# Known Bugs

No open bugs.

**Caveat on everything below:** these were found by reading the code, and fixed the
same way. Docker was not available in the environment where the work was done, so
none of it has been exercised by a real build or boot. The first `docker compose up
-d --build` after this is the actual test — watch the entrypoint's output.

## Fixed Bugs

### `onboard`: "cannot move '~/.hermes' to '~/.hermes.bak': Permission denied"

**Root cause:** not a permission problem at all. With `SANDBOX_HOME_HOST_PATH` set,
`$HOME` is a 9p/drvfs mount of a host folder, and 9p carries Windows semantics: a
directory holding open file handles cannot be renamed, and the refusal surfaces as
`EACCES`. The Hermes WebUI starts at boot and keeps `webui.log` and `state.db-wal`
open under `~/.hermes`, so `dotfiles link` — which renames a colliding path to
`<name>.bak` before symlinking the repo copy in — could never move it aside. Ownership
was correct throughout (`dev:dev`, parent `drwxrwxrwx`), which is what makes the error
message so misleading.

**Where it reproduced:** first `onboard` on a bind-mounted home whose dotfiles manifest
tracks `.hermes`. A named-volume home is unaffected — ext4 renames a busy directory
happily, so this never appears on the default setup or on a Linux host.

**Fix:** `onboard` pauses the webui for the seconds the link takes and starts it again
afterwards. Resuming needed the password, which the entrypoint deliberately withholds
from shell sessions — so the entrypoint now also records the boot binding and password
in `/opt/hermes-webui/.env` (mode `0600`, the mechanism `ctl.sh` already reads). That
independently fixes `hermes-webui start` from inside the box, which until now came back
up on `127.0.0.1` **and unauthenticated**.

### `dotfiles`: "Permission denied" inside the container

**Root cause:** Docker's `ADD` of a remote URL creates the file `600` (root-only).
The follow-up `chmod +x` only added the execute bit, giving `711`. Bash cannot run a
script it cannot *read*, so a non-owner got "Permission denied".

**Where it reproduced:** before `1badfab`, when `/usr/local/bin/dotfiles` stayed
root-owned. That commit added a recursive chown over `/usr/local`, making the sandbox
user the owner — and `711` grants the owner `rwx`, which masked the symptom.

**Fix:** `chmod 755` (Dockerfile). Kept even though the symptom is masked: it states
the intended mode directly rather than depending on an unrelated chown, and the chown
has since been narrowed (see below), which would have unmasked it again.

### The `docker` group grant was inert; `chmod 666` was load-bearing

**Root cause:** the image created a container-local `docker` group and the entrypoint
ran `chown root:docker /var/run/docker.sock`. Access to a *bind-mounted* socket is
decided by the **host's** gid, so a container-local gid granted nothing. The
`chmod 666` on the next line was the only reason docker worked for the sandbox user —
meaning the obvious "tighten that 666" would have silently broken docker access.

**Fix:** the entrypoint now reads the socket's real gid and re-points the container's
`docker` group at it (`groupmod -o -g`), then uses mode `0660`. Where the socket is
root-owned with no distinct group (Docker Desktop, OrbStack), alignment would mean
putting the sandbox user in the root group, so it falls back to `0666` — but says so
at boot instead of doing it silently and always.

### A missing docker socket left a CLI with no daemon and no message

**Root cause:** if the socket bind-mount did not materialise, the entrypoint fell
through to `service docker start`, whose failure was swallowed by `|| true`. Result:
`docker` on `$PATH`, no daemon, no diagnostic. Build check 9b could not catch it —
`command -v docker` passes regardless.

**Fix:** the fallback is gone (see below) and the entrypoint now prints an explicit
warning when the socket is absent, and a distinct one when the mount materialised as
a non-empty directory (a Windows-host failure mode).

### Two half-implemented Docker architectures

**Root cause:** the stack mounted the host socket (Docker-out-of-Docker) *and* could
start a local daemon (Docker-in-Docker) as a fallback. The fallback was the only
reason the sandbox ran `privileged: true`, and it was unreachable on any healthy host.

**Fix:** committed to Docker-out-of-Docker. Removed the daemon-start block from
`scripts/entrypoint` and `privileged: true` from `docker-compose.yml`.

### Infrastructure credentials forwarded into every shell

**Root cause:** `env_file` loads all of `.env`, and the entrypoint republished
everything not session-scoped into `~/.ssh/environment`. That included `TS_AUTHKEY` —
a reusable tailnet key that can enrol new devices — and `HERMES_WEBUI_PASSWORD`.
Both are consumed by compose and the entrypoint; no shell needs either.

**Fix:** both are skipped when writing `~/.ssh/environment`. User API keys still pass
through, as documented.

### `chown -R /usr/local /opt` duplicated the toolchain into an image layer

**Root cause:** chown rewrites the owner of every file it touches, and Docker copies
each changed file into a new layer. Recursing over `/usr/local/lib/node_modules`
(every npm global) plus the codegraph bundle and hermes-webui venv duplicated the
whole toolchain in the image.

**Fix:** narrowed to `/usr/local/bin`, plus a non-recursive chown of `/opt` itself so
a tool can still create its own directory there. Nothing needed the wider scope —
every write path in `scripts/update` runs under `sudo`, and `/opt/hermes-webui`, the
one tree updated without sudo, is chowned at its own install step. Size saving is
unmeasured (no Docker available); the reasoning is that the layer should now be
kilobytes.

**Watch on first onboard.** `scripts/onboard` runs as the sandbox user with no sudo
anywhere in it. `dotfiles init`/`link` and `rtk init` write under `$HOME`, and
`codegraph install` is documented as a per-user config step (the bundle itself is
installed to `/opt/codegraph` at build time) — so none of them should need the
ownership that was removed. This has not been exercised. If `codegraph install`
starts warning after this change, that assumption was wrong: `sudo chown -R
"$USER" /opt/codegraph` in the box confirms it, and the fix is to chown that tree at
its install step the way step 8b does for hermes-webui.

