# Adding Tools to Vibebox

This document explains where each piece lives and what to touch when you add a new tool.

---

## Files to update

| File | What changes |
|---|---|
| `Dockerfile` | Install step + update step |
| `.env.example` | API key variable (if the tool needs one) |
| `dotfiles-init.sh` | Interactive checklist entry for dotfiles |
| `README.md` | Coding tools table + dotfiles section + API Keys section (if needed) |

The `onboard` script lives **inside** the Dockerfile (in the `RUN cat > /usr/local/bin/onboard` heredoc). Its `SUPPORTED_FILES` and `SUPPORTED_DIRS` arrays must also be updated to mirror any new dotfile paths you add to `dotfiles-init.sh`.

---

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
Add a numbered step after the last tool install, before step 9 (SSH config). Copy the binary to `/usr/local/bin` so it is on `$PATH` for all users. Wrap in `(... ) || echo "..."` so a transient network failure doesn't break the whole build.

```dockerfile
# N. Install ToolName via the official installer
RUN (curl -fsSL https://example.com/install.sh | bash && \
     (cp /root/.local/bin/toolname /usr/local/bin/toolname 2>/dev/null || true) && \
     chmod +x /usr/local/bin/toolname 2>/dev/null) || echo "ToolName setup skipped"
```

### apt package
Add to the existing `apt-get install -y` block (step 1).

---

## Update step

The `update` command is a shell script written inline in the Dockerfile (`RUN echo '...' > /usr/local/bin/update`). It is step-numbered (e.g. `1/6`). When you add a tool:

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

Both `dotfiles-init.sh` (runs on the source machine) and the `onboard` script inside the Dockerfile (runs inside the container) maintain parallel lists of supported dotfiles.

**Update both lists** when adding new config paths. Each entry format:

- `dotfiles-init.sh` ITEMS array: `"Label (path)|rel/path|file"` or `"Label (path/)|rel/path|dir"`
- `onboard` SUPPORTED_FILES / SUPPORTED_DIRS arrays: bare relative path strings

If the tool's config directory is unknown, add a `dir` entry for the most likely location (`~/.config/toolname/` is the XDG-standard default for modern CLIs) and note it in the README.

---

## Installed tools reference

| Tool | Install method | Binary location | Update method | Dotfiles |
|---|---|---|---|---|
| Claude Code | npm global | `/usr/local/bin/claude` | `npm update -g` | `.claude/settings.json`, `.claude/CLAUDE.md`, `.claude/commands/` |
| Codex CLI | npm global | `/usr/local/bin/codex` | `npm update -g` | `.codex/` |
| Antigravity (`agy`) | install script | `/usr/local/bin/agy` | re-run installer (no update cmd) | `.gemini/antigravity-cli/` |
| Oh My Pi (`omp`) | install script | `/usr/local/bin/omp` | re-run installer | `.omp/agent/` |
| Grok CLI | install script | `/usr/local/bin/grok` | re-run installer | `.config/grok/` |
| Bun | npm global | `/usr/local/bin/bun` | `bun upgrade` | — |
| Node.js | NodeSource apt | `/usr/bin/node` | apt upgrade | — |
| GitHub CLI | apt (official repo) | `/usr/bin/gh` | apt upgrade | — |

Language servers (pyright, typescript-language-server, etc.) are all npm globals and are covered by `npm update -g`.
