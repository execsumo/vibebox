#!/usr/bin/env bash
# Bash script to set up and launch the sandbox container (Linux/macOS host).
# Windows host: use setup-sandbox.ps1 instead.
# Usage:
#   ./setup-sandbox.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_PATH="$SCRIPT_DIR/.env"

# Colors (fall back to no color if not a terminal).
if [ -t 1 ]; then
    CYAN=$'\033[36m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; RESET=$'\033[0m'
else
    CYAN=''; GREEN=''; YELLOW=''; RED=''; RESET=''
fi

get_env_value() {
    local name="$1" default="$2" line val
    if [ -f "$ENV_PATH" ]; then
        line="$(grep -E "^[[:space:]]*$name[[:space:]]*=" "$ENV_PATH" | head -n1 || true)"
        if [ -n "$line" ]; then
            val="${line#*=}"
            val="$(printf '%s' "$val" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
            printf '%s' "$val"
            return
        fi
    fi
    printf '%s' "$default"
}

echo "${CYAN}==============================================${RESET}"
echo "${CYAN}         Setting up Sandbox Container         ${RESET}"
echo "${CYAN}==============================================${RESET}"

# 1. Parse settings from .env file
Username="$(get_env_value SANDBOX_USERNAME dev)"
SandboxName="$(get_env_value SANDBOX_NAME vibebox)"
SshPort="$(get_env_value SANDBOX_SSH_PORT 22)"

# 2. Require a Tailscale auth key before doing any expensive work.
#    Interactive login is not a viable fallback here: without a key the tailscale
#    container exits and crash-loops, orphaning the network namespace the sandbox
#    shares with it, which breaks even local SSH. Fail now rather than after a
#    multi-minute image build. A shell env var wins over .env, matching Compose.
AuthKey="${TS_AUTHKEY:-$(get_env_value TS_AUTHKEY '')}"
case "$AuthKey" in
    tskey-*) echo "${GREEN}Tailscale auth key found.${RESET}" ;;
    *)
        echo ""
        echo "${RED}ERROR: TS_AUTHKEY is not set (or does not look like a Tailscale key).${RESET}"
        echo ""
        echo "${CYAN}  The sandbox shares its network namespace with the tailscale container,${RESET}"
        echo "${CYAN}  so an unauthenticated tailscale takes SSH down with it.${RESET}"
        echo ""
        echo "${YELLOW}  1. Generate a key at: https://login.tailscale.com/admin/settings/keys${RESET}"
        echo "     (recommended: Reusable + Ephemeral, tagged tag:vibebox)"
        echo "${YELLOW}  2. Add it to .env as:  TS_AUTHKEY=tskey-auth-...${RESET}"
        echo "${YELLOW}  3. Re-run this script.${RESET}"
        echo ""
        if [ ! -f "$ENV_PATH" ]; then
            echo "${YELLOW}  No .env found. Start from the template:  cp .env.example .env${RESET}"
            echo ""
        fi
        exit 1
        ;;
esac

# 3. Ensure authorized_keys file exists
AuthKeysPath="$SCRIPT_DIR/authorized_keys"

if [ ! -s "$AuthKeysPath" ]; then
    echo "${YELLOW}No active 'authorized_keys' file found. Looking for your SSH keys...${RESET}"

    UserSshDir="$HOME/.ssh"
    FoundKey=false

    if [ -d "$UserSshDir" ]; then
        for KeyFile in id_ed25519.pub id_rsa.pub; do
            FullPath="$UserSshDir/$KeyFile"
            if [ -f "$FullPath" ]; then
                echo "${GREEN}Found public key at $FullPath. Importing it to sandbox authorized_keys...${RESET}"
                cp "$FullPath" "$AuthKeysPath"
                FoundKey=true
                break
            fi
        done
    fi

    if [ "$FoundKey" = false ]; then
        echo ""
        echo "${YELLOW}WARNING: Could not find a default public SSH key on your host.${RESET}"
        echo "${YELLOW}Please paste your public key in the newly created 'authorized_keys' file in this folder,${RESET}"
        echo "${YELLOW}then re-run this script.${RESET}"
        echo ""
        # Create an empty file so the mount doesn't fail
        : > "$AuthKeysPath"
    fi
else
    echo "${GREEN}'authorized_keys' file already exists and is configured.${RESET}"
fi

