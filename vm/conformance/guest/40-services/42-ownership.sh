#!/usr/bin/env bash

set -u
source "$(dirname "$0")/../../lib.sh"

# Pre-installed by vibebox, owned by the user: vibebox runs its own
# maintenance jobs as configured, and never wraps a user application in a
# system unit or a root-level launcher.
id=42-ownership
source /opt/vibebox/read-env.sh
read_vibebox_env /etc/vibebox/vibebox.env

if [[ "${MAINTENANCE_ENABLED:-true}" == true ]]; then
    for job in daily weekly; do
        key="MAINTENANCE_${job^^}_AT"
        [[ -n "${!key-}" ]] || continue
        systemctl is-enabled --quiet "vibebox-maintenance-$job.timer" || {
            fail "$id" "the $job maintenance job is scheduled as configured" "${key}=${!key}"
            exit 1
        }
    done
fi

wrapped=$(systemctl list-unit-files --no-legend 'vibebox-hermes*' 'vibebox-droid*' 2>/dev/null | awk '{print $1}')
if [[ -n "$wrapped" ]]; then
    fail "$id" "no system unit wraps a user application" "$wrapped"
    exit 1
fi
for launcher in /usr/local/bin/hermes /usr/local/bin/hermes-*; do
    [[ -f "$launcher" ]] || continue
    if grep -qE '/root/|/usr/local/lib/hermes-agent' "$launcher" 2>/dev/null; then
        fail "$id" "no root-level launcher shadows the user's Hermes" "$launcher"
        exit 1
    fi
done
ok "$id" "maintenance runs as configured; user applications are not wrapped"
