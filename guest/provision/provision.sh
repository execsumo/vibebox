#!/usr/bin/env bash

set -Eeuo pipefail

ROOT=${VIBEBOX_ROOT:-/opt/vibebox}
CONFIG_FILE=${VIBEBOX_CONFIG_FILE:-/etc/vibebox/vibebox.env}
LOG_FILE=${VIBEBOX_LOG_FILE:-/var/log/vibebox-provision.log}

if [[ ${EUID} -ne 0 ]]; then
    printf 'provisioning must run as root\n' >&2
    exit 1
fi

exec 9>/run/lock/vibebox-provision.lock
flock 9

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 0600 "$LOG_FILE"

if [[ -r "$ROOT/read-env.sh" ]]; then
    # shellcheck source=/dev/null
    source "$ROOT/read-env.sh"
else
    printf 'missing guest configuration reader: %s\n' "$ROOT/read-env.sh" >&2
    exit 1
fi
read_vibebox_env "$CONFIG_FILE"

: "${GUEST_USER:?GUEST_USER is required}"
: "${GUEST_SHELL:?GUEST_SHELL is required}"
: "${GUEST_UFW:?GUEST_UFW is required}"
: "${GUEST_SWAP_GB:?GUEST_SWAP_GB is required}"
: "${GUEST_TIMEZONE:?GUEST_TIMEZONE is required}"
: "${NODE_MAJOR:?NODE_MAJOR is required}"
: "${TOOLS_OPTIONAL:=}"
: "${TOOLS_UPDATE_POLICY:=latest}"

export VIBEBOX_ROOT CONFIG_FILE

run_phase() {
    local phase=$1
    local phase_path="$ROOT/provision/$phase"
    [[ -x "$phase_path" ]] || {
        printf 'missing provisioning phase: %s\n' "$phase_path" >&2
        return 1
    }
    printf '\n== %s ==\n' "$phase" | tee -a "$LOG_FILE"
    "$phase_path" "$CONFIG_FILE" 2>&1 | tee -a "$LOG_FILE"
}

run_phase 00-base
run_phase 10-docker
run_phase 20-tailscale
run_phase 30-tools
run_phase 40-services

printf '\nProvisioning completed at %s\n' "$(date --iso-8601=seconds)" | tee -a "$LOG_FILE"
