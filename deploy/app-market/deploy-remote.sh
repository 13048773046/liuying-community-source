#!/usr/bin/env bash
# 在仓库根目录执行；不包含密码，请通过 SSH key/ssh-agent 或手工 scp。
set -euo pipefail
REMOTE="${REMOTE:?请先设置 REMOTE=user@host}"
ROOT="/www/wwwroot/Yosar-community"
STAMP="$(date +%Y%m%d-%H%M%S)"

ssh "$REMOTE" "mkdir -p '$ROOT/services' && cp '$ROOT/schema.py' '$ROOT/schema.py.bak-appmarket-$STAMP' && cp '$ROOT/server.py' '$ROOT/server.py.bak-appmarket-$STAMP' && cp '$ROOT/handlers/admin_api.py' '$ROOT/handlers/admin_api.py.bak-appmarket-$STAMP' && cp '$ROOT/templates/admin.html' '$ROOT/templates/admin.html.bak-appmarket-$STAMP'"

rsync -av community/app_market "$REMOTE:$ROOT/"
rsync -av community/handlers/apps.py community/handlers/admin_apps.py "$REMOTE:$ROOT/handlers/"
rsync -av community/templates/admin-apps.html "$REMOTE:$ROOT/templates/"
rsync -av community/schema.py community/server.py "$REMOTE:$ROOT/"
rsync -av community/handlers/admin_api.py "$REMOTE:$ROOT/handlers/"
rsync -av community/templates/admin.html "$REMOTE:$ROOT/templates/"
rsync -av services/app_resolver services/app_delivery "$REMOTE:$ROOT/services/"

ssh "$REMOTE" "cp '$ROOT/services/app-market.env' /tmp/app-market.env.old 2>/dev/null || true; cp /tmp/app-market.env.old '$ROOT/services/app-market.env' 2>/dev/null || true; chmod 600 '$ROOT/services/app-market.env' 2>/dev/null || true"
echo "代码已上传。请按 deploy/app-market/README.md 配置 env/systemd/nginx，再执行 init_schema。"
