#!/usr/bin/env bash
# Bash script to restore the sandbox from a backup (Linux/macOS host).
# Windows host: use restore.ps1 instead.
# Usage:
#   ./restore.sh                 # Interactively select a backup
#   ./restore.sh before-llm      # Restores '<sandbox>-backup-before-llm.tar.gz'

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
VolumeName="$SandboxName-home"
EtcVolume="$SandboxName-etc"
OptVolume="$SandboxName-opt"
UsrLocalVolume="$SandboxName-usr-local"
BackupsDir="$SCRIPT_DIR/backups/$SandboxName"

echo "${CYAN}==============================================${RESET}"
echo "${CYAN}         Restoring Sandbox Home State         ${RESET}"
echo "${CYAN}==============================================${RESET}"
echo "${YELLOW}Sandbox: $SandboxName${RESET}"
echo "${YELLOW}Volume:  $VolumeName${RESET}"

if [ ! -d "$BackupsDir" ]; then
    echo "${YELLOW}No backups folder found at $BackupsDir.${RESET}"
    echo "${YELLOW}Use ./backup.sh to create one first.${RESET}"
    echo "${CYAN}==============================================${RESET}"
    exit 0
fi

SelectedFile=""
SpecifiedName="${1:-}"

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

echo ""
echo "${RED}WARNING: Restoring will completely overwrite the home volume, plus the${RESET}"
echo "${RED}         persisted /etc, /opt, and /usr/local volumes for this sandbox.${RESET}"
echo "${YELLOW}Target Backup: backups/$SandboxName/$Filename${RESET}"
read -r -p "Are you absolutely sure you want to restore? (y/N): " Confirm

if [ "$Confirm" != "y" ] && [ "$Confirm" != "yes" ]; then
    echo "${YELLOW}Cancelled.${RESET}"
    echo "${CYAN}==============================================${RESET}"
    exit 0
fi

# Mount each volume at its real path under /restore-stage and let the archive layout
# drive extraction. New (root-relative) archives begin with home/...; legacy archives
# are home-relative and restore into the home volume only.
read -r -d '' RESTORE_SCRIPT <<'EOF' || true
set -e
F="$1"
U="$2"
HOME_DIR="/restore-stage/home/$U"
FIRST=$(tar tzf "/backup/$F" 2>/dev/null | head -n 1)
case "$FIRST" in
  home/*)
    echo "Full archive detected; restoring home, /etc, /opt, /usr/local."
    for d in "$HOME_DIR" /restore-stage/etc /restore-stage/opt /restore-stage/usr/local; do
      find "$d" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    done
    tar xzf "/backup/$F" -C /restore-stage
    ;;
  *)
    echo "Legacy home-only archive detected; restoring home directory only."
    find "$HOME_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    tar xzf "/backup/$F" -C "$HOME_DIR"
    ;;
esac
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
if docker run --rm \
    -v "${VolumeName}:/restore-stage/home/${Username}" \
    -v "${EtcVolume}:/restore-stage/etc" \
    -v "${OptVolume}:/restore-stage/opt" \
    -v "${UsrLocalVolume}:/restore-stage/usr/local" \
    -v "${BackupsDir}:/backup:ro" \
    alpine sh -c "$RESTORE_SCRIPT" sh "$Filename" "$Username"; then

    echo "${CYAN}4/4 Restarting the workspace container...${RESET}"
    docker compose start sandbox

    echo ""
    echo "${GREEN}Restore completed successfully.${RESET}"
    echo "${GREEN}Sandbox '$SandboxName' has been rewound to: backups/$SandboxName/$Filename${RESET}"
else
    echo ""
    echo "${RED}ERROR: Restore failed.${RESET}" >&2
    echo "${YELLOW}Attempting to restart the container...${RESET}"
    restart_container
fi

echo "${CYAN}==============================================${RESET}"
