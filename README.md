# Vibebox

A containerized Linux dev workspace for running AI coding agents from a Windows host. You get a persistent, SSH-accessible environment with Claude Code, Codex, and the full toolchain pre-installed — accessible locally and from anywhere on your tailnet.

> Optimized for convenience, not isolation. The user has passwordless `sudo` inside the container.

---

## Quick Start

Five steps from clone to coding:

1. **Copy `.env.example` to `.env`** and fill in `TS_AUTHKEY` (required — setup won't run without it).
2. **Add your SSH public key** to `authorized_keys` (required).
3. **Set `HERMES_WEBUI_PASSWORD`** in `.env` (only if you want the Hermes WebUI).
4. **Run the setup script** — builds and starts the container stack.
5. **SSH in and run `onboard`** — wires up GitHub auth, git identity, dotfiles, RTK, and CodeGraph.

Details on each step below.

---

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

---

## Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) running on Windows
- A [Tailscale](https://tailscale.com) account (free tier is fine)
- An SSH keypair (`~/.ssh/id_ed25519.pub` or similar)

Verify Docker is running:

```powershell
docker --version
docker compose version
```

---

## Setup

### Step 1 — Create your `.env` (Required)

Copy the example and edit it:

```powershell
Copy-Item .env.example .env
notepad .env      # or your editor of choice
```

```bash
# Linux/macOS
cp .env.example .env
$EDITOR .env
```

**Minimum required fields:**

```env
SANDBOX_NAME=vibebox
SANDBOX_USERNAME=dev
SANDBOX_SSH_PORT=22
TS_AUTHKEY=tskey-auth-...   # see Step 2
```

If you plan to run multiple sandboxes, use a different `SANDBOX_NAME` and `SANDBOX_SSH_PORT` for each.

**Optional fields** (set only if you want the feature):

```env
HERMES_HOSTNAME=hermes              # tailnet hostname for the Hermes WebUI
HERMES_WEBUI_PASSWORD=your-password # required only if you want the webui (see Step 3)
ANTHROPIC_API_KEY=sk-ant-...        # optional; agents auth interactively by default
```

Any other variable you add to `.env` reaches the sandbox environment too — see [API Keys](#api-keys).

See the [Reference](#reference) section for all config options (base image, tool versions, resource limits, backup retention).

### Step 2 — Get a Tailscale auth key (Required)

Generate one at <https://login.tailscale.com/admin/settings/keys> and set it as `TS_AUTHKEY` in `.env`.

Recommended settings:

- **Reusable** — survives rebuilds; no need to regenerate on every `up`.
- **Ephemeral** — auto-removes the node from your tailnet when it goes offline, so accidental duplicates self-clean.
- **Tagged** (`tag:vibebox`) — lets tailnet ACLs limit what a compromised sandbox can reach. First add a matching `tagOwners` entry to your tailnet ACLs (e.g. `"tag:vibebox": ["your-user@"]`).

This is required, not just for remote access: the sandbox shares the Tailscale sidecar's network namespace, so without a key the sidecar has nothing to log in with, exits, and gets restarted every minute — taking local SSH down with it. There is no interactive-login fallback, and the setup script refuses to run without a key rather than let you sit through a build that ends in a crash loop.

### Step 3 — Add your SSH public key (Required)

```powershell
Copy-Item authorized_keys.example authorized_keys
notepad authorized_keys
```

Add one public key per line. This file is bind-mounted read-only into the container — edits take effect on the next SSH connection with no restart needed.

> The setup script (Step 4) will auto-import your Windows SSH key (`~/.ssh/id_ed25519.pub` or `id_rsa.pub`) if `authorized_keys` is missing or empty.

### Step 4 — Set the Hermes WebUI password (Optional)

Only needed if you want the [Hermes WebUI](#hermes-webui). Set in `.env`:

```env
HERMES_WEBUI_PASSWORD=your-password
```

The webui binds beyond localhost so the Tailscale sidecar can reach it, making it visible to every device on your tailnet (and nothing outside — Funnel is off). Upstream requires a password for non-localhost binds.

If you skip this, the webui won't start cleanly — SSH and everything else still works.

### Step 5 — Build and start (Required)

```powershell
# Windows
.\setup-sandbox.ps1
```

```bash
# Linux/macOS
chmod +x setup-sandbox.sh backup.sh restore.sh
./setup-sandbox.sh
```

The script builds the image, starts the stack, writes an `~/.ssh/config` alias so you can run `ssh <SANDBOX_NAME>`, and prints a connection guide.

---

## Connecting

**From the Docker host (local):**

```powershell
ssh -p <SANDBOX_SSH_PORT> <SANDBOX_USERNAME>@127.0.0.1
# or just:
ssh <SANDBOX_NAME>
```

Use `127.0.0.1`, not `localhost` — on Windows, `localhost` resolves to IPv6 (`::1`) first, which fails.

**From any other device on your tailnet:**

```bash
ssh <SANDBOX_USERNAME>@<SANDBOX_NAME>.<your-tailnet>.ts.net
# or, on devices using Tailscale DNS:
ssh <SANDBOX_USERNAME>@<SANDBOX_NAME>
```

The bare hostname resolves only on devices with "Use Tailscale DNS" enabled — the client default, so it usually just works. The full MagicDNS name always works. The setup script prints your actual FQDN.

Do not pass `-p <SANDBOX_SSH_PORT>` for remote connections. That port only remaps host-local access; over Tailscale, the container's sshd is always on port 22.

---

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
4. **RTK wiring** — runs `rtk init` for each installed global-scope agent CLI (Claude Code, Codex, Hermes, Pi), installing the hook that compresses command output before it reaches the agent's context
5. **CodeGraph wiring** — runs `codegraph install`, registering CodeGraph's MCP server with every installed agent CLI (Claude Code, Codex, Hermes, Antigravity, and others) so they can query a code index of your projects

Details on RTK and CodeGraph are in the [RTK](#rtk) and [CodeGraph](#codegraph) sections.

---

## Daily Use

### Launch your workspace

```bash
launch
```

Attaches the persistent **Herdr** workspace. Herdr is a client–server multiplexer: closing the client (or losing your connection) leaves the Herdr server running with your agents still working. Reconnect from any device, run `launch`, and you are back where you left off — no manual detach required.

### Work from any device

This is the payoff of the whole design: the same live workspace from your laptop, another machine, or your phone.

1. Install the **Tailscale** app and an SSH client (**Termius** or **Blink** on iOS/Android; any terminal elsewhere) and sign in to the same tailnet.
2. `ssh <SANDBOX_USERNAME>@<SANDBOX_NAME>` — no port flag needed over Tailscale.
3. Run `launch` to attach the persistent Herdr workspace.

**Restart boundary.** A `docker compose down` / `up` stops the Herdr server itself. On the next `launch`, Herdr restores supported agents' **conversations** (`resume_agents_on_restore`, on by default), but **running processes** — dev servers, test watchers — do not come back. `stop` / `start` keeps the same container and avoids this entirely.

### Backups and restore

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

### Update tools

```bash
update
```

Upgrades all in-container tools (APT packages, npm globals, Bun, RTK, Herdr, Hermes, CodeGraph, Hermes WebUI). It creates an `auto-before-update` backup first. Note: tool updates land in image-managed paths and reset on `docker compose down/up`. Rebuild the image (`docker compose up -d --build`) to make them durable.

---

## Reference

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

### Multiple Sandboxes

Give each sandbox its own `.env` values:

```env
SANDBOX_NAME=client-a
SANDBOX_USERNAME=dev
SANDBOX_SSH_PORT=2222
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

The core toolchain intentionally tracks `latest` — backups rewind the persisted volumes, but the toolchain lives in `/usr` (not persisted), so rebuilt images always pick up current tools. Pin exact versions if you need a reproducible environment.

### API Keys

None are required. Every bundled agent (Claude Code, Codex, Antigravity, Herdr, Hermes, Pi) authenticates interactively inside the container via its own flow — `claude auth`, `codex login`, `gh auth`, `pi` then `/login`.

If you would rather a tool read a key from the environment, add it to `.env` and rebuild. For example, Pi honours `ANTHROPIC_API_KEY` when set:

```env
ANTHROPIC_API_KEY=sk-ant-...
```

Any variable works, not a fixed list — `.env` is loaded wholesale into the sandbox, and the entrypoint republishes it to SSH sessions through `~/.ssh/environment` (sshd does not inherit the container's environment on its own). So `OPENROUTER_API_KEY`, `OPENAI_API_KEY`, or anything else you add is visible to interactive shells, `ssh vibebox <cmd>`, and Remote-SSH alike.

Two caveats. Session-scoped variables (`PATH`, `HOME`, `USER`, `SHELL`, `TERM`, …) are skipped — the shell owns those, and exporting the container's copies would break logins. And the file is rewritten on every container start, so a key is picked up by `docker compose up -d` and disappears once you delete it from `.env` and restart.

The file is mode `0600` and owned by the sandbox user. Note that this puts your keys on the persisted home volume, so they land in backup archives — see [Security Notes](#security-notes).

### Security Notes

- Backups archive your home directory only — no longer `/etc/shadow` or system secrets. They still contain whatever lives under `$HOME`: `gh`/Claude/Codex auth tokens, shell history, and any private keys you keep there. Treat backup archives as private secrets.
- The sandbox runs with passwordless `sudo`. A tagged Tailscale auth key (`tag:vibebox`, see [Step 2](#step-2--get-a-tailscale-auth-key-required)) lets tailnet ACLs bound what a compromised sandbox can reach.
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

---

## Hermes WebUI

The [Hermes WebUI](https://github.com/nesquena/hermes-webui) runs inside the sandbox (it drives the Hermes Agent in-process, sharing `~/.hermes` and the full toolchain) and is served to your tailnet at:

```
https://<HERMES_HOSTNAME>.<your-tailnet>.ts.net     (default: https://hermes.…)
```

Because one Tailscale node can only carry one hostname, the webui gets its own node: the `hermes-ts` sidecar joins the tailnet as `<HERMES_HOSTNAME>` and uses `tailscale serve` (config in `hermes-serve/serve.json`) to terminate HTTPS on 443 and proxy to the webui on port 8787. SSH access via `<SANDBOX_NAME>` is unaffected.

**Setup:**

- **Set `HERMES_WEBUI_PASSWORD` in `.env` before starting** (see [Step 4](#step-4--set-the-hermes-webui-password-optional)).
- **Tailnet prerequisites:** MagicDNS and HTTPS certificates must be enabled in the Tailscale admin console. The first visit can take ~10 s while the Let's Encrypt certificate provisions.
- If your `TS_AUTHKEY` is tagged, your tailnet ACLs must allow your devices to reach that tag on port 443.

**Managing the webui:**

The webui starts automatically on container boot. Inside the sandbox, manage it with:

```bash
/opt/hermes-webui/ctl.sh status|logs|restart|stop
```

Logs are at `~/.hermes/webui.log`.

---

## RTK

RTK intercepts Bash commands the agents run and rewrites them to token-efficient
equivalents, cutting the output that lands in context. `onboard` wires it into every
global-scope agent CLI it finds installed, records a marker at `~/.vibebox/rtk-initialized`,
and skips on later runs. Wire up an agent by hand after adding one:

```bash
rtk init -g --auto-patch                  # Claude Code (RTK's default target)
rtk init -g --codex                       # Codex — rejects --auto-patch
rtk init -g --agent hermes --auto-patch   # Hermes
rtk init -g --agent pi --auto-patch       # Pi
```

**Antigravity is project-scoped** and is deliberately not wired by `onboard` — it writes
its rules into the working directory, so a run from `$HOME` would only litter your home
directory. Run it inside each project you want covered:

```bash
rtk init --agent antigravity              # note: no -g
```

Run `rtk init --show` to verify an existing install, or `rtk init --uninstall` to remove
the hook. Like CodeGraph below, this can't be baked into the image — it writes per-user
config into `$HOME`, which is a persisted volume that masks image content.

**Interaction with dotfiles:** RTK patches `~/.claude/settings.json` (adds a `PreToolUse`
hook) and appends `@RTK.md` to `~/.claude/CLAUDE.md`. Both are symlinked by the dotfiles
step that runs before it, so the edits land in your dotfiles repo and sync across
machines. RTK merges rather than overwrites and is idempotent, so existing settings
survive and re-runs don't duplicate entries — but expect uncommitted changes in
`~/.dotfiles` after your first `onboard`.

---

## CodeGraph

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

**Using it.** Indexing is per-project — `cd` into a repo first:

```bash
codegraph init             # build this project's .codegraph/ index
codegraph status           # index stats: files, nodes, edges, freshness
codegraph query <symbol>   # find a symbol (also: explore, node, callers, impact)
```

Your agents reach the same index through the MCP server `onboard` registered, so you rarely
need these by hand.

> **Bare `codegraph` re-runs the installer.** With no arguments it always enters the agent
> install flow — by upstream design, it neither detects an existing install nor shows
> status. `codegraph status` is the view you want.

**Upgrading:** use `update`, not `codegraph upgrade`. The bundle lives in `/opt/codegraph`,
root-owned so every user can read it, which means the self-upgrade path fails with a
permission error. `update` re-runs the installer under `sudo` with the right paths.

---

## Dotfiles

Dotfiles are **not** managed by vibebox. They are handled by
[dotter](https://github.com/execsumo/dotter) — a standalone tool that works the
same way on your laptop, a VPS, or inside a vibebox container. Vibebox is just
one consumer of it.

`onboard` runs exactly two commands for its dotfiles step:

```bash
dotfiles init --repo "https://github.com/<you>/dotfiles"
dotfiles link
```

Which is the same thing you would run on any other machine.

### What lives where

| Thing | Owner |
|---|---|
| Which files are tracked (the manifest) | Your `dotfiles` repo, at `dotfiles.manifest` |
| The git/symlink mechanics | [dotter](https://github.com/execsumo/dotter) |
| Cloning + linking on a fresh container | vibebox's `onboard`, by calling `dotfiles` |

There is no source-of-truth machine any more. Add a file from wherever you are:

```bash
dotfiles add ~/.config/some-tool/config.toml   # move in, symlink back, commit
dotfiles sync                                  # pull, then push
dotfiles status                                # what is linked here
```

The tracked-file list is no longer duplicated in this README — read your own
manifest instead, which carries a label and a rationale comment per entry:

```bash
cat ~/.dotfiles/dotfiles.manifest
```

> **Prefer individual files over whole directories.** A `dir|` entry tracks
> whatever the owning tool writes there *later* — we have had that leak a live
> API key and 250MB of vendored binaries in one case, and logs plus unix sockets
> in another. `dotfiles add` audits a directory and makes you confirm, but the
> audit is a snapshot, not a guarantee. See dotter's README for the full list of
> safety behaviours.

CodeGraph is deliberately absent from the manifest — its state is per-project
(`.codegraph/` and an optional `codegraph.json` at the project root), so it
belongs in each repo, not your dotfiles.

**Cross-platform tip:** guard macOS- or Linux-specific config behind an OS check so the same dotfiles work everywhere:

```sh
if [[ "$(uname)" == "Darwin" ]]; then
  # macOS-only
fi
```
