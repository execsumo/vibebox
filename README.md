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
5. **SSH in and run `onboard`** — wires up GitHub auth, git identity, and dotfiles.

Details on each step below.

---

## What You Get

### Coding tools

| Tool | Notes |
|---|---|
| Herdr |  Multiplexer (Herdr) |
| Claude Code | AI coding agent (Anthropic) |
| Codex CLI | AI coding agent (OpenAI) |
| Antigravity (`agy`) | AI coding agent (Google) |
| Pi (`pi`) | AI coding agent (Earendil Works) |
| Hermes Agent | AI coding agent (Nous Research) |
| Hermes WebUI | Web frontend for Hermes Agent, served at `https://hermes.<tailnet>.ts.net` |
| codeburn | AI spend tracker (by task, tool, model, project) |
| Node.js + npm | LTS (v22 by default) |
| Bun | Fast JS runtime / package manager |
| Python | System Python 3 |
| Go | System Go toolchain |
| Git + GitHub CLI | `git` and `gh` |
| Docker | Container runtime & CLI (`docker` and `docker compose`) |
| tmux | Terminal multiplexer |
| zsh | Default shell |
| btop, htop | Resource and process monitors |
| ripgrep, fzf, jq | Search and data tools |
| ffmpeg | Audio/video transcoding (`ffmpeg`, `ffprobe`) |
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

Heavier servers (rust-analyzer, gopls, sourcekit-lsp) are not included — install them inside the sandbox when you need them. The Go toolchain itself is pre-installed.

### Infrastructure

- SSH key authentication, password login disabled
- Tailscale sidecar for remote access without opening a public port
- A persistent Docker volume for your home directory (optionally a host folder you can browse from Windows) — your files, config, and SSH host identity survive rebuilds; everything else comes from the image
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

