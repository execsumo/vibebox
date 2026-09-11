#!/usr/bin/env bash
# Bash script to restore the sandbox from a backup (Linux/macOS host).
# Windows host: use restore.ps1 instead.
# Usage:
#   ./restore.sh [--restore-identity]                 # Interactively select a backup
#   ./restore.sh [--restore-identity] before-llm      # Restores '<sandbox>-backup-before-llm.tar.gz'

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_PATH="$SCRIPT_DIR/.env"

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

resolve_backup_name() {
    local sandbox="$1" specified="$2"

    case "$specified" in
        */*|*\\*|*..*)
            echo "${RED}ERROR: Backup name must not contain path separators or parent-directory references.${RESET}" >&2
            exit 1
            ;;
    esac

    case "$specified" in
        "$sandbox"-backup-*.tar.gz) printf '%s' "$specified"; return ;;
        backup-*.tar.gz)            printf '%s' "$sandbox-$specified"; return ;;
    esac

    printf '%s' "$sandbox-backup-$specified.tar.gz"
}

# Validates a filename belongs to this sandbox. Returns 0 if valid.
is_valid_backup_name() {
    local sandbox="$1" filename="$2"
    [[ "$filename" =~ ^"$sandbox"-backup-[a-zA-Z0-9_-]+\.tar\.gz$ ]]
}

SandboxName="$(get_env_value SANDBOX_NAME vibebox)"
Username="$(get_env_value SANDBOX_USERNAME dev)"
# Home is either the named Docker volume (default) or, when SANDBOX_HOME_HOST_PATH
# is set in .env, a host folder bind-mounted into the sandbox.
HostHomePath="$(get_env_value SANDBOX_HOME_HOST_PATH '')"
HomeMountSource="${HostHomePath:-$SandboxName-home}"
BackupsDir="$SCRIPT_DIR/backups/$SandboxName"

echo "${CYAN}==============================================${RESET}"
echo "${CYAN}         Restoring Sandbox Home State         ${RESET}"
echo "${CYAN}==============================================${RESET}"
echo "${YELLOW}Sandbox: $SandboxName${RESET}"
echo "${YELLOW}Home:    $HomeMountSource${RESET}"

if [ ! -d "$BackupsDir" ]; then
    echo "${YELLOW}No backups folder found at $BackupsDir.${RESET}"
    echo "${YELLOW}Use ./backup.sh to create one first.${RESET}"
    echo "${CYAN}==============================================${RESET}"
    exit 0
fi

SelectedFile=""
SpecifiedName=""
RestoreIdentity=0
for arg in "$@"; do
    if [ "$arg" = "--restore-identity" ]; then
        RestoreIdentity=1
    elif [ -z "$SpecifiedName" ]; then
        SpecifiedName="$arg"
    else
        echo "${RED}ERROR: Unknown argument: $arg${RESET}" >&2
        exit 1
    fi
done

if [ -n "$SpecifiedName" ]; then
    Filename="$(resolve_backup_name "$SandboxName" "$SpecifiedName")"
    if ! is_valid_backup_name "$SandboxName" "$Filename"; then
        echo "${RED}ERROR: Backup filename is not valid for this sandbox.${RESET}" >&2
        exit 1
    fi

    SelectedFile="$BackupsDir/$Filename"
    if [ ! -f "$SelectedFile" ]; then
        echo "${RED}ERROR: Backup file not found at $SelectedFile${RESET}"
        echo "${CYAN}==============================================${RESET}"
        exit 0
    fi
else
    # Collect backups newest first.
    Backups=()
    while IFS= read -r line; do
        [ -n "$line" ] && Backups+=("$line")
    done < <(ls -1t "$BackupsDir/$SandboxName"-backup-*.tar.gz 2>/dev/null || true)

    if [ "${#Backups[@]}" -eq 0 ]; then
        echo "${YELLOW}No backups found in $BackupsDir.${RESET}"
        echo "${YELLOW}Use ./backup.sh to create one first.${RESET}"
        echo "${CYAN}==============================================${RESET}"
        exit 0
    fi

    echo ""
    echo "${YELLOW}Available backups for '$SandboxName' (newest first):${RESET}"
    for i in "${!Backups[@]}"; do
        f="${Backups[$i]}"
        SizeBytes="$(stat -c %s "$f" 2>/dev/null || stat -f %z "$f")"
        SizeMB="$(awk "BEGIN { printf \"%.2f\", $SizeBytes / 1048576 }")"
        Date="$(date -r "$f" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || stat -c %y "$f" 2>/dev/null | cut -d. -f1)"
        echo "${CYAN}  [$((i + 1))] $(basename "$f") ($SizeMB MB - $Date)${RESET}"
    done

    echo ""
    read -r -p "Select a backup number to restore (1-${#Backups[@]}) or press Enter to cancel: " Selection

    if [ -z "$Selection" ] || ! [[ "$Selection" =~ ^[0-9]+$ ]]; then
        echo "${YELLOW}Cancelled.${RESET}"
        echo "${CYAN}==============================================${RESET}"
        exit 0
    fi

    Index=$((Selection - 1))
    if [ "$Index" -lt 0 ] || [ "$Index" -ge "${#Backups[@]}" ]; then
        echo "${RED}Invalid selection. Cancelled.${RESET}"
        echo "${CYAN}==============================================${RESET}"
        exit 0
    fi

    SelectedFile="${Backups[$Index]}"
fi

Filename="$(basename "$SelectedFile")"
if ! is_valid_backup_name "$SandboxName" "$Filename"; then
    echo "${RED}ERROR: Backup filename is not valid for this sandbox.${RESET}" >&2
    exit 1
fi

HasIdentity=0
if docker run --rm -v "${BackupsDir}:/backup:ro" alpine tar tf "/backup/$Filename" 2>/dev/null | grep -q "^ssh-identity/"; then
    HasIdentity=1
fi

echo ""
echo "${RED}WARNING: Restoring will completely overwrite the home directory for this sandbox.${RESET}"
echo "${YELLOW}Target Backup: backups/$SandboxName/$Filename${RESET}"
read -r -p "Are you absolutely sure you want to restore? (y/N): " Confirm

if [ "$Confirm" != "y" ] && [ "$Confirm" != "yes" ]; then
    echo "${YELLOW}Cancelled.${RESET}"
    echo "${CYAN}==============================================${RESET}"
    exit 0
fi

# Mount home (named volume, or host folder when SANDBOX_HOME_HOST_PATH is set) at
# its real path under /restore-stage, wipe it, then extract.
# Archives are root-relative (begin with home/<user>/...).
read -r -d '' RESTORE_SCRIPT <<'EOF' || true
set -e
F="$1"
U="$2"
WIPE_IDENTITY="$3"
HOME_DIR="/restore-stage/home/$U"
find "$HOME_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
if [ "$WIPE_IDENTITY" = "1" ] && [ -d "/restore-stage/ssh-identity" ]; then
    find "/restore-stage/ssh-identity" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
fi
tar xzf "/backup/$F" -C /restore-stage
EOF

restart_container() {
    docker compose start sandbox >/dev/null 2>&1 || true
}

echo ""
echo "${CYAN}1/4 Creating pre-restore safety backup...${RESET}"
if ! "$SCRIPT_DIR/backup.sh" pre-restore; then
    echo "${RED}ERROR: Pre-restore backup failed; aborting restore.${RESET}" >&2
    echo "${CYAN}==============================================${RESET}"
    exit 1
fi

echo "${CYAN}2/4 Stopping the active workspace container...${RESET}"
if ! docker compose stop sandbox; then
    echo "${RED}ERROR: Failed to stop the workspace container.${RESET}" >&2
    echo "${CYAN}==============================================${RESET}"
    exit 1
fi

echo "${CYAN}3/4 Wiping current active files, including hidden files, and extracting backup...${RESET}"
DOCKER_ARGS=(
    "--rm"
    "-v" "${HomeMountSource}:/restore-stage/home/${Username}"
    "-v" "${BackupsDir}:/backup:ro"
)
WipeIdentity=0
if [ "$RestoreIdentity" = "1" ] && [ "$HasIdentity" = "1" ]; then
    DOCKER_ARGS+=( "-v" "${SandboxName}-ssh-keys:/restore-stage/ssh-identity" )
    WipeIdentity=1
fi

if docker run "${DOCKER_ARGS[@]}" alpine sh -c "$RESTORE_SCRIPT" sh "$Filename" "$Username" "$WipeIdentity"; then

    echo "${CYAN}4/4 Restarting the workspace container...${RESET}"
    docker compose start sandbox

    echo ""
    echo "${GREEN}Restore completed successfully.${RESET}"
    echo "${GREEN}Sandbox '$SandboxName' has been rewound to: backups/$SandboxName/$Filename${RESET}"
    if [ "$RestoreIdentity" = "1" ]; then
        if [ "$HasIdentity" = "1" ]; then
            echo "${YELLOW}Notice: Host identity was replaced. Clients will warn once about a changed host key.${RESET}"
        else
            echo "${YELLOW}Notice: Archive does not contain ssh-identity/. Existing SSH host identity was kept.${RESET}"
        fi
    else
        echo "${YELLOW}Notice: Existing SSH host identity was kept. Use --restore-identity if migrating to a new host.${RESET}"
    fi
else
    echo ""
    echo "${RED}ERROR: Restore failed.${RESET}" >&2
    echo "${YELLOW}Attempting to restart the container...${RESET}"
    restart_container
fi

echo "${CYAN}==============================================${RESET}"
