#!/bin/bash
set -euo pipefail

OLD_DB=/www/wwwroot/music/data/db/tracks.db
NEW_DIR=/www/wwwroot/yosar-data/db
NEW_DB=$NEW_DIR/tracks.db
BK=/www/wwwroot/Yosar-community/backups/db-20261119

systemctl stop community.service || true
systemctl stop music.service || true
sleep 1

mkdir -p "$NEW_DIR" "$BK"
cp -a "$OLD_DB" "$BK/tracks.db"
cp -a /www/wwwroot/music/config.json "$BK/config.json"
cp -a /etc/systemd/system/community.service "$BK/community.service"

cp -a "$OLD_DB" "$NEW_DB"
[ -f "$OLD_DB-wal" ] && cp -a "$OLD_DB-wal" "$NEW_DB-wal" || true
[ -f "$OLD_DB-shm" ] && cp -a "$OLD_DB-shm" "$NEW_DB-shm" || true

sed -i 's#"/www/wwwroot/music/data/db/tracks.db"#"/www/wwwroot/yosar-data/db/tracks.db"#g' /www/wwwroot/music/config.json
sed -i 's#Environment=COMMUNITY_DB=.*#Environment=COMMUNITY_DB=/www/wwwroot/yosar-data/db/tracks.db#' /etc/systemd/system/community.service
sed -i 's#Description=Liuying Community Service.*#Description=Liuying Community Service (independent of music; shared data plane)#' /etc/systemd/system/community.service
systemctl daemon-reload

ls -lh "$NEW_DIR"
grep -n 'db' /www/wwwroot/music/config.json | head -n 3
grep -n 'COMMUNITY_DB\|Description' /etc/systemd/system/community.service

systemctl start music.service
sleep 3
systemctl is-active music.service
systemctl start community.service
sleep 2
systemctl is-active community.service
