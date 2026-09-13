#!/usr/bin/env bash

set -u
source "$(dirname "$0")/../../lib.sh"

id=23-logs-network
if ! journalctl -u ssh.service -n 1 --no-pager >/dev/null 2>&1; then
    fail "$id" "journalctl can read a service journal"
    exit 1
fi
if ! ss -tlnp | grep -q ':22 '; then
    fail "$id" "ss reports the SSH listener"
    exit 1
fi
ok "$id" "journal and listener reporting are truthful"
