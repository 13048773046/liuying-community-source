# 流萤社区 · 开发文档

> 面向第一次拿到源码、要在本地把前后端跑起来并完成一次构建的人。
> 架构说明见 [`ARCHITECTURE.md`](ARCHITECTURE.md)；后端新增接口约定见 [`community/ARCHITECTURE.md`](../community/ARCHITECTURE.md)。

## 1. 环境准备

| 工具 | 版本/要求 | 用途 |
|---|---|---|
| Flutter | 3.47.7（与 CI 一致） | 客户端运行、测试、构建 |
| Dart | 随 Flutter，SDK `^3.13.5` | 客户端代码 |
| Python | 3.12（3.11+ 可用） | 后端主服务、测试 |
| Node.js | 18+（仅 Cap 验证码服务需要） | `community/cap_service/` |
| Android SDK | compileSdk 36、JDK 17 | Android 构建 |
| Xcode | macOS 15 + 最新 Xcode | iOS 构建 |
| Nginx | 生产反向代理 | 部署 |

后端主服务只用 Python 标准库；唯一非标准依赖是 `Pillow`（图片处理）和邀请短信/人机验证相关可选依赖。若只用主流程，安装：

```bash
python3 -m pip install pillow
# 仅在启用邀请短信/短信通道时需要
python3 -m pip install -r community/requirements-invite.txt
```

Flutter 依赖：

```bash
flutter pub get
```

## 2. 仓库结构

```text
lib/                Flutter 客户端
test/               Widget / Golden / 冒烟测试
assets/             字体、品牌素材、头像框、表情、流萤形象
android/            Android 工程
ios/                iOS 工程
community/          后端主服务
  server.py         HTTP 传输
  app.py            应用层
  routes.py         路由清单
  handlers/         领域 handler
  core/             配置/DB/路由/日志/安全
  app_market/       应用市场领域包
  templates/        管理后台与分享 H5
  cap_service/      Cap 人机验证服务
  tests/            后端测试
services/           应用解析、下载网关
deploy/             应用市场部署模板
docs/               架构与开发文档
community-site/     官网静态页
scripts/            运维/迁移脚本
```

## 3. 配置

### 3.1 客户端

`lib/config.dart` 的默认站点是 `https://www.dbmt999.asia`，可在运行/构建时覆盖：

```bash
flutter run \
  --dart-define=SITE_BASE=http://127.0.0.1:8790 \
  --dart-define=API_BASE=http://127.0.0.1:8790/community/api
```

| 变量 | 默认 | 说明 |
|---|---|---|
| `SITE_BASE` | `https://www.dbmt999.asia` | 站点根；音乐、媒体默认从它派生 |
| `API_BASE` | `$SITE_BASE/community/api` | 社区 API 根，优先级最高 |

真机联调时不要用 `127.0.0.1`：Android 模拟器用 `10.0.2.2`，iOS 模拟器可用 `127.0.0.1`，真机用电脑局域网 IP。生产必须 HTTPS。

### 3.2 后端主服务

所有环境变量在 `community/core/settings.py` 读取，启动时校验。

| 变量 | 默认 | 说明 |
|---|---|---|
| `COMMUNITY_DB` | `/www/wwwroot/yosar-data/db/tracks.db` | SQLite 路径 |
| `COMMUNITY_HOST` | `127.0.0.1` | 监听地址 |
| `COMMUNITY_PORT` | `8790` | 监听端口 |
| `COMMUNITY_API_PREFIX` | `/community/api` | 必须以 `/` 开头 |
| `COMMUNITY_PUBLIC_BASE` | `https://www.yosar.cloud/community/api` | 对外 API 根 |
| `COMMUNITY_MUSIC_API` | `http://127.0.0.1:8788` | 音乐曲库上游 |
| `COMMUNITY_MUSIC_PUBLIC_BASE` | `https://www.yosar.cloud/music` | 曲库封面兜底前缀 |
| `COMMUNITY_MUSIC_FILES` | `/data-music/files` | 共享媒体目录 |
| `COMMUNITY_VERSION` | `0.9.58` | `/version` 返回值 |
| `COMMUNITY_CORS_ORIGINS` | 站点域名列表 | 允许跨域来源 |
| `COMMUNITY_MAX_JSON_BODY` | 1 MiB | JSON 请求体上限 |
| `COMMUNITY_MAX_UPLOAD_BODY` | 64 MiB | multipart 上限 |
| `COMMUNITY_LOG_LEVEL` | `INFO` | DEBUG/INFO/WARNING/ERROR/CRITICAL |
| `COMMUNITY_LOG_JSON` | `true` | JSON 行日志 |
| `LIUYING_SB_SECRET` | 无（必须设置） | A 侧沙箱 HMAC 共享密钥；未设置时 `af_sandbox` 直接报错 |

生产密钥（SMTP、支付、短信、应用市场 ticket）不要写进仓库，使用 systemd `EnvironmentFile` 或 CI Secrets。仓库里的 `deploy/app-market/env.example` 只是占位模板。

## 4. 本地启动后端

### 4.1 建最小测试库

