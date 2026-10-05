#!/usr/bin/env bash
# Install and update pre-installed user applications without taking ownership
# of their configuration. Updates use each application's own upstream method.
#
# Usage: user-apps.sh install <user> <app>...
#        user-apps.sh sync <user> <app>...
#        user-apps.sh present <user> <app>
#        user-apps.sh version <user> <app>
# Apps:  hermes, hermes-webui

set -Eeuo pipefail

HERMES_INSTALLER=https://hermes-agent.nousresearch.com/install.sh
WEBUI_REPO=https://github.com/nesquena/hermes-webui.git

action=${1:?action is required}
user=${2:?user is required}
shift 2
home=$(getent passwd "$user" | cut -d: -f6)
[[ -n "$home" ]] || { printf 'no such user: %s\n' "$user" >&2; exit 1; }
webui_dir="$home/.local/share/hermes-webui"
webui_unit="$home/.config/systemd/user/hermes-webui.service"

# Run as the user with a reachable user manager, so installers that register
# systemd user services can talk to it. Linger (00-base) keeps it running.
as_user() {
    local uid
    uid=$(id -u "$user")
    for _ in $(seq 1 20); do
        [[ -S "/run/user/$uid/bus" ]] && break
        sleep 0.5
    done
    # setpriv, not runuser: no PAM session, so routine version checks do not
    # log a session open/close pair on every maintenance run.
    setpriv --reuid="$user" --regid="$user" --init-groups -- env \
        HOME="$home" USER="$user" LOGNAME="$user" \
        XDG_RUNTIME_DIR="/run/user/$uid" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
        PATH="$home/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        "$@"
}

present() {
    case "$1" in
        hermes) [[ -x "$home/.local/bin/hermes" ]] ;;
        hermes-webui) [[ -f "$webui_dir/start.sh" ]] ;;
        *) printf 'unknown user app: %s\n' "$1" >&2; return 2 ;;
    esac
}

version() {
    present "$1" || return 1
    case "$1" in
        hermes) as_user "$home/.local/bin/hermes" --version 2>/dev/null | head -n 1 ;;
        hermes-webui) as_user git -C "$webui_dir" log -1 --format='hermes-webui %h (%cs)' ;;
    esac
}

# Hermes' installer puts the agent in ~/.hermes and the launcher in
# ~/.local/bin/hermes. Run non-interactively it does not register the gateway
# service; that happens when the user sets up a messaging platform
# (`hermes gateway setup`, then `hermes gateway install`).
install_hermes() {
    printf 'hermes: installing for %s with the upstream installer\n' "$user"
    as_user bash -c "curl -fsSL '$HERMES_INSTALLER' | bash -s -- --non-interactive"
}

# The WebUI has no installer; upstream's supervisor guide is a checkout plus a
# user unit running start.sh --foreground. Its defaults (127.0.0.1:8787, agent
# at ~/.hermes/hermes-agent) work without configuration; the user configures
# it in its .env, which the unit reads.
install_hermes_webui() {
    if ! present hermes; then
        install_hermes || return
    fi
    printf 'hermes-webui: installing for %s from %s\n' "$user" "$WEBUI_REPO"
    as_user install -d "$(dirname "$webui_dir")" "$(dirname "$webui_unit")"
    as_user git clone --quiet "$WEBUI_REPO" "$webui_dir"
    if [[ ! -e "$webui_unit" ]]; then
        as_user tee "$webui_unit" >/dev/null <<'EOF'
# Installed once by vibebox (guest/user-apps.sh); yours to edit from here on.
# Configure the WebUI in ~/.local/share/hermes-webui/.env.
[Unit]
Description=Hermes Web UI
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=%h/.local/share/hermes-webui
EnvironmentFile=-%h/.local/share/hermes-webui/.env
ExecStart=/bin/bash %h/.local/share/hermes-webui/start.sh --foreground
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
EOF
    fi
    as_user systemctl --user daemon-reload
    as_user systemctl --user enable --now hermes-webui.service
}

update_app() {
    case "$1" in
        hermes)
            printf 'hermes: updating for %s\n' "$user"
            as_user "$home/.local/bin/hermes" update
            ;;
        hermes-webui)
            before=$(as_user git -C "$webui_dir" rev-parse HEAD)
            as_user git -C "$webui_dir" pull --ff-only --quiet
            after=$(as_user git -C "$webui_dir" rev-parse HEAD)
            if [[ "$before" != "$after" ]] && as_user systemctl --user is-active --quiet hermes-webui.service; then
                as_user systemctl --user restart hermes-webui.service
            fi
            ;;
        *) printf 'unknown user app: %s\n' "$1" >&2; return 2 ;;
    esac
}

install_app() {
    case "$1" in
        hermes) install_hermes ;;
        hermes-webui) install_hermes_webui ;;
        *) printf 'unknown user app: %s\n' "$1" >&2; return 2 ;;
    esac
}

case "$action" in
    present) present "${1:?app is required}" ;;
    version) version "${1:?app is required}" ;;
    install|sync)
        status=0
        for app in "$@"; do
            if present "$app"; then
                if [[ "$action" == sync ]]; then
                    update_app "$app" || status=1
                else
                    printf '%s: already installed; leaving it unchanged\n' "$app"
                fi
            else
                install_app "$app" || status=1
            fi
        done
        exit "$status"
        ;;
    *) printf 'unknown action: %s\n' "$action" >&2; exit 2 ;;
esac
