#!/usr/bin/env bash

set -u
source "$(dirname "$0")/../../lib.sh"

id=10-systemd
pid1=$(ps -p 1 -o comm= | tr -d ' ')
if [[ "$pid1" != "systemd" ]]; then
    fail "$id" "systemd is PID 1" "PID 1 is $pid1"
    exit 1
fi
if ! systemctl is-system-running >/dev/null 2>&1 && ! systemctl is-system-running 2>&1 | grep -Eq 'starting|degraded'; then
    fail "$id" "systemctl is functional"
    exit 1
fi
if [[ -e /.dockerenv || -n "${WSL_INTEROP:-}" ]]; then
    fail "$id" "guest is not a container or WSL environment"
    exit 1
fi
virt=$(systemd-detect-virt 2>/dev/null || true)
[[ "$virt" != "docker" && "$virt" != "wsl" && "$virt" != "lxc" ]] || {
    fail "$id" "guest reports a hypervisor rather than a container" "detected $virt"
    exit 1
}
ok "$id" "systemd is PID 1 and the guest is not Docker or WSL"