`community/tests/prepare_db.py` 会创建 `community/tests/tracks_test.db`，包含音乐侧最小共享表（`users` / `tokens` / `follows` / `notifications`）和社区表，并种 3 个测试用户、token、管理员 token。

```bash
python3 community/tests/prepare_db.py
```

输出里的 `tokens` 和 `admin_token` 可用于本地接口调试。**不要把测试库提交到仓库**。

### 4.2 启动服务

```bash
COMMUNITY_DB=community/tests/tracks_test.db \
COMMUNITY_PORT=8790 \
python3 community/server.py
```

验证：

```bash
curl -s http://127.0.0.1:8790/community/api/health
curl -s http://127.0.0.1:8790/community/api/ready
curl -s http://127.0.0.1:8790/community/api/version
```

- `health` 只证明进程活着，不查库。
- `ready` 会连库并检查 `community_posts` 是否存在，失败返回 503。
- 本地没有音乐进程时，曲库代理会回退读共享 `tracks` 表；媒体文件需要放到 `COMMUNITY_MUSIC_FILES` 指向的目录。

### 4.3 运行客户端

```bash
flutter pub get
flutter run \
  --dart-define=API_BASE=http://127.0.0.1:8790/community/api \
  --dart-define=SITE_BASE=http://127.0.0.1:8790
```

Android 模拟器：

```bash
flutter run \
  --dart-define=API_BASE=http://10.0.2.2:8790/community/api \
  --dart-define=SITE_BASE=http://10.0.2.2:8790
```

如果只想看 UI，不接后端，部分页面会进入空态；登录、发帖、私信等写操作需要真实服务。

## 5. 测试

### 5.1 客户端

```bash
flutter analyze lib test
flutter test
```

只跑受影响范围：

```bash
flutter test test/pages_smoke_test.dart
flutter test test/social_features_golden_test.dart
flutter test test/profile_self_actions_test.dart
```

Golden 测试依赖 `test/goldens/`；修改视觉后先确认差异是预期，再更新基线。仓库不包含 `test/failures/` 历史失败截图。

### 5.2 后端

```bash
python3 -m py_compile community/server.py community/app.py community/routes.py community/core/*.py
python3 -m unittest community/tests/test_architecture.py -v
python3 community/tests/community_smoke_test.py
python3 community/tests/member_smoke_test.py
python3 community/tests/app_market_smoke.py
```

- `community_smoke_test.py` 会自建临时服务与测试库，覆盖登录、发帖、评论、审核、私信、限流等主链路。
- `app_market_smoke.py` 会在 `/tmp` 创建临时库，并在 8800/8890/8891/8892 起测试进程，覆盖 resolver + gateway + Range 下载。
- 测试会占用本地端口，先确认没有残留进程。

## 6. 构建

### 6.1 Android

Debug：

```bash
flutter build apk --debug
```

Release 必须通过环境注入签名，仓库不保存 keystore：

```bash
export ANDROID_KEYSTORE_PATH=/secure/liuying-release.jks
export ANDROID_KEYSTORE_PASSWORD=...
export ANDROID_KEY_ALIAS=liuying-release
export ANDROID_KEY_PASSWORD=...
flutter build apk --release
```

`android/app/build.gradle.kts` 在 release 任务缺少 `ANDROID_KEYSTORE_PATH` 时会直接失败，这是有意的：不要把签名密钥提交进仓库。客户端还会校验签名证书 SHA-256（`EXPECTED_SIGNATURE_SHA256`），换签名后需要同步更新构建环境变量，否则安装后可能拒绝启动。

### 6.2 iOS

需要 macOS + Xcode：

```bash
flutter pub get
flutter build ios --release --no-codesign
```

产物在 `build/ios/iphoneos/Runner.app`。仓库 CI 会把它打成未签名 IPA：

```bash
mkdir -p build/ios/ipa/Payload
cp -R build/ios/iphoneos/Runner.app build/ios/ipa/Payload/
cd build/ios/ipa
zip -qry community-unsigned.ipa Payload
shasum -a 256 community-unsigned.ipa
```

未签名 IPA 需要自签或 Sideloadly 安装。`video_player_avfoundation` 锁定 2.11.1 是为了兼容 CI 的 Xcode/Swift 版本，升级前先验证 iOS 构建。

### 6.3 CI

仓库提供三条通用工作流：

- `.github/workflows/ci.yml`：后端架构/单元测试 + Flutter analyze。
- `.github/workflows/android-release.yml`：手动触发，读取 Android 签名 Secrets，产出 APK artifact。
- `.github/workflows/ios-unsigned.yml`：手动触发，macOS 构建未签名 IPA artifact。

历史版本专用 workflow 不进入本仓库，避免误触发旧 CDN 源码包。

## 7. 后端部署

### 7.1 进程

生产典型拓扑：

```text
Nginx :443
  /community/api/ → 127.0.0.1:8790
  /community/dl/  → 127.0.0.1:8792
  /music/         → 127.0.0.1:8788
  /community/     → 后台/分享/媒体
```

`community.service` 示例（按实际路径调整）：

