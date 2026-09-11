#!/usr/bin/env bash

set -Eeuo pipefail

root_source=$(findmnt -n -o SOURCE /)
root_source=${root_source#/dev/}
root_disk=$(lsblk -no PKNAME "/dev/$root_source" 2>/dev/null || true)

if [[ -z "$root_disk" ]]; then
    printf 'root filesystem is not on a partitioned disk; no growth needed\n'
    exit 0
fi

root_partition_number=$(lsblk -no PARTNUM "/dev/$root_source")
if [[ -z "$root_partition_number" ]]; then
    printf 'root device has no partition number; no growth needed\n'
    exit 0
fi

growpart "/dev/$root_disk" "$root_partition_number" || {
    rc=$?
    if [[ $rc -ne 1 ]]; then
        exit "$rc"
    fi
}

filesystem=$(findmnt -n -o FSTYPE /)
case "$filesystem" in
    ext2|ext3|ext4) resize2fs "/dev/$root_source" ;;
    xfs) xfs_growfs / ;;
    *) printf 'filesystem %s does not need a Vibebox resize operation\n' "$filesystem" ;;
esac
