# Phase 7 evidence: migration

Status: **prepared and blocked.** The tooling is written and the target VM
exists; the copy itself has not run.

## What the user authorized

2026-09-13: "proceed with copying over / migrating the data from the old
version of vibebox into the VM version. Also, let's just call it 'vibebox' not
'vibebox-vm' for live use."

This is the Gate A go-ahead. It arrived before the Gate A report was written,
so [`gate-a-report.md`](./gate-a-report.md) is a record rather than a request.

## Done

- **Renamed.** `VM_NAME=vibebox`. Multipass cannot rename an instance, so
  `vibebox` was created fresh, provisioned, and reached marker state `ready`
  with guest user `herwin` and image hash `d0fe84bb5f80…`.
- **Disk raised to 64 GB** at create time, since real data was about to land in
  it and the size is create-time only. Dynamically allocated, so unused
  capacity costs nothing.
- **`vibebox migrate` written** (`vm/host/lib/migrate.ps1`) — the work order's
  Phase 7 deliverable. Read-only at the source; extracts to a staging
  directory rather than `/`; copies into the existing home instead of
  replacing it; assigns ownership by name; retargets absolute symlinks from
  the old home; skips regenerable caches by default.
- **Source selected and justified** — see below.

## Not done, and why

The copy did not run. `multipassd` wedged for the second time today, mid-way
through `vibebox start`:

```
vibebox: multipass info vibebox --format json timed out after 300 seconds.
$ multipass list      # 180s, no output
EXIT=124
```

`vibebox` is therefore stopped and unreachable (TCP 22 closed), and starting it
needs either a working daemon or `Get-VM`/`Start-VM`, which need elevation.
The user was away, so neither was available.

`vibebox-vm` — the earlier synthetic instance — was still running and
reachable throughout, which is how this was diagnosed without the daemon.

## Source selection

Chosen: `backups/vibebox/vibebox-backup-migrate.tar.gz` (12 GB, 2026-08-20).

Verified structure:

```
drwxrwxrwx root/root         0 2026-08-19 23:27 home/dev/
-rw-rw-r-- 1000/1000      3833 2026-08-03 19:51 home/dev/.bashrc
lrwxrwxrwx 1000/1000         0 2026-08-15 09:59 home/dev/.agents/skills/... -> /home/dev/.local/share/...
```

Relative paths, real modes, real uid/gid, symlinks intact.

**Rejected: `C:/vibebox`.** It holds the same vintage (nothing newer than
2026-08-25) but sits on NTFS, so POSIX modes, executable bits and the `600` on
private keys are already gone. Copying from there would have produced a home
directory that looked complete and behaved wrongly.

**Rejected: the live Docker volume.** It is the only current copy — its VHDX
was written 2026-09-12 — but reaching it means starting Docker Desktop, and
`legacy/docker-compose.yml` declares `restart: unless-stopped` on the legacy
container. Starting the daemon would start the user's legacy box, which the
standing constraints forbid (§1.1) and which is a stop condition (§8.7). Not
done while the user was away and unable to consent.

## Consequence: a delta is owed

**The prepared migration is a 2026-08-20 baseline, about three and a half
weeks stale.** This matches the work order's own Phase 7 → Phase 8 model
(bulk migrate, then delta sync at cutover) but it must not be mistaken for a
complete copy. Anything created or changed on the legacy box since 2026-08-20
is not in it.

The delta needs the user present: Docker Desktop starts, the legacy box comes
up, a fresh backup is taken from it, and that archive is migrated over the
baseline.

## The absolute-symlink problem

The legacy home is full of symlinks whose targets are absolute paths into
`/home/dev`:

```
.gitconfig -> /home/dev/.dotfiles/.gitconfig
.hermes    -> /home/dev/.dotfiles/.hermes
.agents/skills/subagent-orchestration -> /home/dev/.local/share/harnessam/skills/...
```

Under `herwin` every one of these dangles. Extraction and `chown` alone do not
fix it, because the link *target* is data, not metadata. Both
`Invoke-VibeboxMigrate` and the cross-account `vibebox restore` path now
rewrite `/home/<source>/…` targets to `/home/<target>/…` and report how many
they changed, plus how many dangling links remain afterwards — a non-zero
remainder means something pointed outside the home directory and needs a look.

This is the concrete reason the `dev` → `herwin` rename was worth doing before
data landed rather than after.

## To resume

```powershell
# 1. Unwedge the daemon (elevated; force-kill first -- a plain restart hangs)
taskkill /F /T /IM multipassd.exe
Start-Service Multipass

# 2. Bring the VM up
.\vm\host\vibebox.ps1 start
.\vm\host\vibebox.ps1 status

# 3. Migrate the baseline
.\vm\host\vibebox.ps1 migrate -Archive .\backups\vibebox\vibebox-backup-migrate.tar.gz -SourceUser dev -DryRun
.\vm\host\vibebox.ps1 migrate -Archive .\backups\vibebox\vibebox-backup-migrate.tar.gz -SourceUser dev
```

Then, with the user present, take a fresh legacy backup and repeat step 3 with
it to close the delta.
