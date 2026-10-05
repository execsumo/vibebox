#!/usr/bin/env bash

set -u
source "$(dirname "$0")/../../lib.sh"

id=40-boot-services
for unit in ssh.service tailscaled.service docker.service systemd-timesyncd.service; do
    systemctl is-enabled "$unit" >/dev/null 2>&1 || {
        fail "$id" "$unit is enabled"
        exit 1
    }
done
ok "$id" "base services are native enabled systemd units"
