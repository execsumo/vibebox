#!/usr/bin/env bash

set -u
source "$(dirname "$0")/../../lib.sh"

id=22-timer
service=vibebox-conformance-timer.service
timer=vibebox-conformance-timer.timer
marker=/run/vibebox-conformance-timer
cat > "/etc/systemd/system/$service" <<EOF
[Service]
Type=oneshot
ExecStart=/usr/bin/touch $marker
EOF
cat > "/etc/systemd/system/$timer" <<'EOF'
[Unit]
Description=Vibebox conformance timer

[Timer]
OnActiveSec=1s
AccuracySec=1s
EOF
systemctl daemon-reload
systemctl start "$timer"
for _ in $(seq 1 10); do
    [[ -e "$marker" ]] && break
    sleep 1
done
fired=false
[[ -e "$marker" ]] && fired=true
systemctl stop "$timer" >/dev/null 2>&1 || true
rm -f "/etc/systemd/system/$service" "/etc/systemd/system/$timer" "$marker"
systemctl daemon-reload
[[ "$fired" == true ]] || {
    fail "$id" "systemd timer actually fired"
    exit 1
}
# The timer's service is removed after the assertion, so use journal evidence.
ok "$id" "systemd timer was scheduled and completed"
