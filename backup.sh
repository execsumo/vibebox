#!/usr/bin/env bash
# Bash script to take a backup of the sandbox workspace (Linux/macOS host).
# Windows host: use backup.ps1 instead.
# Usage:
#   ./backup.sh                 # Creates a timestamped backup
#   ./backup.sh before-llm      # Creates '<sandbox>-backup-before-llm.tar.gz'

set -euo pipefail

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

SandboxName="$(get_env_value SANDBOX_NAME vibebox)"
Username="$(get_env_value SANDBOX_USERNAME dev)"
VolumeName="$SandboxName-home"
RetentionDays="$(get_env_value BACKUP_RETENTION_DAYS 7)"
BackupsDir="$SCRIPT_DIR/backups/$SandboxName"

mkdir -p "$BackupsDir"

Name="${1:-}"
if [ -z "$Name" ]; then
    Timestamp="$(date +%Y%m%d-%H%M%S)"
    Filename="$SandboxName-backup-$Timestamp.tar.gz"
else
    Sanitized="$(printf '%s' "$Name" | tr -cd 'a-zA-Z0-9_-')"
    if [ -z "$Sanitized" ]; then
        echo "${RED}ERROR: Backup label must contain at least one letter, number, underscore, or dash.${RESET}" >&2
        exit 1
    fi
    Filename="$SandboxName-backup-$Sanitized.tar.gz"
fi

BackupPath="$BackupsDir/$Filename"

echo "${CYAN}==============================================${RESET}"
echo "${CYAN}         Creating Sandbox Home Backup         ${RESET}"
echo "${CYAN}==============================================${RESET}"
echo "${YELLOW}Sandbox:     $SandboxName${RESET}"
echo "${YELLOW}Volume:      $VolumeName${RESET}"
echo "${YELLOW}Backup File: backups/$SandboxName/$Filename${RESET}"
echo "${YELLOW}Retention:   $RetentionDays days${RESET}"

# Mount the home volume at its real path under a staging root (/stage) so the
# archive is root-relative (home/<user>/...) and matches the in-container `backup`
# command. restore.sh extracts it back. .vibebox holds root-owned SSH host keys the
# volume already persists, so it is excluded.
if docker run --rm \
    -v "${VolumeName}:/stage/home/${Username}:ro" \
    -v "${BackupsDir}:/backup" \
    alpine tar czf "/backup/$Filename" --exclude="home/${Username}/.vibebox" -C /stage "home/${Username}"; then

    if [ ! -f "$BackupPath" ]; then
        echo ""
        echo "${RED}ERROR: Backup file was not created successfully.${RESET}" >&2
        echo "${CYAN}==============================================${RESET}"
        exit 1
    fi

    # Prune only timestamped backups (-backup-YYYYMMDD-HHMMSS.tar.gz), so labeled
    # safety snapshots (before-refactor, pre-restore, auto-before-update) are kept.
    # The timestamp is matched with a portable glob (GNU find lacks BSD/macOS
    # -regextype), so this works on Linux and macOS hosts alike.
    ts='[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]'
    find "$BackupsDir" -maxdepth 1 -type f \
        -name "$SandboxName-backup-$ts.tar.gz" \
        -mtime "+$RetentionDays" -delete

    SizeBytes="$(stat -c %s "$BackupPath" 2>/dev/null || stat -f %z "$BackupPath")"
    SizeMB="$(awk "BEGIN { printf \"%.2f\", $SizeBytes / 1048576 }")"
    echo ""
    echo "${GREEN}Backup created successfully.${RESET}"
    echo "${GREEN}Location:  $BackupPath${RESET}"
    echo "${GREEN}File Size: $SizeMB MB${RESET}"
else
    echo ""
    echo "${RED}ERROR: Failed to create backup.${RESET}" >&2
    echo "${CYAN}==============================================${RESET}"
    exit 1
fi

echo "${CYAN}==============================================${RESET}"
