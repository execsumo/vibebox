#!/usr/bin/env bash
# Platform maintenance: the scheduled jobs vibebox runs in the guest.
#
# Pre-installed by vibebox, configured by the user in vibebox.env:
#   MAINTENANCE_ENABLED    true | false -- both jobs
#   MAINTENANCE_DAILY_AT   when the daily job runs: toolchain update
#   MAINTENANCE_WEEKLY_AT  when the weekly job runs: OS + toolchain update,
#                          then housekeeping
# Schedules are systemd calendar expressions ("01:00" is every day,
# "Sun 02:00" every Sunday); an empty value turns that job off.
#
# It maintains the platform only. It never touches user applications (Hermes,
# the WebUI, anything in the user's home), never removes containers or
# volumes, and never reboots or restarts services: like `vibebox update`, it
# reports what needs a restart. Output goes to the journal
# (journalctl -u 'vibebox-maintenance@*'), so there is no log file to grow.
#
# Usage: maintenance.sh run daily|weekly
#        maintenance.sh configure [config-file]   # write and (en|dis)able timers
#        maintenance.sh status

set -Eeuo pipefail

ROOT=${VIBEBOX_ROOT:-/opt/vibebox}
CONFIG_FILE=/etc/vibebox/vibebox.env
JOBS=(daily weekly)

action=${1:-status}
if [[ "$action" == configure && -n "${2:-}" ]]; then
    # Adopt the configuration pushed from the host, as provisioning does.
    install -m 0644 "$2" "$CONFIG_FILE"
fi
# shellcheck source=/dev/null
source "$ROOT/read-env.sh"
read_vibebox_env "$CONFIG_FILE"
enabled=${MAINTENANCE_ENABLED:-true}

schedule_for() {
    case "$1" in
        daily) printf '%s' "${MAINTENANCE_DAILY_AT-01:00}" ;;
        weekly) printf '%s' "${MAINTENANCE_WEEKLY_AT-Sun 02:00}" ;;
    esac
}

update_mode_for() {
    case "$1" in
        daily) printf 'tools' ;;
        weekly) printf 'all' ;;
    esac
}

housekeeping() {
    printf '\n== housekeeping ==\n'
    journalctl --vacuum-size=500M --vacuum-time=30d 2>&1 | tail -n 1 || true
    if command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker; then
        # Only images and build cache unused for a week. Never containers or
        # volumes: a stopped Compose stack keeps its database in a volume.
        docker image prune --all --force --filter until=168h | tail -n 1 || true
        docker builder prune --all --force --filter until=168h | tail -n 1 || true
    fi
}

run() {
    local job=${1:?job is required: daily or weekly} status=0 mode
    mode=$(update_mode_for "$job")
    [[ -n "$mode" ]] || { printf 'unknown job: %s\n' "$job" >&2; return 2; }
    # Jobs, and a manual run, must not overlap: both drive apt and npm.
    exec 9>/run/lock/vibebox-maintenance.lock
    flock -w 3600 9 || { printf 'another maintenance run held the lock for an hour; skipping\n' >&2; return 1; }

    printf '== vibebox maintenance: %s (update %s) ==\n' "$job" "$mode"
    "$ROOT/update.sh" "$CONFIG_FILE" "$mode" || {
        status=1
        printf 'update failed; see the output above\n' >&2
    }
    [[ "$job" == weekly ]] && housekeeping
    return "$status"
}

configure() {
    local job schedule timer
    [[ "$enabled" == true || "$enabled" == false ]] || {
        printf 'MAINTENANCE_ENABLED must be true or false, not %s\n' "$enabled" >&2
        return 1
    }
    install -m 0644 "$ROOT/units/vibebox-maintenance@.service" /etc/systemd/system/
    for job in "${JOBS[@]}"; do
        schedule=$(schedule_for "$job")
        timer="vibebox-maintenance-$job.timer"
        if [[ "$enabled" == false || -z "$schedule" ]]; then
            systemctl disable --now "$timer" >/dev/null 2>&1 || true
            rm -f "/etc/systemd/system/$timer"
            printf 'maintenance %s: off\n' "$job"
            continue
        fi
        if ! systemd-analyze calendar "$schedule" >/dev/null 2>&1; then
            printf 'MAINTENANCE_%s_AT is not a valid systemd calendar expression: %s\n' \
                "${job^^}" "$schedule" >&2
            return 1
        fi
        cat > "/etc/systemd/system/$timer" <<EOF
# Generated from MAINTENANCE_${job^^}_AT by /opt/vibebox/maintenance.sh.
# Change it in vibebox.env and run: vibebox maintenance apply
[Unit]
Description=Vibebox $job maintenance

[Timer]
OnCalendar=$schedule
Persistent=true
RandomizedDelaySec=10m
Unit=vibebox-maintenance@$job.service

[Install]
WantedBy=timers.target
EOF
        systemctl daemon-reload
        systemctl enable --now "$timer" >/dev/null 2>&1
        systemctl restart "$timer"
        printf 'maintenance %s: "%s" (update %s)\n' "$job" "$schedule" "$(update_mode_for "$job")"
    done
    systemctl daemon-reload
}

status() {
    local job next last result
    printf 'enabled: %s\n' "$enabled"
    for job in "${JOBS[@]}"; do
        printf '\n%s (update %s)\n' "$job" "$(update_mode_for "$job")"
        printf '  schedule : %s\n' "$(schedule_for "$job")"
        next=$(systemctl show "vibebox-maintenance-$job.timer" --property=NextElapseUSecRealtime --value 2>/dev/null || true)
        printf '  next run : %s\n' "${next:-not scheduled}"
        last=$(systemctl show "vibebox-maintenance@$job.service" --property=ExecMainExitTimestamp --value 2>/dev/null || true)
        result=$(systemctl show "vibebox-maintenance@$job.service" --property=Result --value 2>/dev/null || true)
        if [[ -n "$last" ]]; then
            printf '  last run : %s (%s)\n' "$last" "$result"
        else
            printf '  last run : never since boot; see journalctl -u vibebox-maintenance@%s\n' "$job"
        fi
    done
}

case "$action" in
    run) run "${2:-}" ;;
    configure) configure ;;
    status) status ;;
    *) printf 'usage: maintenance.sh run daily|weekly | configure [config-file] | status\n' >&2; exit 2 ;;
esac
