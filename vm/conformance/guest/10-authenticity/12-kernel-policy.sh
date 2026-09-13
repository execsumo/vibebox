#!/usr/bin/env bash

set -u
source "$(dirname "$0")/../../lib.sh"

id=12-kernel-policy
if [[ "$(stat -fc %T /sys/fs/cgroup)" != "cgroup2fs" ]]; then
    fail "$id" "cgroup v2 is mounted"
    exit 1
fi
if ! systemctl is-enabled systemd-timesyncd >/dev/null 2>&1; then
    fail "$id" "systemd-timesyncd is enabled"
    exit 1
fi
if ! swapon --show --noheadings | grep -q .; then
    fail "$id" "swap is configured"
    exit 1
fi
ok "$id" "cgroup v2, timesync, and swap are configured"
