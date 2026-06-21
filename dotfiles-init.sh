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
# Each entry: "LABEL|PATH|type"  (type = file | dir)
# PATH is relative to $HOME. Dirs are symlinked whole; files are symlinked individually.
ITEMS=(
  # Shell & editor
  "Zsh config                  (.zshrc)|.zshrc|file"
  "Bash config                 (.bashrc)|.bashrc|file"
  "Git config                  (.gitconfig)|.gitconfig|file"
  "tmux config                 (.tmux.conf)|.tmux.conf|file"
  "Vim config                  (.vimrc)|.vimrc|file"
  "Nano config                 (.nanorc)|.nanorc|file"
  "EditorConfig                (.editorconfig)|.editorconfig|file"
  "curl config                 (.curlrc)|.curlrc|file"
  "wget config                 (.wgetrc)|.wgetrc|file"
  # Claude Code
  "Claude Code settings        (.claude/settings.json)|.claude/settings.json|file"
  "Claude Code global CLAUDE.md(.claude/CLAUDE.md)|.claude/CLAUDE.md|file"
  "Claude Code commands        (.claude/commands/)|.claude/commands|dir"
  # Codex
  "Codex config dir            (.codex/)|.codex|dir"
  # Antigravity (agy)
  "Antigravity settings        (.gemini/antigravity-cli/settings.json)|.gemini/antigravity-cli/settings.json|file"
  "Antigravity keybindings     (.gemini/antigravity-cli/keybindings.json)|.gemini/antigravity-cli/keybindings.json|file"
  "Antigravity MCP config      (.gemini/antigravity-cli/mcp_config.json)|.gemini/antigravity-cli/mcp_config.json|file"
  "Antigravity skills          (.gemini/antigravity-cli/skills/)|.gemini/antigravity-cli/skills|dir"
  # Oh My Pi (omp)
  "Oh My Pi config             (.omp/agent/config.yml)|.omp/agent/config.yml|file"
  "Oh My Pi MCP config         (.omp/agent/mcp.json)|.omp/agent/mcp.json|file"
  "Oh My Pi models             (.omp/agent/models.yml)|.omp/agent/models.yml|file"
  # Grok CLI
  "Grok CLI config dir         (.config/grok/)|.config/grok|dir"
)

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
DOTFILES_REPO_SSH="git@github.com:${GH_USER}/dotfiles.git"

# ── Step 2: Dotfiles repo ──────────────────────────────────────────────────────
step "Dotfiles repo"
if [ -d "$DOTFILES_DIR/.git" ]; then
  ok "Repo already cloned at ${DOTFILES_DIR} — pulling latest"
  git -C "$DOTFILES_DIR" pull --ff-only
else
  if gh repo view "${GH_USER}/dotfiles" &>/dev/null 2>&1; then
    ok "Found existing repo ${DOTFILES_REPO}"
    git clone "$DOTFILES_REPO_SSH" "$DOTFILES_DIR" 2>/dev/null || \
      git clone "$DOTFILES_REPO" "$DOTFILES_DIR"
  else
    warn "No repo found at ${DOTFILES_REPO}"
    read -rp "  Create it now? [Y/n]: " CREATE
    if [[ "${CREATE:-Y}" =~ ^[Yy]$ ]]; then
      gh repo create dotfiles --private --confirm 2>/dev/null || \
        gh repo create dotfiles --private
      git init "$DOTFILES_DIR"
      git -C "$DOTFILES_DIR" remote add origin "$DOTFILES_REPO_SSH"
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
  INPUT="${INPUT,,}"  # lowercase

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
