#!/usr/bin/env bash

set -u
source "$(dirname "$0")/../../lib.sh"

id=11-filesystem
if mount | grep -iE '9p|drvfs|//'; then
    fail "$id" "the guest has no Windows filesystem mount"
    exit 1
fi
if ! findmnt -n -o FSTYPE / | grep -Eq 'ext4|xfs|btrfs'; then
    fail "$id" "root is a native Linux filesystem"
    exit 1
fi
ok "$id" "native guest filesystem and no host filesystem mount are present"
