# Vibebox

A containerized Linux development workspace for agent-heavy coding from a Windows host. It provides SSH access through Tailscale, persistent home-directory storage, common coding tools, and sandbox-scoped backup/restore.

This is optimized for convenience with some guardrails. It is not a high-security isolation boundary because the user still has passwordless sudo inside the container.

## What Is Included

- SSH key authentication with password login disabled.
- Tailscale sidecar for remote access without opening a public port.
- Persistent Docker volumes for `/home/<SANDBOX_USERNAME>` plus `/etc`, `/opt`, and `/usr/local` (config drift and self-installed tools survive rebuilds).
- Scoped backups in `backups/<SANDBOX_NAME>/` covering all persisted volumes.
- `backup` command inside the container and host scripts: `backup.ps1` / `restore.ps1` (Windows) and `backup.sh` / `restore.sh` (Linux/macOS).
- Node.js, npm, Bun, Python, Git, GitHub CLI, Claude Code, Codex CLI, common language servers, tmux, zsh, ripgrep, fzf, jq, and common build utilities.

## Base Image Choice

The default base image uses the current Ubuntu LTS line:

```env
BASE_IMAGE=ubuntu:24.04
```

For mostly vibe-coding, web apps, scripts, CLIs, and normal project work, this is the better default than CUDA. It is smaller, faster to rebuild, and has less attack surface.

Use CUDA only when you actually need CUDA runtime libraries inside the container:

```env
# Pin a specific CUDA patch tag rather than :latest for reproducible rebuilds.
BASE_IMAGE=nvidia/cuda:13.3.0-cudnn-runtime-ubuntu24.04
```

If you use the CUDA base and need GPU passthrough, start with the GPU override:

```powershell
docker compose -f docker-compose.yml -f docker-compose.gpu.yml up -d --build
```

## Setup

1. Copy `.env.example` to `.env`.

2. Set a unique sandbox name if you may run more than one sandbox:

   ```env
   SANDBOX_NAME=vibebox
   SANDBOX_USERNAME=dev
   SSH_PORT=22
   ```

   Use a different `SANDBOX_NAME` and `SSH_PORT` for each sandbox. Also set
   `TS_AUTHKEY` (see step 5 and `.env.example`) so Tailscale logs in automatically.

3. Create `authorized_keys` from the example and add your public SSH key:

   ```powershell
   Copy-Item authorized_keys.example authorized_keys
   notepad authorized_keys
   ```

   `authorized_keys` is intentionally ignored by Git (and `.dockerignore`d). It is local machine identity/config, not project source.

   The file is bind-mounted **read-only** into the container at `/home/<SANDBOX_USERNAME>/.ssh/authorized_keys`. Because it is a live bind mount, editing `authorized_keys` on the host takes effect on the **next SSH connection** with no restart or rebuild — `sshd` re-reads it on each authentication. Add one public key per line for multiple keys. The mount is read-only on purpose: the host file is the single source of truth, so keys cannot be added from inside the container.

4. Build and start:

   ```powershell
   # Windows host
   .\setup-sandbox.ps1
   ```

   ```bash
   # Linux/macOS host (make the scripts executable once after checkout)
   chmod +x setup-sandbox.sh backup.sh restore.sh
   ./setup-sandbox.sh
   ```

5. Authenticate Tailscale.

   Recommended: set `TS_AUTHKEY` in `.env` to a **reusable + ephemeral** auth key
   from <https://login.tailscale.com/admin/settings/keys>, and the node logs in
   automatically on startup. Without an auth key the tailscale container has
   nothing to log in with, exits, and gets restarted every ~minute — which also
   breaks local SSH — so an auth key is strongly recommended. An *ephemeral* key
   additionally keeps your tailnet tidy: a stale node auto-removes when it goes
   offline, so you don't accumulate `<SANDBOX_NAME>-1`, `<SANDBOX_NAME>-2`, ...

   To authenticate interactively instead, leave `TS_AUTHKEY` blank and open the
   login URL printed in the container logs:

   ```powershell
   docker logs <SANDBOX_NAME>-tailscale
   ```

6. Connect locally (from the Docker host):

   ```powershell
   ssh -p <SSH_PORT> <SANDBOX_USERNAME>@127.0.0.1
   ```

   Use `127.0.0.1`, **not** `localhost`: the port is published IPv4-only, and on
   Windows `localhost` resolves to IPv6 (`::1`) first, which fails with
   "Connection refused". The setup scripts also write an `~/.ssh/config` alias on
   the host, so you can just run `ssh <SANDBOX_NAME>`.

   Connect remotely from any other device on your tailnet:

   ```bash
   ssh <SANDBOX_USERNAME>@<SANDBOX_NAME>
   ```

   The tailnet connection always uses SSH port **22** — do **not** pass
   `-p <SSH_PORT>`. `SSH_PORT` only remaps the host-local port on the Docker host
   (`127.0.0.1:<SSH_PORT> -> 22`); it has no effect over the tailnet, where
   Tailscale routes the node's port 22 to the container's sshd.

