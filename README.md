# Vibebox

A containerized Linux dev workspace for running AI coding agents from a Windows host. You get a persistent, SSH-accessible environment with Claude Code, Codex, and the full toolchain pre-installed — accessible locally and from anywhere on your tailnet.

> This is optimized for convenience, not isolation. The user has passwordless `sudo` inside the container.

## What You Get

### Coding tools

| Tool | Notes |
|---|---|
| Claude Code | AI coding agent (Anthropic) |
| Codex CLI | AI coding agent (OpenAI) |
| Antigravity (`agy`) | AI coding agent (Google) |
| Herdr | AI coding agent (Herdr) |
| Grok CLI | AI coding agent (xAI) |
| Node.js + npm | LTS (v22 by default) |
| Bun | Fast JS runtime / package manager |
| Python | System Python 3 |
| Git + GitHub CLI | `git` and `gh` |
| tmux | Terminal multiplexer |
| zsh | Default shell |
| ripgrep, fzf, jq | Search and data tools |
| Common build utilities | `build-essential`, `curl`, `wget`, etc. |

### Language servers (for editor LSP support)

| Server | Covers |
|---|---|
| `pyright` | Python |
| `typescript-language-server` + `typescript` | TypeScript / JavaScript |
| `vscode-langservers-extracted` | HTML, CSS, ESLint, JSON |
| `yaml-language-server` | YAML |
| `bash-language-server` | Shell scripts |
| `tailwindcss-language-server` | Tailwind CSS |

Heavier servers (rust-analyzer, gopls, sourcekit-lsp) are not included — install them inside the sandbox when you need them.

### Infrastructure

- SSH key authentication, password login disabled
- Tailscale sidecar for remote access without opening a public port
- A single persistent Docker volume for your home directory — your files, config, and SSH host identity survive rebuilds; everything else comes from the image
- `backup` / `restore` commands (inside container and host scripts)
- `onboard` command for first-time setup: GitHub CLI auth, git identity, dotfiles

## Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) running on Windows
- A [Tailscale](https://tailscale.com) account (free tier is fine)
- An SSH keypair (`~/.ssh/id_ed25519.pub` or similar)

## Setup

1. Copy `.env.example` to `.env` and configure:

   ```env
   SANDBOX_NAME=vibebox
   SANDBOX_USERNAME=dev
   SSH_PORT=22
   TS_AUTHKEY=tskey-auth-...   # see step 2
   ```

   If you plan to run multiple sandboxes, use a different `SANDBOX_NAME` and `SSH_PORT` for each.

2. Get a Tailscale auth key from <https://login.tailscale.com/admin/settings/keys>.

   Choose **reusable + ephemeral**. Reusable lets the container authenticate on every restart without generating a new key. Ephemeral auto-removes the node from your tailnet when it goes offline, so you don't accumulate stale entries.

   Also make it a **tagged** key (select `tag:vibebox` when creating it). First add a matching `tagOwners` entry to your tailnet ACLs (e.g. `"tag:vibebox": ["your-user@"]`). The sandbox then comes up tagged automatically, so tailnet ACLs can limit what it reaches — a meaningful blast-radius reduction for a box with passwordless `sudo`.

   Set this as `TS_AUTHKEY` in `.env`. Without it, the Tailscale sidecar has nothing to log in with, exits, and gets restarted every minute — which also breaks local SSH.

3. Add your SSH public key to `authorized_keys`:

   ```powershell
   Copy-Item authorized_keys.example authorized_keys
   notepad authorized_keys
   ```

   Add one public key per line. This file is bind-mounted read-only into the container — edits take effect on the next SSH connection with no restart needed.

4. Build and start:

   ```powershell
   # Windows
   .\setup-sandbox.ps1
   ```

   ```bash
   # Linux/macOS
   chmod +x setup-sandbox.sh backup.sh restore.sh
   ./setup-sandbox.sh
   ```

## Connecting

**From the Docker host (local):**

```powershell
ssh -p <SSH_PORT> <SANDBOX_USERNAME>@127.0.0.1
```

Use `127.0.0.1`, not `localhost` — on Windows, `localhost` resolves to IPv6 (`::1`) first, which fails. The setup script also writes an `~/.ssh/config` alias so you can just run:

```powershell
ssh <SANDBOX_NAME>
```

**From any other device on your tailnet:**

```bash
ssh <SANDBOX_USERNAME>@<SANDBOX_NAME>
```

Do not pass `-p <SSH_PORT>` for remote connections. That port only remaps host-local access; over Tailscale, the container's sshd is always on port 22.

## First-Time Setup

After your first SSH login, run:

```bash
onboard
```

This one-time script personalizes the sandbox. It is idempotent — safe to re-run at any time.

**What it does:**

1. **GitHub CLI auth** — runs `gh auth login` if not already authenticated
2. **Git identity** — sets `user.name` and `user.email` in `~/.gitconfig`, pre-filling values from your GitHub profile
3. **Dotfiles** — clones `github.com/<your-gh-username>/dotfiles` (or a URL you enter) into `~/.dotfiles` and symlinks supported files into `$HOME`

### Setting up dotfiles from your main machine

Run `dotfiles-init.sh` once on the machine whose config you want to use as the source of truth:

```bash
chmod +x dotfiles-init.sh
./dotfiles-init.sh
```

The script will authenticate with GitHub CLI, create or clone your `dotfiles` repo, show an interactive checklist of supported files, move selected files into `~/.dotfiles/`, symlink them back to their original locations, then commit and push. Any Vibebox running `onboard` will clone the same repo and mirror the same symlinks.

### Supported dotfiles

The repo mirrors your home directory exactly. The `onboard` script links these files if present:

**Shell & editor**

| File | Purpose |
|---|---|
| `.zshrc` | Zsh config — aliases, prompt, plugins, `$PATH` additions |
| `.bashrc` | Bash config |
| `.gitconfig` | Git aliases, diff settings, default branch |
| `.tmux.conf` | tmux key bindings and appearance |
| `.vimrc` | Vim settings |
| `.nanorc` | Nano syntax highlighting |
| `.editorconfig` | Editor-agnostic indent/charset rules |
| `.curlrc` | Default curl flags |
| `.wgetrc` | Default wget flags |

**Claude Code**

| File | Purpose |
|---|---|
| `.claude/settings.json` | User-level Claude Code settings |
| `.claude/CLAUDE.md` | Global instructions for all projects |
| `.claude/commands/` _(dir)_ | Custom slash commands |

**Codex**

| File | Purpose |
|---|---|
| `.codex/` _(dir)_ | Full Codex config directory |

**Antigravity (`agy`)**

| File | Purpose |
|---|---|
| `.gemini/antigravity-cli/settings.json` | Antigravity settings |
| `.gemini/antigravity-cli/keybindings.json` | Custom keybindings |
| `.gemini/antigravity-cli/mcp_config.json` | Global MCP config |
| `.gemini/antigravity-cli/skills/` _(dir)_ | Agent skills |

**Herdr**

| File | Purpose |
|---|---|
| `.config/herdr/` _(dir)_ | Herdr config directory |

**Grok CLI**

| File | Purpose |
|---|---|
| `.config/grok/` _(dir)_ | Grok CLI config directory |

Only files that exist in your repo are linked — the rest are left alone.

**Cross-platform tip:** guard macOS- or Linux-specific config behind an OS check so the same dotfiles work everywhere:

```sh
if [[ "$(uname)" == "Darwin" ]]; then
  # macOS-only
fi
```

---

## Reference

### Working From Any Device

This is the payoff of the whole design: the same live workspace from your laptop, another
machine, or your phone.

1. Install the **Tailscale** app and an SSH client (**Termius** or **Blink** on iOS/Android;
   any terminal elsewhere) and sign in to the same tailnet.
2. `ssh <SANDBOX_USERNAME>@<SANDBOX_NAME>` — no port flag needed over Tailscale.
3. Run `launch` to attach the persistent **Herdr** workspace.

Herdr is a client–server multiplexer: closing the client (or losing your connection) leaves
the Herdr server running with your agents still working. Reconnect from any device, run
`launch`, and you are back where you left off — no manual detach required.

**Restart boundary.** A `docker compose down` / `up` stops the Herdr server itself. On the
next `launch`, Herdr restores supported agents' **conversations** (`resume_agents_on_restore`,
on by default), but **running processes** — dev servers, test watchers — do not come back.
`stop` / `start` keeps the same container and avoids this entirely.

### Persistence and State

**What survives a rebuild is your home directory.** That is the whole model:

- `/home/<SANDBOX_USERNAME>` — all your files, settings, shell history, and the sandbox's SSH host identity (under `~/.vibebox/ssh`), in the `<SANDBOX_NAME>-home` volume
- Tailscale auth/identity (`<SANDBOX_NAME>-tailscale-state` volume)
- `authorized_keys` and `backups/` live on the host as bind mounts, outside the container lifecycle entirely

Everything else comes from the image and is disposable. Anything you install with `apt` or `sudo cp` works for the life of the container but is **not** persisted — to make a tool or package durable, add it to the Dockerfile and rebuild. The in-container `update` command upgrades tools in place, but those changes reset on the next `down`/`up`; treat `docker compose up -d --build` as the durable update path.

SSH host keys are generated once on first boot into the home volume, so rebuilds keep the same identity — no "host key changed" warnings. (A `restore` regenerates them, so expect one host-key prompt after a deliberate rewind.)

**Two distinctions worth knowing:**

