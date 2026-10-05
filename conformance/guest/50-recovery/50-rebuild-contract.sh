#!/usr/bin/env bash

set -u
source "$(dirname "$0")/../../lib.sh"

id=50-rebuild-contract
if [[ ! -S /var/run/docker.sock ]] || ! systemctl is-active --quiet docker; then
    fail "$id" "the guest has a native Docker socket and active Docker daemon"
    exit 1
fi
socket_mount=$(findmnt --target /var/run/docker.sock --noheadings --output SOURCE,FSTYPE,OPTIONS 2>/dev/null || true)
if [[ "$socket_mount" =~ (drvfs|9p|virtiofs|/mnt/[a-zA-Z]) ]]; then
    fail "$id" "the Docker socket is not backed by a host filesystem"
    exit 1
fi
if mount | grep -qiE 'drvfs|9p|/mnt/[a-z]'; then
    fail "$id" "the guest has no host drive mount"
    exit 1
fi
if [[ ! -x /usr/local/sbin/vibebox-backup-producer ]]; then
    fail "$id" "the restricted backup producer is installed"
    exit 1
fi
ok "$id" "guest recovery boundary has no host socket or drive mount"