## Persistence And State

The dividing line for what survives is the persisted volumes versus the rest of the OS layer.

**Survives `docker compose down` / `up`, and even `--build` rebuilds:**

- `/home/<SANDBOX_USERNAME>` — all your files, settings, and shell history. Stored in the `<SANDBOX_NAME>-home` named volume.
- `/etc`, `/opt`, and `/usr/local` — persisted in the `<SANDBOX_NAME>-etc`, `<SANDBOX_NAME>-opt`, and `<SANDBOX_NAME>-usr-local` named volumes. This captures config drift (e.g. edits under `/etc`), self-installed tools dropped in `/usr/local/bin`, and keeps SSH host keys (`/etc/ssh/ssh_host_*`) stable across rebuilds so you do not get host-key-changed warnings.
- Tailscale auth/identity — stored in the `<SANDBOX_NAME>-tailscale-state` named volume, so you do not re-authenticate after a rebuild.
- `authorized_keys` and `backups/` — these live on the host as bind mounts, so they are outside the container lifecycle entirely.

**Does NOT survive `docker compose down` / `up`:**

- Anything outside the persisted paths above: most notably system packages, which install into `/usr` (apt) — `/usr/lib`, `/usr/bin`, and npm globals under `/usr/lib/node_modules` are **not** persisted. They live in the container's writable layer, which is destroyed when `down` removes the container. `up` then creates a fresh container from the image, resetting that layer to whatever the Dockerfile baked in.

Practical consequence: the in-container `update` command upgrades apt and npm packages, but those land in `/usr` and are lost on a `down`/`up` cycle. To make a system package permanent, add it to the Dockerfile (the system layer is intentionally rebuildable from the image). `/usr` is deliberately not persisted because it is multiple GB of image-reproducible content; persisting it would bloat volumes and every backup by gigabytes.

**Rebuild-shadow caveat for persisted system folders:** because a named volume is seeded from the image only when it is first created (while empty), later image changes to `/etc`, `/opt`, or `/usr/local` are **shadowed** by the existing volume and will not take effect until the volume is recreated. Concretely:

- Changing `SANDBOX_USERNAME` after the `/etc` volume exists will not rewrite `/etc/passwd`; the old user entry persists. Recreate the `-etc` volume (or start from a fresh `SANDBOX_NAME`) when changing the username.
- Dockerfile changes to `sshd_config` or to the baked-in `/usr/local/bin` tools (`agy`, `herdr`, `omp`) will not reach an existing sandbox until you recreate the relevant volume.

To force a persisted system folder back to image defaults, remove its volume and bring the stack back up, for example: `docker volume rm <SANDBOX_NAME>-etc` then `docker compose up -d`.

Two distinctions:

- `docker compose stop` / `start` keeps the same container, so the writable layer and system changes are preserved. It is `down` specifically that resets the OS layer.
- `docker compose down -v` additionally deletes the named volumes, which **wipes your home directory, the persisted `/etc`, `/opt`, `/usr/local` volumes, and Tailscale auth**. Avoid the `-v` flag unless you intend a full reset.

After pulling these changes into an existing sandbox, run `docker compose up -d` once so the new `/etc`, `/opt`, and `/usr/local` volumes are created and seeded from the current image before you rely on backups or restore.

## Backups And Restore

Backups are scoped by sandbox:

```text
backups/<SANDBOX_NAME>/<SANDBOX_NAME>-backup-YYYYMMDD-HHMMSS.tar.gz
```

Create a backup from inside the container:

```bash
backup
backup before-refactor
```

Create a backup from the host:

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

Restore from the host:

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

A backup archives your home directory plus the persisted `/etc`, `/opt`, and `/usr/local` volumes into a single root-relative `.tar.gz`. Restore creates a `pre-restore` backup first, stops the workspace container, wipes those volumes including hidden files, extracts the selected backup back into each, then starts the workspace again. Older home-only backups (created before system folders were persisted) are detected automatically and restored into the home volume alone.

Backups older than `BACKUP_RETENTION_DAYS` are deleted when a new backup is created. The default is 7 days.

## Multiple Sandboxes

Each sandbox should have its own `.env` values:

```env
SANDBOX_NAME=client-a
SANDBOX_USERNAME=dev
SSH_PORT=2222
```

This changes container names, Docker volume names, Tailscale hostname, and backup folder. For example:

```text
client-a
client-a-tailscale
client-a-home
client-a-tailscale-state
backups/client-a/
```

