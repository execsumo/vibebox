#!/usr/bin/env bash

set -u
source "$(dirname "$0")/../../lib.sh"

id=25-user-services
# Read the configured account rather than assuming one; GUEST_USER is a
# create-time setting and is not always "dev".
guest_user=$(sed -n 's/^GUEST_USER=//p' /opt/vibebox/vibebox.env 2>/dev/null | head -1)
if [[ -z "$guest_user" ]]; then
    skip "$id" "GUEST_USER is not readable from /opt/vibebox/vibebox.env"
    exit 77
fi

loginctl enable-linger "$guest_user" || {
    fail "$id" "enable-linger succeeds for $guest_user"
    exit 1
}

# logind does not always reflect a just-enabled linger immediately, so poll
# briefly rather than racing it. The on-disk marker is the durable form that
# actually survives logout and reboot.
linger=no
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if [[ -e "/var/lib/systemd/linger/$guest_user" ]] &&
       [[ "$(loginctl show-user "$guest_user" --property=Linger --value 2>/dev/null)" == "yes" ]]; then
        linger=yes
        break
    fi
    sleep 0.5
done

if [[ "$linger" != "yes" ]]; then
    fail "$id" "$guest_user lingering survives logout" \
        "marker=$([[ -e /var/lib/systemd/linger/$guest_user ]] && echo present || echo absent); loginctl=$(loginctl show-user "$guest_user" --property=Linger --value 2>&1)"
    exit 1
fi
ok "$id" "user services can outlive an SSH logout"
