#!/usr/bin/env bash
# Install and update pre-installed user applications without taking ownership
# of their configuration. Updates use each application's own upstream method.
#
# Usage: user-apps.sh install <user> <app>...
#        user-apps.sh sync <user> <app>...
#        user-apps.sh remove <user> <app>
#        user-apps.sh present <user> <app>
#        user-apps.sh version <user> <app>
# Apps:  hermes, hermes-webui, deepseek-harness

set -Eeuo pipefail

HERMES_INSTALLER=https://hermes-agent.nousresearch.com/install.sh
WEBUI_REPO=https://github.com/nesquena/hermes-webui.git
DSH_PACKAGE=@deepseek-ai/dsh

action=${1:?action is required}
user=${2:?user is required}
shift 2
home=$(getent passwd "$user" | cut -d: -f6)
[[ -n "$home" ]] || { printf 'no such user: %s\n' "$user" >&2; exit 1; }
webui_dir="$home/.local/share/hermes-webui"
webui_unit="$home/.config/systemd/user/hermes-webui.service"
dsh_dir="$home/.local/share/deepseek-harness"
dsh_unit="$home/.config/systemd/user/deepseek-harness.service"

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
        deepseek-harness) [[ -x "$dsh_dir/bin/dsh" ]] ;;
        *) printf 'unknown user app: %s\n' "$1" >&2; return 2 ;;
    esac
}

version() {
    present "$1" || return 1
    case "$1" in
        hermes) as_user "$home/.local/bin/hermes" --version 2>/dev/null | head -n 1 ;;
        hermes-webui) as_user git -C "$webui_dir" log -1 --format='hermes-webui %h (%cs)' ;;
        deepseek-harness)
            as_user node -p "'deepseek-harness ' + require('$dsh_dir/node_modules/@deepseek-ai/dsh/package.json').version"
            ;;
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

# DeepSeek Harness is an npm package (@deepseek-ai/dsh) with a Web UI that
# `dsh web` serves on 127.0.0.1:3080. It is installed into the user's own
# prefix, not globally, so the root-owned copy is never created. The package
# declares Node.js >= 24.9 while the guest's toolchain is NODE_MAJOR; refuse
# to install on an older runtime rather than leave a service that cannot start.
install_deepseek_harness() {
    if ! as_user node -e 'const [major, minor] = process.versions.node.split(".").map(Number); process.exit(major > 24 || (major === 24 && minor >= 9) ? 0 : 1)'; then
        printf 'deepseek-harness: needs Node.js 24.9 or newer; found %s for %s\n' "$(as_user node --version)" "$user" >&2
        return 1
    fi
    printf 'deepseek-harness: installing for %s from %s\n' "$user" "$DSH_PACKAGE"
    as_user install -d "$dsh_dir" "$(dirname "$dsh_unit")"
    as_user npm install --prefix "$dsh_dir" --no-fund --no-audit "$DSH_PACKAGE@latest"
    if [[ ! -e "$dsh_unit" ]]; then
        as_user tee "$dsh_unit" >/dev/null <<'EOF'
# Installed once by vibebox (guest/user-apps.sh); yours to edit from here on.
# The Web UI listens on 127.0.0.1:3080. Pass --host or --port to ExecStart to change it.
[Unit]
Description=DeepSeek Harness Web UI
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=%h
ExecStart=%h/.local/share/deepseek-harness/bin/dsh web --no-open
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
EOF
    fi
    as_user systemctl --user daemon-reload
    as_user systemctl --user enable --now deepseek-harness.service
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
        deepseek-harness)
            before=$(version deepseek-harness)
            as_user npm install --prefix "$dsh_dir" --no-fund --no-audit "$DSH_PACKAGE@latest"
            after=$(version deepseek-harness)
            if [[ "$before" != "$after" ]] && as_user systemctl --user is-active --quiet deepseek-harness.service; then
                as_user systemctl --user restart deepseek-harness.service
            fi
            ;;
        *) printf 'unknown user app: %s\n' "$1" >&2; return 2 ;;
    esac
}

install_app() {
    case "$1" in
        hermes) install_hermes ;;
        hermes-webui) install_hermes_webui ;;
        deepseek-harness) install_deepseek_harness ;;
        *) printf 'unknown user app: %s\n' "$1" >&2; return 2 ;;
    esac
}

# Removes the application's code and launcher and stops its service. Data the
# user made is kept: ~/.hermes (configuration, sessions, memory), the WebUI's
# .env, and the unit files, which the user may have edited. Those are named
# in the output so the user can delete them by hand if they want them gone.
remove_app() {
    case "$1" in
        hermes)
            [[ -x "$home/.local/bin/hermes" ]] && as_user "$home/.local/bin/hermes" gateway stop >/dev/null 2>&1 || true
            as_user rm -rf "$home/.hermes/hermes-agent" "$home/.local/bin/hermes"
            printf 'hermes: removed the agent and launcher; kept %s/.hermes configuration\n' "$home"
            ;;
        hermes-webui)
            as_user systemctl --user disable --now hermes-webui.service >/dev/null 2>&1 || true
            as_user rm -rf "$webui_dir"
            printf 'hermes-webui: removed the checkout; kept %s (disabled)\n' "$webui_unit"
            ;;
        deepseek-harness)
            as_user systemctl --user disable --now deepseek-harness.service >/dev/null 2>&1 || true
            as_user rm -rf "$dsh_dir"
            printf 'deepseek-harness: removed the package; kept %s (disabled)\n' "$dsh_unit"
            ;;
        *) printf 'unknown user app: %s\n' "$1" >&2; return 2 ;;
    esac
}

case "$action" in
    present) present "${1:?app is required}" ;;
    version) version "${1:?app is required}" ;;
    remove) remove_app "${1:?app is required}" ;;
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