# 4. Write/refresh a local SSH alias so you can connect with `ssh <SandboxName>`.
#    Uses 127.0.0.1 (not localhost): the port is published IPv4-only, and on a
#    Windows host localhost resolves to ::1 first. Idempotent: a marked block per sandbox.
SshConfigDir="$HOME/.ssh"
SshConfigPath="$SshConfigDir/config"
BeginMarker=">>> sandbox alias: $SandboxName (managed by setup-sandbox) >>>"
EndMarker="<<< sandbox alias: $SandboxName <<<"
mkdir -p "$SshConfigDir"; chmod 700 "$SshConfigDir"
touch "$SshConfigPath"; chmod 600 "$SshConfigPath"
# Remove any previous managed block for this sandbox (markers included), then strip
# trailing blank lines so we re-append cleanly.
TmpConfig="$(mktemp)"
awk -v b="# $BeginMarker" -v e="# $EndMarker" '
    $0 == b { skip = 1; next }
    skip && $0 == e { skip = 0; next }
    !skip { print }
' "$SshConfigPath" | awk '
    { lines[NR] = $0 }
    END { last = NR; while (last > 0 && lines[last] ~ /^[[:space:]]*$/) last--; for (i = 1; i <= last; i++) print lines[i] }
' > "$TmpConfig"
mv "$TmpConfig" "$SshConfigPath"
chmod 600 "$SshConfigPath"
[ -s "$SshConfigPath" ] && echo "" >> "$SshConfigPath"
{
    echo "# $BeginMarker"
    echo "Host $SandboxName"
    echo "    HostName 127.0.0.1"
    echo "    Port $SshPort"
    echo "    User $Username"
    echo "# $EndMarker"
} >> "$SshConfigPath"
echo "${GREEN}Configured SSH alias 'Host $SandboxName' -> 127.0.0.1:$SshPort in $SshConfigPath${RESET}"

# 5. Build and launch the container stack
echo ""
echo "${CYAN}Building and launching container stack via Docker Compose...${RESET}"
docker compose up -d --build

# 6. Check status and output connection guide
echo ""
echo "${CYAN}Checking container status...${RESET}"
ContainerStatus="$(docker compose ps --format json 2>/dev/null || true)"

if [ -n "$ContainerStatus" ]; then
    # Ask tailscale for the tailnet suffix so the remote hint is a real FQDN. The
    # bare name only resolves on devices that accept Tailscale DNS; the FQDN always
    # does. Best-effort: fall back to the short name if the node isn't up yet.
    TailnetFqdn="$SandboxName"
    Suffix="$(docker exec "$SandboxName-tailscale" tailscale status --json 2>/dev/null \
        | grep -o '"MagicDNSSuffix": *"[^"]*"' | head -n1 | sed 's/.*"\([^"]*\)"$/\1/' || true)"
    [ -n "$Suffix" ] && TailnetFqdn="$SandboxName.$Suffix"

    echo "${GREEN}==============================================${RESET}"
    echo "${GREEN}      Container is Running Successfully!      ${RESET}"
    echo "${GREEN}==============================================${RESET}"
    echo ""
    echo "${YELLOW}Step 1: Connect to your sandbox${RESET}"
    echo "${CYAN}  A. From this host:${RESET}"
    echo "${YELLOW}     ssh $SandboxName${RESET}"
    echo "       (alias added to ~/.ssh/config; same as: ssh -p $SshPort ${Username}@127.0.0.1)"
    echo ""
    echo "${CYAN}  B. From any device on your Tailnet:${RESET}"
    echo "${YELLOW}     ssh ${Username}@$TailnetFqdn${RESET}"
    echo "       (or 'ssh ${Username}@$SandboxName' on devices using Tailscale DNS)"
    echo ""
    echo "${YELLOW}Step 2: First-time setup (once per sandbox)${RESET}"
    echo "${CYAN}  In the SSH session, run:${RESET}"
    echo "${YELLOW}     onboard${RESET}"
    echo "${CYAN}  Wires up GitHub auth, git identity, dotfiles, RTK, and CodeGraph.${RESET}"
    echo ""
    echo "${YELLOW}Step 3: Launch your workspace${RESET}"
    echo "${CYAN}  Every login, run:${RESET}"
    echo "${YELLOW}     launch${RESET}"
    echo "${CYAN}  This places you in a persistent Herdr workspace.${RESET}"
else
    echo "${RED}Failed to start the container. Please verify Docker is running.${RESET}"
fi
echo "${CYAN}==============================================${RESET}"