```ini
[Unit]
Description=Liuying Community
After=network.target

[Service]
Type=simple
WorkingDirectory=/www/wwwroot/Yosar-community
Environment=COMMUNITY_DB=/www/wwwroot/yosar-data/db/tracks.db
Environment=COMMUNITY_HOST=127.0.0.1
Environment=COMMUNITY_PORT=8790
EnvironmentFile=/www/wwwroot/Yosar-community/services/app-market.env
ExecStart=/usr/bin/python3 /www/wwwroot/Yosar-community/community/server.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
```

应用市场两个附属服务见 `deploy/app-market/`：

```bash
cp deploy/app-market/app-resolver.service /etc/systemd/system/
cp deploy/app-market/app-delivery.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now app-resolver.service app-delivery.service
systemctl restart community.service
```

### 7.2 Nginx

`deploy/app-market/nginx-community-dl.conf` 提供 `/community/dl/` 的精确反代。上线前：

```bash
nginx -t && systemctl reload nginx
```

### 7.3 数据库与备份

- 主库：`/www/wwwroot/yosar-data/db/tracks.db`（与音乐共享）。
- 社区只新增 `community_*` 表；共享表结构由音乐侧维护。
- 备份必须覆盖 `tracks.db` 与媒体目录；SQLite 备份用 `.backup` 或停服复制，不要只拷 `.db` 而漏掉 WAL。
- 双机部署前必须迁移到 PostgreSQL/MySQL；SQLite 单文件不能跨机共享。

## 8. 新增功能约定

### 8.1 新增后端接口

1. 先判断领域：已有 handler 能覆盖就在原文件加精确路由；新领域新建 `handlers/<domain>.py`。
2. 实现 `dispatch(self, c, u, api, method) -> bool`，路径精确匹配，不写宽泛 `startswith` 兜底。
3. 在 `routes.py` 登记 `ModuleSpec(name, prefixes, description)`。
4. 鉴权、限流、参数校验在 handler 内完成；错误优先抛 `core.errors.ApiError`。
5. 涉及持久写/权限/外部副作用时补真实链路测试。

### 8.2 新增客户端页面

1. 页面放 `lib/pages/<domain>/`；跨页能力放 `lib/services/`。
2. 只使用 `AppColors` / `AppType` / `AppSpace` / `AppRadius` / `AppMotion`，不写字面量。
3. 请求带 token/uid 快照与请求序号；页面销毁后不回调 `setState`。
4. 列表分页用现有 `LoadMoreFooter` / `SkeletonSwap` / `BlurUpImage`。
5. 至少补一个页面冒烟或 Golden；键盘/窄屏交互要单独覆盖。

### 8.3 数据库变更

- 新表/新列必须幂等；不要改历史迁移。
- 共享表可选列运行时探测，不能假设音乐库永远有。
- 生产迁移前先备份；迁移脚本放到 `scripts/` 并写清回滚。

## 9. 常见问题

| 现象 | 排查 |
|---|---|
| `ready` 返回 503 | `COMMUNITY_DB` 路径不存在、无写权限，或 `community_posts` 未建表 |
| 登录成功但资料 401 | 客户端 token 未写入安全存储；检查 `SecureStore` 与请求头 |
| 图片/视频 404 | `COMMUNITY_MUSIC_FILES` / 上传目录不在预期路径；检查媒体文件名与代理路由 |
| 短视频 iOS 构建失败 | `video_player_avfoundation` 版本与 Xcode/Swift 不兼容；保持 2.11.1 并清理 Pods 后重试 |
| Android release 直接失败 | 未设置 `ANDROID_KEYSTORE_PATH`；这是签名保护，不是代码缺陷 |
| 应用下载 302 后 403 | ticket 过期/密钥不一致；主服务与 gateway 的 `APP_TICKET_SECRET` 必须一致 |
| WebSocket 不推消息 | Nginx 未升级协议；检查 `Upgrade` / `Connection` 头与 `/community/api/ws` 反代 |
| 热更新不生效 | 检查 `shorebird.yaml`、补丁通道与 `kHotUpdateStamp`；热更只替换 Dart 代码 |

## 10. 提交前检查清单

- [ ] `flutter analyze lib test` 无新增 error/warning。
- [ ] 受影响页面有冒烟/ Golden/交互测试。
- [ ] `python3 -m unittest community/tests/test_architecture.py` 通过。
- [ ] 改动涉及后端写操作时，跑对应 smoke。
- [ ] 没有提交 keystore、`.env`、数据库、上传文件、安装包、日志、失败截图。
- [ ] 版本号、`lib/config.dart`、更新说明保持一致。
- [ ] 生产配置只通过环境变量注入，仓库内是占位值。

## 11. 安全与隐私

- token 只存 Keychain / Keystore；日志不打印 `Authorization`、密码、支付签名。
- 后台接口必须校验管理员 token 与模块权限；不要用“隐藏入口”当权限。
- 上传必须限制类型、大小、路径穿越；媒体代理只允许 basename。
- 外链解析禁止访问内网/本机地址（`APP_ALLOW_PRIVATE=0`）。
- 生产数据库、SMTP、支付、对象存储密钥只放服务器环境文件，权限 600。