Details on the dotfiles step are in the [Dotfiles](#dotfiles) section.

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

This one covers home only — it runs as the sandbox user, which cannot read the root-owned host keys. Use the host-side scripts below if you want the SSH identity in the archive.

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

**Restore the SSH host identity too** — only when you mean it, e.g. rebuilding on a new host:

```powershell
.\restore.ps1 before-refactor -RestoreIdentity     # Windows
```

```bash
./restore.sh before-refactor --restore-identity    # Linux/macOS
```

A backup archives your home directory into a single `.tar.gz` (onboard markers under `~/.vibebox` are excluded so a restore re-runs them), plus the SSH host keys under `ssh-identity/`. Restore creates a `pre-restore` backup first, stops the workspace container, wipes the home directory, extracts the selected backup, then starts the workspace again.

The host identity is **not** restored unless you ask for it: by default the sandbox keeps the identity it already has, so a restore never triggers "host key changed" warnings on your clients. Passing `--restore-identity` adopts the archived keys instead — expect each client to warn once. Archives made before this existed have no `ssh-identity/` entry; the flag then reports that and leaves the current identity alone. When a new backup is created, **timestamped** backups older than `BACKUP_RETENTION_DAYS` (default: 7) are pruned; **labeled** backups (e.g. `before-refactor`, `pre-restore`, `auto-before-update`) are kept until you delete them.

### Update tools

```bash
update
```

Upgrades every tool the image pre-installs — APT packages, all npm globals (including Bun, which is installed as one), Herdr, Antigravity (`agy`), the Hermes Agent, the Hermes WebUI, and the `dotfiles` tool — each through its own supported update path. It creates an `auto-before-update` backup first and prints an `ok` / `MISSING` / `BROKEN` line per tool at the end, so a step that failed and scrolled past is still visible. Note: tool updates land in image-managed paths and reset on `docker compose down/up`. Rebuild the image (`docker compose up -d --build`) to make them durable. The tailscale sidecars are separate containers — update them from the host with `docker compose pull && docker compose up -d`.

**Claude Code and Codex do not self-update here — `update` is their update path.** The
NodeSource `nodejs` package sets npm's prefix to `/usr`, so every npm global lives in
root-owned `/usr/lib/node_modules`. That is intentional (see the chown note in the
Dockerfile), but Claude Code's built-in updater checks the prefix for write access at
startup and otherwise prints `Auto-update failed: no write permission to npm prefix ·
Run claude doctor` on every launch. The image therefore sets `DISABLE_AUTOUPDATER=1`
so the CLI stops attempting an update path this box does not use, and `update` reinstalls
every npm global at `@latest` under `sudo` (a bare `npm update -g` honours the caret range
npm records per global, so it would never cross a major version). To update just Claude
without a full `update` run:

```bash
sudo npm install -g @anthropic-ai/claude-code@latest
```

### Docker and Tailscale from inside the box

`docker` and `docker compose` work inside the sandbox. There is no daemon running in
the container — they talk to the **host's** Docker daemon over the bind-mounted
`/var/run/docker.sock`, so containers you start are siblings of the sandbox, not
children of it. Two consequences worth knowing: bind-mount paths you pass to
`docker run` are resolved on the *host*, not in the sandbox, and anything you start
this way outlives `docker compose down`. See [Security Notes](#security-notes) —
this mount is deliberately a hole in the sandbox.

If the socket is not mounted, the entrypoint says so at boot and `docker` is simply
unavailable; it does not silently fall back to anything.

`tailscale` is also on `$PATH`, as a wrapper that runs the real CLI in the sidecar
container that owns the network namespace:

```bash
tailscale status
tailscale ip -4
```

It shells out to `docker`, so it depends on that same socket being mounted.

---

## Reference

### Persistence and State

**What survives a rebuild is your home directory.** That is the whole model:

- `/home/<SANDBOX_USERNAME>` — all your files, settings, and shell history, in the `<SANDBOX_NAME>-home` volume (or a host folder — see [Mounting Home from a Host Folder](#mounting-home-from-a-host-folder))
- SSH host identity — the `<SANDBOX_NAME>-ssh-keys` volume, mounted at `/opt/vibebox/ssh`
- Tailscale auth/identity (`<SANDBOX_NAME>-tailscale-state` volume)
- `authorized_keys` and `backups/` live on the host as bind mounts, outside the container lifecycle entirely

Everything else comes from the image and is disposable. Anything you install with `apt` or `sudo cp` works for the life of the container but is **not** persisted — to make a tool or package durable, add it to the Dockerfile and rebuild. The in-container `update` command upgrades tools in place, but those changes reset on the next `down`/`up`; treat `docker compose up -d --build` as the durable update path.

SSH host keys are generated once on first boot into a dedicated volume (`/opt/vibebox/ssh`), so rebuilds — and restores — keep the same identity: no "host key changed" warnings. Keeping them off the home volume is what makes them survive a restore.

They are still captured by `backup.sh` / `backup.ps1`, under `ssh-identity/` in the archive, so losing the volume does not lose the identity for good. Restore deliberately **does not** put them back by default — that would undo the very property above — so use `--restore-identity` (or `-RestoreIdentity` on Windows) when you actually want the archived identity, e.g. when moving the sandbox to a new host. See [Backups and restore](#backups-and-restore).

**Two distinctions worth knowing:**

- `docker compose stop` / `start` keeps the same container — the writable layer is preserved
- `docker compose down -v` deletes named volumes, **wiping your home directory and all persisted state** — avoid unless you intend a full reset. (If home is a host folder via `SANDBOX_HOME_HOST_PATH`, `down -v` does *not* touch it.)

### Mounting Home from a Host Folder

By default home lives in a Docker named volume — fast and Linux-native, but invisible to the host OS. If you want the same files on both sides (edit on Windows, run in the sandbox), point `SANDBOX_HOME_HOST_PATH` in `.env` at an absolute host path:

```env
SANDBOX_HOME_HOST_PATH=D:/vibebox
```

Then `docker compose up -d`. Use forward slashes; on Docker Desktop the drive must be shared (all local drives are, by default, on current versions). A fresh empty folder is seeded with the usual skel files on first boot.

**Upgrading from an earlier vibebox?** Boot once on the new version *before* setting `SANDBOX_HOME_HOST_PATH` (`docker compose up -d --build`), so your SSH host keys migrate from the home volume to their own volume. Switching in the same step hides the old keys behind the bind mount, and the sandbox starts with a fresh host identity (one "host key changed" prompt per client).

**Migrating an existing sandbox** (volume → host folder, or back). The backup/restore tools target whichever backend is configured, so they double as the migration path:

1. `.\backup.ps1 migrate` — archive the current home.
2. Set (or clear) `SANDBOX_HOME_HOST_PATH` in `.env`.
3. `docker compose up -d` — boots with the other storage backend.
4. `.\restore.ps1 migrate` — restores into the new location.

The named volume is never deleted by switching, so you can flip back and forth without losing the old copy. SSH host identity is unaffected either way — the keys live on their own volume.

**Caveats:**

- **File watchers don't see host-side edits.** inotify events do not cross the Windows filesystem bridge, so `vite`/`nodemon`/`jest --watch` only react to changes made *inside* the container. Use polling when editing from Windows (e.g. `CHOKIDAR_USEPOLLING=true`).
- **Slower I/O.** Many-small-file workloads (npm installs, builds) run noticeably slower through the bridge than on the native volume.
- **git "dubious ownership" on host-created repos** — files made on Windows appear root-owned in the container. The entrypoint sets `safe.directory '*'` automatically when this option is on.
- **Your home is host-visible.** Agent auth tokens, shell history, and `~/.ssh/environment` (which carries any API keys from `.env`) sit in a normal host folder now, guarded by host OS permissions instead of living inside the Docker VM.
- **`docker compose down -v` no longer wipes home** — it's your folder. Backups and restores work unchanged.
- Close host-side apps holding the folder (editors, terminals) while running `restore` — it deletes and re-extracts everything in it.

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
client-a-ssh-keys
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

**Disk (Windows/WSL2 only):**

```env
SANDBOX_DEFAULT_VHD_SIZE=50GB
SANDBOX_SPARSE_VHD=true
```

WSL2 keeps its filesystem in a virtual disk that grows up to a fixed ceiling. `setup-sandbox.ps1` writes both values into `~/.wslconfig` at build time. `SANDBOX_DEFAULT_VHD_SIZE` is that ceiling — raise it before you fill it, since growing it afterwards means resizing the VHD by hand. `SANDBOX_SPARSE_VHD=true` lets the disk file shrink on the host when you delete data inside it; without it the VHD only ever grows. Both apply to **newly created** WSL distributions, so changing them does not resize a distribution that already exists. They are ignored on Linux and macOS hosts.

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

**Two exceptions.** `TS_AUTHKEY` and `HERMES_WEBUI_PASSWORD` are infrastructure credentials consumed by docker-compose and the entrypoint, never by a shell — so they are held back from `~/.ssh/environment`. A reusable tailnet auth key can enrol new devices, and there is no reason every process in the box should hold one. If you add another credential in that category, add it to the skip list in `scripts/entrypoint` alongside them.

`HERMES_WEBUI_PASSWORD` has one narrower outlet: the entrypoint writes it, with the boot host/port, to `/opt/hermes-webui/.env` (mode `0600`, the file `ctl.sh` already reads). Without it, `hermes-webui start` from inside the box would come back up on `127.0.0.1` and unauthenticated, since no session can supply the password. Only the webui reads that file — unlike `~/.ssh/environment`, which puts a value in every process's environment.

Two caveats. Session-scoped variables (`PATH`, `HOME`, `USER`, `SHELL`, `TERM`, …) are skipped — the shell owns those, and exporting the container's copies would break logins. And the file is rewritten on every container start, so a key is picked up by `docker compose up -d` and disappears once you delete it from `.env` and restart.

The file is mode `0600` and owned by the sandbox user. Note that this puts your keys on the persisted home volume, so they land in backup archives — see [Security Notes](#security-notes).

### Security Notes

- Backups archive your home directory only — no longer `/etc/shadow` or system secrets. They still contain whatever lives under `$HOME`: `gh`/Claude/Codex auth tokens, shell history, and any private keys you keep there. Treat backup archives as private secrets.
- The sandbox runs with passwordless `sudo`. A tagged Tailscale auth key (`tag:vibebox`, see [Step 2](#step-2--get-a-tailscale-auth-key-required)) lets tailnet ACLs bound what a compromised sandbox can reach.
- **The sandbox is not a security boundary against the host.** `docker` inside the box is Docker-*out*-of-Docker: the host's `/var/run/docker.sock` is bind-mounted in. Control of that socket is equivalent to root on the Docker host — anything in the sandbox, including an agent acting on its own, can start a container that mounts the host filesystem. This is the cost of running builds and compose stacks inside the box; if you do not want it, remove the `/var/run/docker.sock` mount from `docker-compose.yml` and the sandbox simply has no daemon to talk to (the entrypoint says so at boot rather than leaving you to discover it). Treat the sandbox as a convenience boundary — a place to keep agent mess contained — not as containment for code you actively distrust.
- The container does **not** run privileged, and the socket is left at mode `0660` wherever possible: the entrypoint re-points the container's `docker` group at the gid the socket actually carries, which is what makes group access work at all. On hosts that expose a root-owned socket with no distinct group (Docker Desktop, OrbStack), that alignment is impossible and the entrypoint falls back to mode `0666`, announcing it at boot. That fallback widens access to every user in the container — in practice only the sandbox user, but worth knowing.
- `TS_AUTHKEY` and `HERMES_WEBUI_PASSWORD` are deliberately **not** forwarded into shell sessions (see [API Keys](#api-keys)). Everything else in `.env` is.
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
hermes-webui status|logs|restart|stop|start
```

(`hermes-webui` is a wrapper on `$PATH`; `/opt/hermes-webui/ctl.sh` works too.)

`start` and `restart` need no arguments: the entrypoint records the boot host/port and password in `/opt/hermes-webui/.env`, so a hand-restarted webui comes back on the same tailnet-facing bind with authentication intact (see [API Keys](#api-keys)).

Logs are at `~/.hermes/webui.log`.

**`onboard` pauses the webui.** If your dotfiles manifest tracks `.hermes`, `onboard` stops the webui while `dotfiles link` runs and starts it again afterwards. On a bind-mounted home (`SANDBOX_HOME_HOST_PATH`) the link *cannot* succeed otherwise — 9p refuses to rename a directory whose files the daemon holds open, reporting it as `Permission denied`.

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

**Cross-platform tip:** guard macOS- or Linux-specific config behind an OS check so the same dotfiles work everywhere:

```sh
if [[ "$(uname)" == "Darwin" ]]; then
  # macOS-only
fi
```
