# Known Bugs

No open bugs.

**Caveat on everything below:** these were found by reading the code, and fixed the
same way. Docker was not available in the environment where the work was done, so
none of it has been exercised by a real build or boot. The first `docker compose up
-d --build` after this is the actual test — watch the entrypoint's output.

## Fixed Bugs

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

**Fix:** narrowed to `/usr/local/bin`. Nothing needed the wider scope — every write
path in `scripts/update` runs under `sudo`, and `/opt/hermes-webui`, the one tree
updated without sudo, is chowned at its own install step. Size saving is unmeasured
(no Docker available); the reasoning is that the layer should now be kilobytes.

### SSH host identity was in no backup at all

**Root cause:** moving host keys out of the home volume into `<name>-ssh-keys` is what
makes them survive a restore — but it also meant nothing captured them. Losing the
volume, or moving hosts, lost the identity permanently.

**Fix:** `backup.sh` / `backup.ps1` archive the volume under `ssh-identity/`. Restore
still leaves the existing identity alone by default; `--restore-identity` /
`-RestoreIdentity` adopts the archived one. Archives predating this are detected and
reported rather than erroring. The in-container `backup` is unchanged — it runs as the
sandbox user and cannot read the root-owned keys.
