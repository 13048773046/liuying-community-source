# 共享数据平面与音乐停服隔离

## 结论

音乐与社区共享同一份用户身份和业务数据，但数据文件已经从音乐项目目录迁出，放在中立路径：

```
/www/wwwroot/yosar-data/db/tracks.db
```

- 音乐 `config.json` → `paths.db` 指向该文件。
- 社区 `community.service` → `COMMUNITY_DB` 指向该文件。
- 音乐注册的新用户立即出现在社区；社区签发/校验的 token 与音乐互通。
- 社区登录页支持邮箱验证码：新邮箱自动注册、老邮箱直接登录；验证码可由社区自己发送和校验。
- 音乐 `music.service` 停止时，社区不依赖该进程：已实测社区可独立启动，登录、资料、信息流、曲库、通知、头像、封面、配乐均可用。

## 为什么不是“社区复制一份用户表”

复制会带来双写、回填和密码哈希不一致问题。当前采用“共享数据平面”：

- 单一事实来源，音乐注册/社区登录不会分叉。
- 迁移成本低，现有 token、关注、通知、曲库无需重灌。
- 音乐停摆只影响音乐进程，不影响数据文件。

## 配置位置

| 项 | 路径 |
|---|---|
| 主库 | `/www/wwwroot/yosar-data/db/tracks.db` |
| 音乐配置 | `/www/wwwroot/music/config.json` → `paths.db` |
| 社区服务 | `/etc/systemd/system/community.service` → `Environment=COMMUNITY_DB=...` |
| 迁移备份 | `/www/wwwroot/Yosar-community/backups/db-20261119/` |
| 旧库（仅保留，不再写入） | `/www/wwwroot/music/data/db/tracks.db` |
| 共享媒体目录 | `/data-music/files`（`/www/wwwroot/music/data/media/files` 只是符号链接） |
| 社区媒体代理 | `/community/api/music/{files,cover,avatar,background}/...` |
| SMTP 中立配置 | `/www/wwwroot/yosar-data/config/smtp.json`（`COMMUNITY_SMTP_CONFIG` 可覆盖） |

## 切换步骤（本次已执行）

1. 停止 `community.service` 和 `music.service`。
2. 备份旧库、音乐配置、社区 unit。
3. 复制 `tracks.db`（含 WAL/SHM）到 `/www/wwwroot/yosar-data/db/`。
4. 修改音乐 `paths.db` 与社区 `COMMUNITY_DB`。
5. `systemctl daemon-reload`，先启动音乐，再启动社区。
6. 验证用户数、曲库数、社区帖子数与旧库一致。

## 停服实测

1. `systemctl stop music.service`。
2. 社区 `health/ready` 200。
3. 音乐注册的账号 `280173` 通过 `POST /community/api/auth/login` 登录成功；`/user/me` 200。
4. `/feed` 200，`/music/tracks` 200（代理失败直读本地曲库），`/notifications/unread` 200。
5. 媒体代理：头像 200、曲库封面 200、配乐 Range 206；曲库 315 首仍可读。
6. 邮箱验证码登录：社区 `POST /auth/login-email` 用共享 `email_codes` 校验，新邮箱自动注册并签发 token；停止音乐时实测成功，测试用户已清理。
7. 停止社区后再单独启动社区（音乐仍停止）：`health` 200、头像 200、`feed` 200、曲库 200。
8. 恢复 `music.service` 后音乐 `health` 200，社区 `ready` 200。
9. 测试账号及 token 已清理。

## 媒体层隔离

- `GET /community/api/music/files/<fname>`：配乐音频，支持 Range 206。
- `GET /community/api/music/cover/<trackId>`：曲库封面，先查 `tracks.cover`，回退 `<id>_cover.jpg`，第三方封面 302。
- `GET /community/api/music/avatar/<uid>`、`GET /community/api/music/background/<uid>`：用户头像/背景。
- 读取根目录默认 `/data-music/files`，可用 `COMMUNITY_MUSIC_FILES` 覆盖；文件名只允许 basename，防目录穿越。
- 曲库代理返回的封面统一改写为社区地址；旧帖配乐 URL 在 `decorate_post` 输出时改写。

## 当前边界

- 这是同一台机器上的共享 SQLite 文件，不是跨机共享数据库；第二台服务器不能直接挂同一个 SQLite 文件。
- 单文件仍有单点故障：数据库损坏/误删时两边都不可用，必须依赖备份恢复。
- 邮箱验证码已社区化：`/auth/send-email-code` 发送、`/auth/login-email` 校验并自动注册；客户端优先音乐，音乐 5xx/不可达时回退社区。SMTP 从 `/www/wwwroot/yosar-data/config/smtp.json` 读取，不依赖音乐进程。
- 媒体已由社区代理并读取中立媒体目录，不再依赖音乐进程；旧帖 `music` 字段中的音乐站 URL 在接口输出时自动改写为社区代理 URL。
- 双机负载均衡前，必须把 SQLite 换成 PostgreSQL/MySQL 或独立数据库服务。

## 回滚

```bash
systemctl stop community.service music.service
cp /www/wwwroot/Yosar-community/backups/db-20261119/tracks.db \
   /www/wwwroot/music/data/db/tracks.db
cp /www/wwwroot/Yosar-community/backups/db-20261119/config.json \
   /www/wwwroot/music/config.json
cp /www/wwwroot/Yosar-community/backups/db-20261119/community.service \
   /etc/systemd/system/community.service
systemctl daemon-reload
systemctl start music.service community.service
```

回滚会丢失切换后写入共享库的数据；生产回滚前先备份当前 `/www/wwwroot/yosar-data/db/tracks.db`。
