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
| `~/.dotfiles/dotfiles.manifest` | One line per new dotfile path (if the tool has config) — lives in your dotfiles repo, not here |
| `README.md` | Coding tools table + dotfiles section + API Keys section (if needed) |

The in-container commands (`onboard`, `backup`, `update`, `launch`, `tailscale`, `hermes-webui`) and the `entrypoint` are real files in `scripts/`, `COPY`'d to `/usr/local/bin` by the Dockerfile — edit them directly. Dotfile paths are **not** in this repo any more: they live in the manifest inside your own dotfiles repo, managed by [dotter](https://github.com/execsumo/dotter).

If a tool is one you depend on daily, add it to the hard-fail loop in the Dockerfile's step 9b verification (`for t in claude codex bun node gh docker`); optional agents go in the warn loop. Anything installed with a tolerated (`|| echo ...`) step belongs in the warn loop — a hard-fail check on a tolerated install just relocates the build break.


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

> **The `cp` only works for self-contained single-file binaries** (rtk, herdr, hermes, agy).
> If the installer drops a *bundle* — a launcher script plus a runtime and libs — copying
> the launcher out of the bundle severs the relative path it uses to find its own runtime.
> CodeGraph is the cautionary example: its launcher resolves the bundle relative to its
> symlink-resolved path, so the `cp` above left it exec'ing a nonexistent `/usr/local/node`.
>
> For bundles, use the installer's own destination env vars and let it create the symlink.
> Put the bundle somewhere world-readable: run as root, the default `~/.foo` lands under
> `/root` (mode 700) and is invisible to the sandbox user. CodeGraph, worked:
>
> ```dockerfile
> RUN (curl -fsSL https://.../install.sh | \
>        env CODEGRAPH_INSTALL_DIR=/opt/codegraph CODEGRAPH_BIN_DIR=/usr/local/bin sh && \
>      chmod -R a+rX /opt/codegraph) || echo "CodeGraph setup skipped"
> ```
>
> The build-time check (step 9b) runs `<tool> --version`, not just `command -v`, precisely
> because a broken launcher still exists and is executable.

### apt package
Add to the existing `apt-get install -y` block (step 1).

### Wrapper script on `$PATH`
When the "tool" is really a shortcut — delegating to a sidecar container, or to a
long path inside `/opt` — add a file to `scripts/`. `COPY scripts/ /usr/local/bin/`
puts everything in that directory on `$PATH` automatically, so no Dockerfile install
step is needed. Two exist today:

```bash
# scripts/tailscale — run the tailscale CLI in the sidecar that owns the netns
exec docker exec -i "${SANDBOX_NAME:-vibebox}-tailscale" tailscale "$@"

# scripts/hermes-webui — shorthand for the webui control script
exec /opt/hermes-webui/ctl.sh "$@"
```

**You must add the new file to the explicit `chmod +x` list** in the Dockerfile right
after the `COPY` — the execute bit does not survive a Windows/git checkout reliably,
and that list is enumerated by name rather than globbed:

```dockerfile
RUN chmod +x /usr/local/bin/onboard /usr/local/bin/backup \
             /usr/local/bin/update  /usr/local/bin/launch \
             /usr/local/bin/hermes-webui /usr/local/bin/entrypoint /usr/local/bin/tailscale
```

Wrappers that shell out to `docker` (like `tailscale`) depend on the host Docker
socket being mounted; they fail at call time, not build time, if it isn't. `SANDBOX_NAME`
is passed into the container by docker-compose, so it resolves inside the sandbox.

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

The same bundle caveat as the install step applies — mirror whatever the Dockerfile does, or
the update will re-break a working install. CodeGraph's update step is the worked example.

---

## Dotfiles

Vibebox does not own dotfiles logic any more. It is handled by
[dotter](https://github.com/execsumo/dotter), a standalone tool installed into
the image by the Dockerfile. `onboard` calls it:

```bash
dotfiles init --repo "https://github.com/${GH_USER}/dotfiles"
dotfiles link
```

The manifest lives in **your dotfiles repo** (`~/.dotfiles/dotfiles.manifest`),
not in this one — so it is editable from any machine, not just a designated host.

**To track a new tool's config**, run this from wherever you are:

```bash
dotfiles add ~/.config/toolname/config.toml
dotfiles sync
```

That appends the manifest entry, moves the file into the repo, symlinks it back,
and commits — no need to edit anything in vibebox.

Manifest format is `type|relpath|label`:

- `type` = `file` (symlinked individually) or `dir` (symlinked whole)
- `relpath` = path relative to `$HOME`
- `label` = human-readable description

**Prefer `file` entries.** A `dir` entry tracks whatever the owning tool writes
there later — that has leaked a live API key plus 250MB of vendored binaries in
one case, and logs plus unix sockets in another. If a tool's config directory is
unknown, find its actual config file rather than defaulting to a `dir` entry for
`~/.config/toolname/`. `dotfiles add` audits directories and makes you confirm,
but that audit is a snapshot, not a guarantee.

**Bumping the tool version:** the Dockerfile pins it via `ARG DOTTER_REF=main`.
Pin a tag or SHA there if you want reproducible builds.

---

## Installed tools reference

| Tool | Install method | Binary location | Update method | Dotfiles |
|---|---|---|---|---|
| Claude Code | npm global | `/usr/local/bin/claude` | `npm update -g` | `.claude/settings.json`, `.claude/CLAUDE.md`, `.claude/commands/` |
| Codex CLI | npm global | `/usr/local/bin/codex` | `npm update -g` | `.codex/` |
| codeburn | npm global (tolerated) | `/usr/local/bin/codeburn` | `npm update -g` | `.config/codeburn/` |
| Antigravity (`agy`) | install script | `/usr/local/bin/agy` | re-run installer (no update cmd) | `.gemini/antigravity-cli/` |
| Herdr | install script | `/usr/local/bin/herdr` | re-run installer | `.config/herdr/` |
| Pi | npm global (tolerated, `--ignore-scripts`) | `/usr/local/bin/pi` | `npm update -g` | `.pi/` |
| RTK | install script | `/usr/local/bin/rtk` | re-run installer (update step 6) | `.config/rtk/` |
| Hermes Agent | install script | `/usr/local/bin/hermes` | re-run installer | `.hermes/` |
| Hermes WebUI | git clone + venv (tolerated) | `/opt/hermes-webui` | `git pull` + pip (update step 10) | state under `.hermes/webui/` |
| CodeGraph | install script (bundle in `/opt/codegraph`) | `/usr/local/bin/codegraph` → symlink into bundle | re-run installer via `update` (not `codegraph upgrade`) | — (per-project `.codegraph/`) |
| Bun | npm global | `/usr/local/bin/bun` | `bun upgrade` | — |
| Node.js | NodeSource apt | `/usr/bin/node` | apt upgrade | — |
| GitHub CLI | apt (official repo) | `/usr/bin/gh` | apt upgrade | — |
| Docker | apt (official repo) | `/usr/bin/docker` | apt upgrade | — |
| btop, htop | apt | `/usr/bin/btop` | apt upgrade | — |
| `tailscale` | wrapper script | `/usr/local/bin/tailscale` | edit `scripts/tailscale` | — |
| `hermes-webui` | wrapper script | `/usr/local/bin/hermes-webui` | edit `scripts/hermes-webui` | — |

Language servers (pyright, typescript-language-server, etc.) are all npm globals and are covered by `npm update -g`.
