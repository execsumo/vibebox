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
| Pi (`pi`) | AI coding agent (Earendil Works) |
| Hermes Agent | AI coding agent (Nous Research) |
| Hermes WebUI | Web frontend for Hermes Agent, served at `https://hermes.<tailnet>.ts.net` |
| RTK | Token-reducing command wrapper — hooks into each agent CLI, wired up by `onboard` |
| CodeGraph | Code-index MCP server for the agent CLIs — wired up by `onboard` |
| codeburn | AI spend tracker (by task, tool, model, project) |
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

## Hermes WebUI

The [Hermes WebUI](https://github.com/nesquena/hermes-webui) runs inside the sandbox (it drives the Hermes Agent in-process, sharing `~/.hermes` and the full toolchain) and is served to your tailnet at:

```
https://<HERMES_HOSTNAME>.<your-tailnet>.ts.net     (default: https://hermes.…)
```

Because one Tailscale node can only carry one hostname, the webui gets its own node: the `hermes-ts` sidecar joins the tailnet as `<HERMES_HOSTNAME>` and uses `tailscale serve` (config in `hermes-serve/serve.json`) to terminate HTTPS on 443 and proxy to the webui on port 8787. SSH access via `<SANDBOX_NAME>` is unaffected.

- **Set `HERMES_WEBUI_PASSWORD` in `.env` before starting.** The webui binds beyond localhost so the sidecar can reach it, making it visible to every device on your tailnet (and nothing outside — Funnel is off). Upstream requires a password for non-localhost binds.
- **Tailnet prerequisites:** MagicDNS and HTTPS certificates must be enabled in the Tailscale admin console. The first visit can take ~10 s while the Let's Encrypt certificate provisions.
- The webui starts automatically on container boot. Inside the sandbox, manage it with `/opt/hermes-webui/ctl.sh status|logs|restart|stop`; logs are at `~/.hermes/webui.log`.
- If your `TS_AUTHKEY` is tagged, your tailnet ACLs must allow your devices to reach that tag on port 443.

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
4. **RTK wiring** — runs `rtk init` for each installed agent CLI (Claude Code, Codex, Antigravity, Hermes, Pi), installing the hook that compresses command output before it reaches the agent's context
5. **CodeGraph wiring** — runs `codegraph install`, registering CodeGraph's MCP server with every installed agent CLI (Claude Code, Codex, Hermes, Antigravity, and others) so they can query a code index of your projects

### RTK

RTK intercepts Bash commands the agents run and rewrites them to token-efficient
equivalents, cutting the output that lands in context. `onboard` wires it into every
agent CLI it finds installed, records a marker at `~/.vibebox/rtk-initialized`, and skips
on later runs. Wire up an agent by hand after adding one:

```bash
rtk init -g --auto-patch                 # Claude Code (RTK's default target)
rtk init -g --codex --auto-patch         # Codex
rtk init -g --agent antigravity --auto-patch
rtk init -g --agent hermes --auto-patch
rtk init -g --agent pi --auto-patch
```

Run `rtk init --show` to verify an existing install, or `rtk init --uninstall` to remove
the hook. Like CodeGraph below, this can't be baked into the image — it writes per-user
config into `$HOME`, which is a persisted volume that masks image content.

### CodeGraph

`onboard` handles the wiring, so there is normally nothing to do by hand. It records a
marker at `~/.vibebox/codegraph-installed` and skips on later runs; re-run it yourself
after adding or removing an agent CLI:

```bash
codegraph install
```

**Why this step isn't baked into the image:** it writes per-user agent config into `$HOME`
(e.g. `~/.claude.json`), and `$HOME` is a persisted Docker volume that masks image content
— so a build-time run would never reach your user. Running it inside the container writes
into the volume instead, which means it **survives rebuilds**.

Indexing is per-project: run `codegraph` in a repo to build its `.codegraph/` index.

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

**Pi (`pi`)**

| File | Purpose |
|---|---|
| `.pi/` _(dir)_ | Pi config directory |

Pi keeps config *and* state (auth, sessions) under `~/.pi/agent/`, so linking it shares
auth across machines. Set `PI_CODING_AGENT_DIR` to relocate that state if you would
rather keep it machine-local.

**RTK**

| File | Purpose |
|---|---|
| `.config/rtk/` _(dir)_ | RTK config directory (`config.toml`) |

RTK's per-agent hooks live in each agent's own config (linked above), not here — so
linking `.config/rtk/` shares your RTK settings, and `onboard` re-installs the hooks.

**Hermes Agent**

| File | Purpose |
|---|---|
| `.hermes/` _(dir)_ | Hermes config directory |

Note that `~/.hermes/` also holds Hermes' cloned source tree, auth, and sessions — not
just config. Linking it shares all of that across machines; skip it in the
`dotfiles-init.sh` checklist if you would rather keep auth machine-local.

**codeburn**

| File | Purpose |
|---|---|
| `.config/codeburn/` _(dir)_ | Spend config: `config.json` (currency, model aliases), `guard.json` (budget caps) |

CodeGraph is deliberately absent — its state is per-project (`.codegraph/` and an optional
`codegraph.json` at the project root), so it belongs in each repo, not your dotfiles.

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
CODEBURN_VERSION=latest
PI_CODING_AGENT_VERSION=latest
PYRIGHT_VERSION=latest
TYPESCRIPT_VERSION=latest
TYPESCRIPT_LANGUAGE_SERVER_VERSION=latest
VSCODE_LANGSERVERS_VERSION=latest
YAML_LANGUAGE_SERVER_VERSION=latest
BASH_LANGUAGE_SERVER_VERSION=latest
TAILWIND_LANGUAGE_SERVER_VERSION=latest
```

### API Keys

None are required. Every bundled agent (Claude Code, Codex, Antigravity, Herdr, Hermes,
Pi) authenticates interactively inside the container via its own flow — `claude auth`,
`codex login`, `gh auth`, `pi` then `/login`.

If you would rather a tool read a key from the environment, add it to `.env` and it is
picked up on container start. For example, Pi honours `ANTHROPIC_API_KEY` when set:

```env
ANTHROPIC_API_KEY=sk-ant-...
```

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
