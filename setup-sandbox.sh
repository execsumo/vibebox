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
SshPort="$(get_env_value SSH_PORT 22)"

# 2. Ensure authorized_keys file exists
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

# 3. Write/refresh a local SSH alias so you can connect with `ssh <SandboxName>`.
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

# 4. Build and launch the container stack
echo ""
echo "${CYAN}Building and launching container stack via Docker Compose...${RESET}"
docker compose up -d --build

# 5. Check status and output connection guide
echo ""
echo "${CYAN}Checking container status...${RESET}"
ContainerStatus="$(docker compose ps --format json 2>/dev/null || true)"

if [ -n "$ContainerStatus" ]; then
    echo "${GREEN}==============================================${RESET}"
    echo "${GREEN}      Container is Running Successfully!      ${RESET}"
    echo "${GREEN}==============================================${RESET}"
    echo ""
    echo "${YELLOW}Step 1: Authenticate Tailscale (If not already authenticated)${RESET}"
    echo "${CYAN}  To authorize your sandbox on your Tailnet, run:${RESET}"
    echo "${YELLOW}    docker logs $SandboxName-tailscale${RESET}"
    echo "${CYAN}  and click the authentication URL in the log output.${RESET}"
    echo ""
    echo "${YELLOW}Step 2: Connect to your sandbox${RESET}"
    echo "${CYAN}  A. Local Connection (from this host):${RESET}"
    echo "${YELLOW}     ssh $SandboxName${RESET}"
    echo "       (alias added to ~/.ssh/config; same as: ssh -p $SshPort ${Username}@127.0.0.1)"
    echo ""
    echo "${CYAN}  B. Remote Connection (from any device on your Tailnet):${RESET}"
    echo "${YELLOW}     ssh ${Username}@$SandboxName${RESET}"
    echo ""
    echo "${YELLOW}Step 3: Launch your Workspace${RESET}"
    echo "${CYAN}  Once logged into the SSH session, run the ultimate workspace launcher:${RESET}"
    echo "${YELLOW}     launch${RESET}"
    echo "${CYAN}  This places you in a persistent Herdr workspace.${RESET}"
else
    echo "${RED}Failed to start the container. Please verify Docker is running.${RESET}"
fi
echo "${CYAN}==============================================${RESET}"
