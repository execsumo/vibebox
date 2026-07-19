# Adding Tools to Vibebox

This document explains where each piece lives and what to touch when you add a new tool.

---

## Files to update

| File | What changes |
|---|---|
| `Dockerfile` | Install step + build verification (step 9b) |
| `scripts/onboard` | Per-user config step, if the tool has one (see below) |
| `scripts/update` | Add an update step for the tool (real file, not a heredoc) |
| `.env.example` | API key variable (if the tool needs one) |
| `dotfiles.manifest` | One line per new dotfile path (if the tool has config) |
| `README.md` | Coding tools table + dotfiles section + API Keys section (if needed) |

The in-container commands (`onboard`, `backup`, `update`, `launch`) and the `entrypoint` are real files in `scripts/`, `COPY`'d to `/usr/local/bin` by the Dockerfile — edit them directly. Dotfile paths live in a single `dotfiles.manifest` at the repo root; both `dotfiles-init.sh` (host) and `onboard` (container) read it, so there is only one list to maintain.

If a tool is one you depend on daily, add it to the hard-fail loop in the Dockerfile's step 9b verification (`for t in claude codex bun node gh`); optional agents go in the warn loop. Anything installed with a tolerated (`|| echo ...`) step belongs in the warn loop — a hard-fail check on a tolerated install just relocates the build break.


## Install step patterns

### npm global package
Add the package name to the existing `npm install -g` block (step 4). Add a matching `ARG` at the top and use `@scope/package@${VERSION_ARG}`.

```dockerfile
ARG MY_TOOL_VERSION=latest

RUN npm install -g \
    ...
    my-tool@${MY_TOOL_VERSION} \
    && npm cache clean --force
```

### Official install script
Add a numbered step after the last tool install, before step 8 (SSH config). Copy the binary to `/usr/local/bin` so it is on `$PATH` for all users. Wrap in `(... ) || echo "..."` so a transient network failure doesn't break the whole build.

```dockerfile
# N. Install ToolName via the official installer
RUN (curl -fsSL https://example.com/install.sh | bash && \
     (cp /root/.local/bin/toolname /usr/local/bin/toolname 2>/dev/null || true) && \
     chmod +x /usr/local/bin/toolname 2>/dev/null) || echo "ToolName setup skipped"
```

### apt package
Add to the existing `apt-get install -y` block (step 1).

### Tools with a per-user configuration step
Some tools ship a `<tool> install` / `<tool> init` step that writes into `$HOME` (agent
config, MCP registration, auth). **Do not run these in the Dockerfile.** The build runs as
root, and `/home/<user>` is a persisted volume that masks image content on rebuilds — so
build-time writes never reach the sandbox user.

Install the binary in the Dockerfile, then run the config step from `scripts/onboard`,
which executes as the sandbox user inside the container. It lands in the home volume and
survives rebuilds. Guard it with a marker file under `~/.vibebox/` so re-running `onboard`
stays idempotent, and keep the failure path non-fatal — `onboard` runs under
`set -euo pipefail`, so use `if cmd; then ... else warn ...; fi` rather than a bare call.

CodeGraph (`codegraph install`, marker `~/.vibebox/codegraph-installed`) is the worked
example. Also add the step to the README's First-Time Setup list.

---

## Update step

The `update` command is `scripts/update` (a normal shell script, `COPY`'d to `/usr/local/bin/update`). It is step-numbered (e.g. `1/9`). When you add a tool:

1. Increment the denominator in all step labels (e.g. `6/6` → `7/7`).
2. Add a new step at the end (before the closing summary echo).

For npm tools, `sudo npm update -g` already covers them — no extra step needed.

For install-script tools, re-run the installer:

```bash
echo "N/N Updating ToolName..."
(curl -fsSL https://example.com/install.sh | bash && (sudo cp ~/.local/bin/toolname /usr/local/bin/toolname 2>/dev/null || true)) || true
```

---

## Dotfiles

Supported dotfiles live in a single `dotfiles.manifest` at the repo root. `dotfiles-init.sh` (runs on the source machine) and `onboard` (runs inside the container, reading the copy at `/usr/local/share/vibebox/dotfiles.manifest`) both parse it — **one list, no hand-syncing.**

**Add one line** per new config path. Format is `type|relpath|label`:

- `type` = `file` (symlinked individually) or `dir` (symlinked whole)
- `relpath` = path relative to `$HOME`
- `label` = description shown in the `dotfiles-init.sh` checklist

If the tool's config directory is unknown, add a `dir` entry for the most likely location (`~/.config/toolname/` is the XDG-standard default for modern CLIs) and note it in the README.

---

## Installed tools reference

| Tool | Install method | Binary location | Update method | Dotfiles |
|---|---|---|---|---|
| Claude Code | npm global | `/usr/local/bin/claude` | `npm update -g` | `.claude/settings.json`, `.claude/CLAUDE.md`, `.claude/commands/` |
| Codex CLI | npm global | `/usr/local/bin/codex` | `npm update -g` | `.codex/` |
| codeburn | npm global (tolerated) | `/usr/local/bin/codeburn` | `npm update -g` | `.config/codeburn/` |
| Antigravity (`agy`) | install script | `/usr/local/bin/agy` | re-run installer (no update cmd) | `.gemini/antigravity-cli/` |
| Herdr | install script | `/usr/local/bin/herdr` | re-run installer | `.config/herdr/` |
| Grok CLI | install script | `/usr/local/bin/grok` | re-run installer | `.config/grok/` |
| Hermes Agent | install script | `/usr/local/bin/hermes` | re-run installer | `.hermes/` |
| Hermes WebUI | git clone + venv (tolerated) | `/opt/hermes-webui` | `git pull` + pip (update step 10) | state under `.hermes/webui/` |
| CodeGraph | install script | `/usr/local/bin/codegraph` | re-run installer | — (per-project `.codegraph/`) |
| Bun | npm global | `/usr/local/bin/bun` | `bun upgrade` | — |
| Node.js | NodeSource apt | `/usr/bin/node` | apt upgrade | — |
| GitHub CLI | apt (official repo) | `/usr/bin/gh` | apt upgrade | — |

Language servers (pyright, typescript-language-server, etc.) are all npm globals and are covered by `npm update -g`.
