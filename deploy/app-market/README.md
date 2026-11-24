# 应用市场部署

## 1. 备份

```bash
python3 - <<'PY'
import sqlite3, time
src = sqlite3.connect('/www/wwwroot/music/data/db/tracks.db')
dst = sqlite3.connect('/www/wwwroot/music/data/db/tracks.db.bak-appmarket-%d' % int(time.time()))
src.backup(dst)
dst.close(); src.close()
PY
```

## 2. 上传代码

```bash
# 建议用 SSH key 或 ssh-agent，不要写死密码
REMOTE=root@your-server-ip bash deploy/app-market/deploy-remote.sh
```

脚本会先备份将被覆盖的 `schema.py`、`server.py`、`handlers/admin_api.py`、`templates/admin.html`。

## 3. 环境文件

```bash
ssh root@your-server-ip
install -m 600 /dev/null /www/wwwroot/Yosar-community/services/app-market.env
# 写入强随机值；两个 MUST 一致
APP_TICKET_SECRET=$(openssl rand -hex 32)
APP_INTERNAL_TOKEN=$(openssl rand -hex 32)
cat > /www/wwwroot/Yosar-community/services/app-market.env <<ENV
APP_TICKET_SECRET=$APP_TICKET_SECRET
APP_INTERNAL_TOKEN=$APP_INTERNAL_TOKEN
APP_TICKET_TTL=1800
APP_MANIFEST_URL=http://127.0.0.1:8790/community/api/internal/app-download/manifest
APP_RESOLVER_URL=http://127.0.0.1:8793/resolve
APP_ALLOW_PRIVATE=0
ENV
```

主服务 systemd unit 也需要读取该文件：

```bash
cp /etc/systemd/system/community.service /etc/systemd/system/community.service.bak-appmarket
# 在 [Service] 的 Environment= 行后、ExecStart 前加入：
# EnvironmentFile=/www/wwwroot/Yosar-community/services/app-market.env
```

## 4. 建表 / 启动

```bash
cd /www/wwwroot/Yosar-community
COMMUNITY_DB=/www/wwwroot/music/data/db/tracks.db python3 -c 'from schema import init_schema; init_schema()'
cp deploy/app-market/app-resolver.service /etc/systemd/system/
cp deploy/app-market/app-delivery.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now app-resolver.service app-delivery.service
systemctl restart community.service
systemctl status community.service app-resolver.service app-delivery.service --no-pager
```

## 5. Nginx

在 `location /community/` 之前加入 `deploy/app-market/nginx-community-dl.conf` 的内容，然后：

```bash
nginx -t && systemctl reload nginx
```

## 6. 验证

```bash
curl -s https://www.yosar.cloud/community/api/apps/categories | head -c 500
curl -s http://127.0.0.1:8793/health
curl -s http://127.0.0.1:8792/health
curl -s -o /dev/null -w '%{http_code}\n' https://www.yosar.cloud/community/admin.html
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' https://www.yosar.cloud/community/admin-apps.html
# 下载入口和 Range 需要真实已上架应用；验证后用测试数据清理。
```
