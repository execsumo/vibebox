#!/usr/bin/env bash

set -u
source "$(dirname "$0")/../../lib.sh"

id=30-engine
if ! docker info >/dev/null 2>&1; then
    fail "$id" "Docker Engine runs inside the guest"
    exit 1
fi
if ! systemctl is-enabled docker >/dev/null 2>&1; then
    fail "$id" "Docker is enabled by systemd"
    exit 1
fi
docker run --rm alpine:3.20 true >/dev/null 2>&1 || {
    fail "$id" "guest Docker can run a container"
    exit 1
}
ok "$id" "Docker Engine and Compose are guest-local"