- `docker compose stop` / `start` keeps the same container — the writable layer is preserved
- `docker compose down -v` deletes named volumes, **wiping your home directory and all persisted state** — avoid unless you intend a full reset

### Backups and Restore

Backups are scoped by sandbox name:

```text
backups/<SANDBOX_NAME>/<SANDBOX_NAME>-backup-YYYYMMDD-HHMMSS.tar.gz
```

**Create a backup** (from inside the container):

```bash
backup
backup before-refactor
```

**Create a backup** (from the host):

```powershell
# Windows
.\backup.ps1
.\backup.ps1 before-refactor
```

```bash
# Linux/macOS
./backup.sh
./backup.sh before-refactor
```

**Restore** (from the host):

```powershell
# Windows
.\restore.ps1
.\restore.ps1 before-refactor
```

```bash
# Linux/macOS
./restore.sh
./restore.sh before-refactor
```

A backup archives your home directory into a single `.tar.gz` (SSH host keys under `~/.vibebox` are excluded — the home volume already persists them). Restore creates a `pre-restore` backup first, stops the workspace container, wipes the home volume, extracts the selected backup, then starts the workspace again. When a new backup is created, **timestamped** backups older than `BACKUP_RETENTION_DAYS` (default: 7) are pruned; **labeled** backups (e.g. `before-refactor`, `pre-restore`, `auto-before-update`) are kept until you delete them.

### Multiple Sandboxes

Give each sandbox its own `.env` values:

```env
SANDBOX_NAME=client-a
SANDBOX_USERNAME=dev
SSH_PORT=2222
```

This namespaces container names, Docker volumes, the Tailscale hostname, and the backup folder:

```text
client-a
client-a-tailscale
client-a-home
client-a-tailscale-state
backups/client-a/
```

### Base Image

The default base image uses the current Ubuntu LTS:

```env
BASE_IMAGE=ubuntu:24.04
```

For most vibe-coding, web apps, scripts, and CLIs this is the better default — smaller, faster to rebuild, less attack surface.

Use CUDA only when you need CUDA runtime libraries inside the container:

```env
# Pin a specific tag rather than :latest for reproducible rebuilds.
BASE_IMAGE=nvidia/cuda:13.3.0-cudnn-runtime-ubuntu24.04
```

With the CUDA base and GPU passthrough:

```powershell
docker compose -f docker-compose.yml -f docker-compose.gpu.yml up -d --build
```

### Resource Limits

Default runaway protections:

```env
SANDBOX_MEM_LIMIT=8g
SANDBOX_CPUS=4
SANDBOX_PIDS_LIMIT=1024
```

These stop runaway agent loops, accidental recursive process spawning, and oversized installs from taking over the host. `1024` is a safe runaway guard that still leaves headroom for large builds — linkers, `jest`, and `cargo` spawn many short-lived processes. If you ever hit mysterious "Resource temporarily unavailable" errors during a heavy build, this limit is the first thing to raise.

### Tool Versions

```env
NODE_MAJOR=22
BUN_VERSION=latest
CLAUDE_CODE_VERSION=latest
CODEX_VERSION=latest
PYRIGHT_VERSION=latest
TYPESCRIPT_VERSION=latest
TYPESCRIPT_LANGUAGE_SERVER_VERSION=latest
VSCODE_LANGSERVERS_VERSION=latest
YAML_LANGUAGE_SERVER_VERSION=latest
BASH_LANGUAGE_SERVER_VERSION=latest
TAILWIND_LANGUAGE_SERVER_VERSION=latest
```

### API Keys

Set these in `.env` so the container picks them up automatically:

```env
XAI_API_KEY=xai-...   # Grok CLI (xAI)
```

Other agents (Claude Code, Codex, Antigravity) use their own auth flows (`claude auth`, `codex login`, `gh auth`) and don't need API keys in `.env`.

The core toolchain intentionally tracks `latest` — backups rewind the persisted volumes, but the toolchain lives in `/usr` (not persisted), so rebuilt images always pick up current tools. Pin exact versions if you need a reproducible environment.

### Security Notes

- Backups archive your home directory only — no longer `/etc/shadow` or system secrets. They still contain whatever lives under `$HOME`: `gh`/Claude/Codex auth tokens, shell history, and any private keys you keep there. Treat backup archives as private secrets.
- The sandbox runs with passwordless `sudo`. A tagged Tailscale auth key (`tag:vibebox`, see setup step 2) lets tailnet ACLs bound what a compromised sandbox can reach.
- Tool versions default to `latest`. Pin versions in `.env` and rebuild if you need to recreate a known-good environment.

### Management Commands

```powershell
# Start
docker compose up -d

# Start with rebuild
docker compose up -d --build

# Start in CUDA/GPU mode
docker compose -f docker-compose.yml -f docker-compose.gpu.yml up -d --build

# Stop
docker compose down

# Check health
docker compose ps
```
