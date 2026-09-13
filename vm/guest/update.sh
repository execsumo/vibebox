#!/usr/bin/env bash
# Update the OS packages and the toolchain, and report what actually changed.
#
# The legacy container deliberately skipped APT: a system upgrade was slow and
# its results were discarded by the next `docker compose down/up`, so the OS
# was the host-side `update-image` script's job. A VM persists, so that split
# no longer buys anything and both halves live here.
#
# Tool updates run through provision/30-tools rather than being duplicated,
# so `update` and `provision` can never disagree about how a tool is installed.
# 30-tools honours TOOLS_UPDATE_POLICY, so `locked` pins to manifest.lock and
# this becomes a no-op for tools.

set -Eeuo pipefail

CONFIG_FILE=${1:?configuration file is required}
ROOT=${VIBEBOX_ROOT:-/opt/vibebox}
MODE=${2:-all}          # all | tools | os

# shellcheck source=/dev/null
source "$ROOT/read-env.sh"
read_vibebox_env "$CONFIG_FILE"

manifest_lock="$ROOT/manifest.lock"
before_lock=$(mktemp)
before_pkgs=$(mktemp)
trap 'rm -f "$before_lock" "$before_pkgs"' EXIT
[[ -f "$manifest_lock" ]] && cp "$manifest_lock" "$before_lock" || true
dpkg-query -W -f='${Package} ${Version}\n' 2>/dev/null | sort > "$before_pkgs" || true

if [[ "$MODE" == "all" || "$MODE" == "os" ]]; then
    printf '== operating system ==\n'
    export DEBIAN_FRONTEND=noninteractive
    # List services needing restart; do not restart them. needrestart bouncing
    # dbus or sshd mid-upgrade kills the channel this command arrives on, so the
    # upgrade succeeds while the caller sees a failure. Report instead.
    export NEEDRESTART_MODE=l
    apt-get update -qq
    # upgrade, not full-upgrade: full-upgrade may remove packages to resolve
    # dependencies, which is not something an unattended update should decide.
    apt-get upgrade -y -qq
    apt-get autoremove -y -qq
    apt-get clean
fi

if [[ "$MODE" == "all" || "$MODE" == "tools" ]]; then
    printf '\n== toolchain ==\n'
    "$ROOT/provision/30-tools" "$CONFIG_FILE"
fi

printf '\n== changes ==\n'

if [[ "$MODE" == "all" || "$MODE" == "os" ]]; then
    after_pkgs=$(mktemp)
    dpkg-query -W -f='${Package} ${Version}\n' 2>/dev/null | sort > "$after_pkgs" || true
    changed=$( { join -j1 "$before_pkgs" "$after_pkgs" 2>/dev/null || true; } \
        | awk '$2 != $3 { printf "  %s: %s -> %s\n", $1, $2, $3 }' || true)
    added=$(comm -13 <(cut -d" " -f1 "$before_pkgs") <(cut -d" " -f1 "$after_pkgs") 2>/dev/null | sed 's/^/  + /' || true)
    removed=$(comm -23 <(cut -d" " -f1 "$before_pkgs") <(cut -d" " -f1 "$after_pkgs") 2>/dev/null | sed 's/^/  - /' || true)
    rm -f "$after_pkgs"
    if [[ -n "$changed$added$removed" ]]; then
        [[ -n "$changed" ]] && printf 'packages upgraded:\n%s\n' "$changed"
        [[ -n "$added" ]] && printf 'packages added:\n%s\n' "$added"
        [[ -n "$removed" ]] && printf 'packages removed:\n%s\n' "$removed"
    else
        printf 'packages: already current\n'
    fi
fi

if [[ "$MODE" == "all" || "$MODE" == "tools" ]]; then
    if [[ -f "$manifest_lock" ]] && ! diff -q "$before_lock" "$manifest_lock" >/dev/null 2>&1; then
        printf 'tools:\n'
        { diff "$before_lock" "$manifest_lock" 2>/dev/null || true; } | sed -n 's/^> /  now: /p; s/^< /  was: /p'
    else
        printf 'tools: already current\n'
    fi
fi

# needrestart is in list-only mode above, so report rather than act.
services=$(needrestart -b 2>/dev/null | sed -n 's/^NEEDRESTART-SVC: //p' | sort -u | tr '\n' ' ' || true)
if [[ -n "${services// /}" ]]; then
    echo "services needing restart: $services"
    echo "run: vibebox restart"
fi

# A kernel or libc upgrade needs a reboot to take effect. Say so rather than
# rebooting a box someone may be working in.
if [[ -f /var/run/reboot-required ]]; then
    echo "reboot required: $(tr '\n' ' ' < /var/run/reboot-required.pkgs 2>/dev/null || echo yes)"
    echo "run: vibebox restart"
fi
