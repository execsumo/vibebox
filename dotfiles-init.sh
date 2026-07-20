#!/usr/bin/env bash
# dotfiles-init.sh — Bootstrap your dotfiles repo from this machine.
# Run once on the machine whose config you want to use as the source of truth.
# Safe to re-run: already-linked files are skipped.
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

step() { echo -e "\n${CYAN}==>${RESET} ${BOLD}$*${RESET}"; }
ok()   { echo -e "  ${GREEN}✓${RESET} $*"; }
warn() { echo -e "  ${YELLOW}!${RESET} $*"; }
info() { echo -e "    $*"; }

# ── Supported items ────────────────────────────────────────────────────────────
# The supported dotfiles come from the shared manifest (dotfiles.manifest), which
# the container's onboard script reads too — one list, kept in sync automatically.
# Manifest format is "type|relpath|label"; internally we use "LABEL|PATH|type"
# (item_label/item_path/item_type read fields 1/2/3), so we reorder while reading.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$SCRIPT_DIR/dotfiles.manifest"

if [ ! -f "$MANIFEST" ]; then
  echo "ERROR: dotfiles manifest not found at $MANIFEST" >&2
  exit 1
fi

ITEMS=()
while IFS='|' read -r TYPE REL LABEL; do
  ITEMS+=("$LABEL|$REL|$TYPE")
done < <(grep -vE '^[[:space:]]*(#|$)' "$MANIFEST")

DOTFILES_DIR="$HOME/.dotfiles"

# ── Helpers ────────────────────────────────────────────────────────────────────
item_label() { echo "${ITEMS[$1]}" | cut -d'|' -f1; }
item_path()  { echo "${ITEMS[$1]}" | cut -d'|' -f2; }
item_type()  { echo "${ITEMS[$1]}" | cut -d'|' -f3; }

item_exists() {
  local p="$HOME/$(item_path "$1")"
  [ -e "$p" ] || [ -L "$p" ]
}

item_linked() {
  local p="$HOME/$(item_path "$1")"
  local target="$DOTFILES_DIR/$(item_path "$1")"
  [ -L "$p" ] && [ "$(readlink "$p")" = "$target" ]
}

print_menu() {
  echo ""
  local i
  for i in "${!ITEMS[@]}"; do
    local exists_marker=""
    if ! item_exists "$i"; then
      exists_marker=" ${YELLOW}(not found on this machine)${RESET}"
    elif item_linked "$i"; then
      exists_marker=" ${GREEN}(already linked)${RESET}"
    fi
    if [ "${SELECTED[$i]}" = "1" ]; then
      printf "  ${GREEN}[x]${RESET} %2d. %s%b\n" "$((i+1))" "$(item_label "$i")" "$exists_marker"
    else
      printf "  [ ] %2d. %s%b\n" "$((i+1))" "$(item_label "$i")" "$exists_marker"
    fi
  done
  echo ""
  echo -e "  ${BOLD}a${RESET} = select all   ${BOLD}n${RESET} = select none   ${BOLD}done${RESET} = confirm and proceed"
  echo ""
}

# ── Step 1: GitHub CLI auth ────────────────────────────────────────────────────
step "GitHub CLI authentication"
if ! command -v gh &>/dev/null; then
  echo "ERROR: gh CLI is not installed. Install it from https://cli.github.com then re-run."
  exit 1
fi

if gh auth status &>/dev/null; then
  GH_USER=$(gh api /user --jq '.login')
  ok "Authenticated as ${GH_USER}"
else
  gh auth login
  GH_USER=$(gh api /user --jq '.login')
  ok "Authenticated as ${GH_USER}"
fi

DOTFILES_REPO="https://github.com/${GH_USER}/dotfiles"

# ── Step 2: Dotfiles repo ──────────────────────────────────────────────────────
# HTTPS only: gh already sets up a git credential helper on login, so this
# works without requiring an SSH key to be registered on the account.
step "Dotfiles repo"
if [ -d "$DOTFILES_DIR/.git" ]; then
  ok "Repo already cloned at ${DOTFILES_DIR}"
  if ! git -C "$DOTFILES_DIR" rev-parse --verify -q HEAD >/dev/null; then
    warn "No commits yet — skipping pull (this run will create the first commit)"
  elif ! git -C "$DOTFILES_DIR" rev-parse --abbrev-ref -q '@{u}' >/dev/null 2>&1; then
    warn "No upstream tracking branch yet — skipping pull"
  else
    info "Pulling latest"
    git -C "$DOTFILES_DIR" pull --ff-only
  fi
