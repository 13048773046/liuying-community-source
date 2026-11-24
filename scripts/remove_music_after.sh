#!/bin/bash
set -e
F=/etc/systemd/system/community.service
sed -i 's#After=network.target music.service#After=network.target#' "$F"
grep -n 'After=' "$F"
systemctl daemon-reload
systemctl restart community.service
sleep 2
systemctl is-active community.service
