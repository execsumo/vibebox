#!/usr/bin/env bash

set -u
source "$(dirname "$0")/../../lib.sh"

id=24-databases-web
export DEBIAN_FRONTEND=noninteractive
apt-get update >/dev/null
apt-get install -y --no-install-recommends postgresql nginx >/dev/null || {
    fail "$id" "unmodified apt instructions install PostgreSQL and nginx"
    exit 1
}
systemctl enable --now postgresql nginx
systemctl is-active postgresql nginx >/dev/null || {
    fail "$id" "PostgreSQL and nginx are native systemd services"
    exit 1
}
ss -tlnp | grep -q ':80 ' || {
    fail "$id" "nginx truthfully binds port 80"
    exit 1
}
if ! tailscale status --json >/dev/null 2>&1; then
    skip "$id" "tailnet reachability requires explicit Tailscale enrollment and policy approval"
    exit 77
fi
ok "$id" "PostgreSQL and nginx install and run from upstream Ubuntu packages"
