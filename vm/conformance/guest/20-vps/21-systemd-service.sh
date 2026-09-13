#!/usr/bin/env bash

set -u
source "$(dirname "$0")/../../lib.sh"

id=21-systemd-service
unit=vibebox-conformance.service
cat > "/etc/systemd/system/$unit" <<'EOF'
[Unit]
Description=Vibebox conformance service
After=network.target

[Service]
Type=simple
ExecStart=/bin/sh -c 'printf conformance; sleep 30'
Restart=on-failure
EnvironmentFile=-/etc/default/vibebox-conformance

[Install]
WantedBy=multi-user.target
EOF
printf 'VIBEBOX_CONFORMANCE=1\n' > /etc/default/vibebox-conformance
systemctl daemon-reload
systemctl start "$unit"
kill -KILL "$(systemctl show "$unit" --property=MainPID --value)"
sleep 2
if [[ "$(systemctl is-active "$unit")" != "active" ]]; then
    systemctl stop "$unit" || true
    systemctl reset-failed "$unit" || true
    fail "$id" "systemd restarts a killed unit with EnvironmentFile"
    exit 1
fi
systemctl stop "$unit"
systemctl disable "$unit" >/dev/null 2>&1 || true
rm -f "/etc/systemd/system/$unit" /etc/default/vibebox-conformance
systemctl daemon-reload
ok "$id" "hand-written Restart=on-failure service survives kill -9"