### SSH host identity was in no backup at all

**Root cause:** moving host keys out of the home volume into `<name>-ssh-keys` is what
makes them survive a restore — but it also meant nothing captured them. Losing the
volume, or moving hosts, lost the identity permanently.

**Fix:** `backup.sh` / `backup.ps1` archive the volume under `ssh-identity/`. Restore
still leaves the existing identity alone by default; `--restore-identity` /
`-RestoreIdentity` adopts the archived one. Archives predating this are detected and
reported rather than erroring. The in-container `backup` is unchanged — it runs as the
sandbox user and cannot read the root-owned keys.

### `herdr: command not found`

**Root cause:** the Dockerfile's herdr install ran the official script into
`~/.local/bin` (root's home, at build time) and then did `cp ... /usr/local/bin/herdr
2>/dev/null || true` followed by `chmod +x /usr/local/bin/herdr`. If the `cp` silently
no-op'd, the following `chmod` on a nonexistent file failed, and the whole step was
tolerated (`|| echo "Herdr CLI setup skipped"`) — leaving the image with no herdr on
`$PATH` at all. `scripts/update` had the identical pattern and would have re-hit the
same silent no-op on every future `update` run.

**Where it reproduced:** confirmed live via SSH on the running container —
`/usr/local/bin/herdr` didn't exist; running the installer by hand dropped a working
binary in `~/.local/bin` with the installer's own warning that the directory isn't on
`$PATH`.

**Fix:** install straight to the destination with the herdr installer's own
`HERDR_INSTALL_DIR` env var (same pattern already used for CodeGraph in this file),
in both the Dockerfile and `scripts/update`. Verified live: `curl ... | sudo env
HERDR_INSTALL_DIR=/usr/local/bin sh` lands the binary directly in `/usr/local/bin`.

### `claude`/`codex` installed but failing with "native binary not installed"

**Root cause:** both ship their real CLI as an npm **optional** dependency (a
platform-native package). npm treats a failed optional-dependency install as
non-fatal, so `npm install -g` in the Dockerfile (no `|| true` around it, so it never
failed the build) could exit 0 while silently missing the native package — leaving a
wrapper script on `$PATH` that throws on every invocation. Build check 8b only ran
`command -v claude`/`command -v codex`, which passes regardless.

**Where it reproduced:** confirmed live via SSH — `claude --version` and `codex
--version` both failed outright (not just their self-update paths) with "native binary
not installed" / "Missing optional dependency ...-linux-x64".

**Fix:** `sudo npm install -g @anthropic-ai/claude-code@latest @openai/codex@latest`
to force npm to re-resolve the missing optional packages (fixes the running
container immediately). Build check 8b now runs `"$t" --version` for the daily-driver
tools, not just `command -v`, so a build that produces a non-functional CLI fails
loudly instead of shipping.

### `hermes update`: "cannot open '.git/FETCH_HEAD': Permission denied"

**Root cause:** the Hermes Agent installer runs as root at build time and lands its
real install tree — a git clone — at `/usr/local/lib/hermes-agent` (the `/usr/local/bin/hermes`
wrapper just execs into it). `hermes update` runs as the sandbox user with no sudo and
does a plain `git fetch` there, so a root-owned tree fails outright. Exactly the same
category as the `/opt/hermes-webui` case already fixed in step 7b — this install just
never got the matching chown.

**Where it reproduced:** confirmed live via SSH — `hermes update` failed with `error:
cannot open '.git/FETCH_HEAD': Permission denied`; `/usr/local/lib/hermes-agent` was
`root:root`.

**Fix:** Dockerfile step 7 now chowns `/usr/local/lib/hermes-agent` to `1000:1000`
right after install, mirroring step 7b. Confirmed live: `sudo chown -R dev:dev
/usr/local/lib/hermes-agent` then `hermes update` completed successfully.

### `update` silently ran a personal macOS dotfiles function instead of the real script

**Root cause:** the sandbox user's `~/.zshrc`, synced in by the `dotfiles` tool from a
personal (cross-platform) dotfiles repo, defined its own `update` shell function —
a generic "update everything" helper written for a laptop (`brew`, `softwareupdate`,
plain `npm update -g`, `claude update`, ...). zsh resolves a function before `$PATH`,
so typing `update` never reached `/usr/local/bin/update` (which correctly runs
`sudo npm update -g` etc.); it ran the personal function instead, which called `npm
update -g` **without** sudo — producing the `EACCES` errors on `/usr/lib/node_modules`.
Not a permissions bug: opening up ownership of the npm global directory would have
papered over the symptom while leaving the real cause (a name collision) in place.

**Where it reproduced:** confirmed live — `zsh -i -c 'type update'` resolved to `a
shell function from /home/dev/.zshrc`, not `/usr/local/bin/update`.

**Fix, two layers:** the immediate fix on the affected box was `dotfiles rm ~/.zshrc`
(unlinking it from the shared dotfiles repo, since a laptop-oriented `update` helper
doesn't belong in the sandbox) followed by deleting the conflicting function from the
now-local file. As a durable, image-level backstop for any dotfiles repo that defines
`update` again in the future, `/etc/zsh/zlogin` (sourced after `~/.zshrc` for every
login shell — confirmed live by sourcing order) now clears any `update`
function/alias before the prompt appears, so `command` resolution always falls
through to `/usr/local/bin/update`. This only covers login shells (plain `ssh
vibebox`); a non-login shell started inside another multiplexer would still see a
personal definition if one exists.
