#!/usr/bin/env bash
# Bash script to refresh the sandbox image from scratch (Linux/macOS host).
# Windows host: use update-image.ps1 instead.
#
# This is the durable, once-in-a-while update path. The in-container `update` command is
# the fast one: it swaps tools in place without restarting anything, but it does not touch
# APT or the base image, and its changes reset on the next `docker compose down/up`. This
# script rebuilds the image so those updates stick — and picks up APT, the base image, and
# the tailscale sidecars along the way.
#
# The build runs against nothing that is live, so the long part is safe to leave running
# while you keep working. Applying the new image is what recreates the sandbox and ends
# every SSH session, tmux window, and running agent — so that step asks first.
#
# Usage:
#   ./update-image.sh              # Pull, rebuild, then ask before restarting
#   ./update-image.sh --yes        # Same, but apply without asking (unattended/scheduled)
#   ./update-image.sh --build-only # Pull and rebuild, never apply

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_PATH="$SCRIPT_DIR/.env"

if [ -t 1 ]; then
    CYAN=$'\033[36m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; GRAY=$'\033[90m'; RESET=$'\033[0m'
else
    CYAN=''; GREEN=''; YELLOW=''; RED=''; GRAY=''; RESET=''
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
ImageRef="$SandboxName:latest"

AutoYes=0
BuildOnly=0
for arg in "$@"; do
    if [ "$arg" = "--yes" ]; then AutoYes=1
    elif [ "$arg" = "--build-only" ]; then BuildOnly=1
    else
        echo "${RED}ERROR: Unknown argument: $arg${RESET}" >&2
        exit 1
    fi
done

cd "$SCRIPT_DIR"

TOTAL=4

echo "${CYAN}==============================================${RESET}"
echo "${CYAN}         Refreshing the Sandbox Image         ${RESET}"
echo "${CYAN}==============================================${RESET}"
echo "Sandbox:     ${YELLOW}$SandboxName${RESET}"
echo "Image:       ${YELLOW}$ImageRef${RESET}"
echo ""

# The image id before the build, so the summary can say whether anything actually changed.
OldImageId="$(docker image inspect --format '{{.Id}}' "$ImageRef" 2>/dev/null || true)"

echo "${CYAN}1/$TOTAL Pulling sidecar images...${RESET}"
# The two tailscale containers come from an upstream image rather than this Dockerfile,
# so they update by pull, not by build.
#
# --ignore-buildable is required, not cosmetic: a bare `docker compose pull` also tries to
# pull the `sandbox` service, which is built from the local Dockerfile and exists in no
# registry. That fails with "pull access denied for vibebox" and, under `set -e`, kills
# this script before it ever reaches the build. The flag skips any service with a `build:`
# section, so adding another built service later needs no change here.
docker compose pull --ignore-buildable
echo ""

echo "${CYAN}2/$TOTAL Rebuilding the sandbox image (this takes a while)...${RESET}"
echo "${GRAY}    --no-cache is deliberate: without it Docker reuses the cached APT and npm${RESET}"
echo "${GRAY}    layers and the rebuild silently updates nothing. Expect ~10-15 minutes,${RESET}"
echo "${GRAY}    most of it recompiling docling's torch dependency.${RESET}"
echo "${GRAY}    Nothing running is touched by this step.${RESET}"
# --pull refreshes the base image too. A build failure stops the script here, before the
# apply step: the Dockerfile's final stage verifies the toolchain and hard-fails if a
# daily-driver tool is missing or cannot run, so a broken build never becomes a running
# container and the existing one keeps serving.
if ! docker compose build --no-cache --pull sandbox; then
    echo ""
    echo "${RED}ERROR: Image build failed. Nothing was applied — the running sandbox is untouched.${RESET}" >&2
    echo "${CYAN}==============================================${RESET}"
    exit 1
fi
echo ""

NewImageId="$(docker image inspect --format '{{.Id}}' "$ImageRef" 2>/dev/null || true)"
NewImageCreated="$(docker image inspect --format '{{.Created}}' "$ImageRef" 2>/dev/null || echo unknown)"

echo "${CYAN}3/$TOTAL Build result${RESET}"
echo "Built:       ${YELLOW}$NewImageCreated${RESET}"
if [ -z "$OldImageId" ]; then
    echo "Status:      ${YELLOW}new image (nothing to compare against)${RESET}"
elif [ "$OldImageId" = "$NewImageId" ]; then
    echo "Status:      ${YELLOW}identical to the running image — nothing changed upstream${RESET}"
else
    echo "Status:      ${GREEN}new image differs from the one in use${RESET}"
    echo "${GRAY}    old ${OldImageId:7:12}  ->  new ${NewImageId:7:12}${RESET}"
fi
echo ""

if [ "$BuildOnly" -eq 1 ]; then
    echo "${YELLOW}--build-only: stopping here. Apply it whenever you are ready:${RESET}"
    echo "    docker compose up -d"
    echo "${CYAN}==============================================${RESET}"
    exit 0
fi

if [ "$AutoYes" -ne 1 ]; then
    echo "${YELLOW}Applying this image recreates the sandbox container.${RESET}"
    echo "${YELLOW}Every SSH session, tmux window, and running agent inside it will end.${RESET}"
    echo "${GRAY}    Your home directory and Tailscale identity are on volumes and survive.${RESET}"
    printf '%s' "Apply now? [y/N] "
    # `|| Reply=""` so a non-interactive run (no stdin) declines cleanly instead of
    # tripping `set -e` with an unexplained exit. Use --yes to apply unattended.
    read -r Reply || Reply=""
    case "$Reply" in
        [yY]|[yY][eE][sS]) ;;
        *)
            echo ""
            echo "${YELLOW}Not applied. The new image is built and waiting — apply it when ready:${RESET}"
            echo "    docker compose up -d"
            echo "${CYAN}==============================================${RESET}"
            exit 0
            ;;
    esac
    echo ""
fi

echo "${CYAN}4/$TOTAL Applying the new image...${RESET}"
docker compose up -d
echo ""
docker compose ps
echo ""
echo "${GREEN}Sandbox image refreshed and running.${RESET}"
echo "${GRAY}    The Hermes WebUI is started by the entrypoint; check with${RESET}"
echo "${GRAY}    'hermes-webui status' once you are back inside the box.${RESET}"
echo "${CYAN}==============================================${RESET}"