## Resource Limits

The default runaway protections are:

```env
SANDBOX_MEM_LIMIT=8g
SANDBOX_CPUS=4
SANDBOX_PIDS_LIMIT=512
```

These are meant to stop runaway agent loops, accidental recursive process spawning, and oversized installs from taking over the host. Tune them upward for heavier builds.

## Tooling Decisions

Removed by default:

- Swift toolchain + `sourcekit-lsp`: removed because `sourcekit-lsp` only ships inside the full Swift toolchain, which was ~3.6 GB — roughly 39% of the image and its single largest component. Install on demand with `swiftly` if you need Swift.
- Swift's apt prerequisites: `clang` and the dev headers `libcurl4-openssl-dev`, `libncurses-dev`, `libpython3-dev`, `libxml2-dev`, `libz3-dev` were added only to support the Swift toolchain. They are removed along with it (`clang` was the bulk; `build-essential`'s `gcc` remains for general native builds). Re-add a specific `-dev` package if a future native build needs it.
- `vim`: `nano` remains; install `vim` yourself if you want it.
- `net-tools`: legacy networking tools; modern images should use `iproute2` style commands.
- `python3-dev`: only needed when compiling Python packages against CPython headers.
- `git-lfs`: useful for ML models and large binary assets, but unnecessary for most vibe-coding.
- CUDA base image: available as an option, not the default.

Kept:

- `build-essential`: worth keeping because npm and Python packages often need native compilation through `node-gyp`, `make`, `gcc`, or related build tooling.
- `pkg-config` and `zlib1g-dev`: small, broadly useful native-build dependencies (not Swift-specific), so retained even though Swift also used them.

The npm install layer also runs `npm cache clean --force` so the global CLI install does not leave a ~400 MB cache baked into the image.

## Tool Versions

The sandbox builds from current tool releases by default:

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

The normal sandbox toolchain path should stay on `latest`. Backups rewind the persisted volumes (home, `/etc`, `/opt`, `/usr/local`); the core toolchain (Node, npm globals, system packages) lives in `/usr`, which is not persisted, so rebuilt images still intentionally track current tools.

## Language Servers

Preinstalled language servers focus on common vibe-coding stacks:

- Python: `pyright`
- TypeScript/JavaScript: `typescript-language-server` plus `typescript`
- HTML, CSS, ESLint, JSON: `vscode-langservers-extracted`
- YAML: `yaml-language-server`
- Bash: `bash-language-server`
- Tailwind CSS: `tailwindcss-language-server`

These are all small, Node-based servers. Heavier language servers that ship with a full toolchain — `sourcekit-lsp` (Swift), `rust-analyzer`, `gopls`, Terraform LSP, Vue, Svelte, Astro, and Angular — are not installed by default. They are worth adding when the sandbox is dedicated to those stacks, but they pull the image toward a heavier, more opinionated dev distribution. Swift in particular is excluded because `sourcekit-lsp` only ships as part of the ~3.6 GB Swift toolchain; install it on demand with `swiftly` if you need it.

## Ignore Files

`.gitignore` prevents local runtime data such as `.env` and `backups/` from being committed.

`.dockerignore` controls what gets sent to Docker during `docker build`. It keeps backup archives, logs, `.env`, and other local state out of the build context. That makes builds faster and avoids accidentally baking local secrets or old backups into an image layer.

## Supply-Chain Drift

Supply-chain drift means a rebuild later does not install the same software you had before. Floating tags such as `latest`, unpinned npm packages, and `curl | bash` installers can change without any change in your repo.

For your use case, it matters because coding-agent CLIs are powerful: they read and write your repo, run commands, and often hold auth tokens. A bad or broken release can disrupt your workflow, leak state, or run unexpected code. This repo now chooses freshness over strict reproducibility for the default build, so keep backups private and use exact versions temporarily if you need to recreate a known-good environment.

## Backup Contamination

Backup contamination means your backups contain more state than you intended: shell history, CLI logs, auth metadata, cached prompts, local config, generated files, or copied keys.

The value of avoiding it is practical: backups should help you rewind work, not become a pile of sensitive operational history. This project now keeps backups out of Git by default and scopes them per sandbox. The backup command skips common cache folders, but it archives your home directory plus `/etc`, `/opt`, and `/usr/local` — and `/etc` in particular includes sensitive files such as `/etc/shadow` and SSH host keys. Treat backup archives as private secrets.

## Management Commands

Start:

```powershell
docker compose up -d
```

Start with rebuild:

```powershell
docker compose up -d --build
```

Start CUDA/GPU mode:

```powershell
docker compose -f docker-compose.yml -f docker-compose.gpu.yml up -d --build
```

Stop:

```powershell
docker compose down
```

Check health:

```powershell
docker compose ps
```
