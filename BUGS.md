# Known Bugs

No open bugs.

**Caveat on everything below:** these were found by reading the code, and fixed the
same way. Docker was not available in the environment where the work was done, so
none of it has been exercised by a real build or boot. The first `docker compose up
-d --build` after this is the actual test — watch the entrypoint's output.

## Fixed Bugs

### `hermes update`: "error: cannot open '.git/FETCH_HEAD': Permission denied"

**Root cause:** the Hermes installer, run as root by the Dockerfile, takes its FHS
layout on Linux: the git checkout and its venv go to `/usr/local/lib/hermes-agent`,
the launchers to `/usr/local/bin`, uv-managed Python to `/usr/local/share/uv`, and
only per-user data to `$HERMES_HOME`. `hermes update` is a `git pull` plus a
dependency sync **in that tree**, run as the invoking user with no `sudo` anywhere in
its path — so a root-owned tree left the sandbox user unable to update the agent at
all. It failed on the first write, before any network call. (The stamp
`/usr/local/lib/hermes-agent/.install_method` says `git`, so the CLI correctly took
the git-update path; being inside a container was not the issue.)

**Where it reproduced:** every box, on the first `hermes update`.

**Fix:** the install tree and the uv Python directory are chowned to the sandbox user
inside the same `RUN` that installs them — same layer, so nothing is duplicated into
the image. The same treatment is applied to `/opt/codegraph`, which had the identical
problem (documented in the README as "use `update`, not `codegraph upgrade`"), and its
launcher on `$PATH` now points at `/opt/codegraph/current` rather than the versioned
directory the installer's prune step deletes on the next upgrade. Build check 8b
asserts the ownership invariant so a change in an upstream installer's layout surfaces
at build time, and `scripts/update` re-takes ownership of any of these trees it finds
root-owned — so an existing box is repaired by running `update`, not only by a rebuild.

**Also fixed in `scripts/update` while auditing the other pre-installed tools:**

- npm globals were updated with `npm update -g`, which for globals stays inside the
  semver range a package was installed under and so never crosses a major — Claude
  Code and Codex both move majors. Now reinstalled explicitly at `@latest`, mirroring
  the Dockerfile's list, with `--ignore-scripts` preserved for Pi.
- The Hermes step re-ran the installer as the sandbox user, which takes the *per-user*
  layout: a second full checkout and venv under `~/.hermes` on the persisted home
  volume, with `/usr/local/bin/hermes` re-pointed at it and the image copy orphaned.
  Now `hermes update`, with a reinstall pinned to `HERMES_INSTALL_DIR` as the fallback.
- Antigravity (`agy`) and `dotfiles` were pre-installed but had no update step at all.
  Both now have one; the `dotfiles` download is smoke-tested before it is swapped in,
  so a truncated fetch cannot leave the box without the tool `onboard` depends on.
- `bun upgrade` was a separate step, but this image installs Bun as an npm global.
  It is updated with the other npm globals instead.

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
