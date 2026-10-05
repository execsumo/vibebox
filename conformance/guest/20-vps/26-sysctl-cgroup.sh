#!/usr/bin/env bash

set -u
source "$(dirname "$0")/../../lib.sh"

id=26-sysctl-cgroup
file=/etc/sysctl.d/99-vibebox-conformance.conf
cat > "$file" <<'EOF'
fs.inotify.max_user_watches=524288
vm.max_map_count=262144
net.core.somaxconn=4096
EOF
sysctl --system >/dev/null || {
    rm -f "$file"
    fail "$id" "representative sysctl values persist"
    exit 1
}
for key in fs.inotify.max_user_watches vm.max_map_count net.core.somaxconn; do
    sysctl -n "$key" >/dev/null || {
        rm -f "$file"
        fail "$id" "$key is writable and readable"
        exit 1
    }
done
rm -f "$file"
if [[ "$(stat -fc %T /sys/fs/cgroup)" != "cgroup2fs" ]]; then
    fail "$id" "cgroup v2 delegation is available"
    exit 1
fi
ok "$id" "sysctl persistence and cgroup v2 are available"