else
  if gh repo view "${GH_USER}/dotfiles" &>/dev/null 2>&1; then
    ok "Found existing repo ${DOTFILES_REPO}"
    git clone "$DOTFILES_REPO" "$DOTFILES_DIR"
  else
    warn "No repo found at ${DOTFILES_REPO}"
    read -rp "  Create it now? [Y/n]: " CREATE
    if [[ "${CREATE:-Y}" =~ ^[Yy]$ ]]; then
      gh repo create dotfiles --private --confirm 2>/dev/null || \
        gh repo create dotfiles --private
      git init -b main "$DOTFILES_DIR"
      git -C "$DOTFILES_DIR" remote add origin "$DOTFILES_REPO"
      ok "Created private repo and initialized ${DOTFILES_DIR}"
    else
      echo "Aborted."
      exit 0
    fi
  fi
fi

# ── Step 3: Interactive checklist ─────────────────────────────────────────────
step "Select files to add to your dotfiles repo"
info "Only files that exist on this machine are shown as selectable."
info "Items already symlinked to the repo are marked (already linked)."

# Default: select all items that exist and are not yet linked
declare -a SELECTED
for i in "${!ITEMS[@]}"; do
  if item_exists "$i" && ! item_linked "$i"; then
    SELECTED[$i]="1"
  else
    SELECTED[$i]="0"
  fi
done

while true; do
  print_menu
  read -rp "  Toggle [1-${#ITEMS[@]}], a, n, or done: " INPUT
  INPUT="$(echo "$INPUT" | tr '[:upper:]' '[:lower:]')"  # lowercase

  if [ "$INPUT" = "done" ]; then
    break
  elif [ "$INPUT" = "a" ]; then
    for i in "${!ITEMS[@]}"; do
      item_exists "$i" && SELECTED[$i]="1"
    done
  elif [ "$INPUT" = "n" ]; then
    for i in "${!ITEMS[@]}"; do SELECTED[$i]="0"; done
  elif [[ "$INPUT" =~ ^[0-9]+$ ]]; then
    IDX=$((INPUT - 1))
    if [ "$IDX" -ge 0 ] && [ "$IDX" -lt "${#ITEMS[@]}" ]; then
      if item_exists "$IDX"; then
        [ "${SELECTED[$IDX]}" = "1" ] && SELECTED[$IDX]="0" || SELECTED[$IDX]="1"
      else
        warn "$(item_label "$IDX") — not found on this machine, skipping"
      fi
    else
      warn "Invalid number"
    fi
  else
    warn "Unrecognised input: ${INPUT}"
  fi
done

# ── Step 4: Move files into repo and symlink back ──────────────────────────────
step "Linking files"
ADDED=()

for i in "${!ITEMS[@]}"; do
  [ "${SELECTED[$i]}" != "1" ] && continue

  REL="$(item_path "$i")"
  TYPE="$(item_type "$i")"
  SRC="$HOME/$REL"
  DEST="$DOTFILES_DIR/$REL"

  if item_linked "$i"; then
    ok "${REL} — already linked, skipping"
    continue
  fi

  # Create parent dir in repo if needed
  mkdir -p "$(dirname "$DEST")"

  if [ "$TYPE" = "dir" ]; then
    if [ -d "$SRC" ] && [ ! -L "$SRC" ]; then
      mv "$SRC" "$DEST"
      ln -sf "$DEST" "$SRC"
      ok "${REL}/ — moved to repo, symlinked"
      ADDED+=("$REL")
    elif [ -L "$SRC" ]; then
      warn "${REL}/ — already a symlink, skipping"
    fi
  else
    if [ -f "$SRC" ] && [ ! -L "$SRC" ]; then
      mv "$SRC" "$DEST"
      ln -sf "$DEST" "$SRC"
      ok "${REL} — moved to repo, symlinked"
      ADDED+=("$REL")
    elif [ -L "$SRC" ]; then
      warn "${REL} — already a symlink, skipping"
    fi
  fi
done

if [ ${#ADDED[@]} -eq 0 ]; then
  echo ""
  warn "Nothing new to commit — all selected items were already linked or skipped."
  exit 0
fi

# ── Step 5: Commit and push ────────────────────────────────────────────────────
step "Committing and pushing"
git -C "$DOTFILES_DIR" add "${ADDED[@]}"
git -C "$DOTFILES_DIR" commit -m "dotfiles: add ${ADDED[*]}"
git -C "$DOTFILES_DIR" push -u origin HEAD

echo ""
echo "================================================"
echo "  Dotfiles pushed to ${DOTFILES_REPO}"
echo "  Run 'onboard' on any vibebox to pull them in."
echo "================================================"
echo ""
