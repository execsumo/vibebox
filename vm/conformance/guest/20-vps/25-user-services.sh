#!/usr/bin/env bash

set -u
source "$(dirname "$0")/../../lib.sh"

id=25-user-services
loginctl enable-linger dev
loginctl show-user dev --property=Linger --value | grep -qx yes || {
    fail "$id" "dev user lingering survives logout"
    exit 1
}
ok "$id" "user services can outlive an SSH logout"
