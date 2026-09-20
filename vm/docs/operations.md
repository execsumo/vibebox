# VM operations

The host entry point is `vm/host/vibebox.ps1`. Run it from **PowerShell 7
(`pwsh`) as Administrator** on the Windows host. Windows PowerShell 5.1 is not
supported. The guest remains usable with ordinary Ubuntu commands:
`systemctl`, `journalctl`, `apt`, `ss`, and the native Docker CLI.

No lifecycle command requires an elevated shell. Multipass drives Hyper-V
through its own LocalSystem daemon, and Vibebox proves instance ownership from
its own state marker plus the Multipass image hash rather than from `Get-VM`.

Multipass restores instances that were running when the host shut down, so the
VM normally comes back on its own after a Windows restart.

## Lifecycle

```powershell
.\vm\host\vibebox.ps1 doctor
.\vm\host\vibebox.ps1 create
.\vm\host\vibebox.ps1 status
.\vm\host\vibebox.ps1 ssh
.\vm\host\vibebox.ps1 stop
.\vm\host\vibebox.ps1 start
```

`destroy` and `rebuild` print the resolved instance and require `-Confirm`.
They never target an instance without a Vibebox state marker.

## Configuration

Edit the ignored `vm/vibebox.env`, then use:

```powershell
.\vm\host\vibebox.ps1 config show
```

`VM_CPUS`, `VM_MEMORY`, `VM_DISK`, `UBUNTU_RELEASE`, `VM_NAME` and
`GUEST_USER` are create-time settings. To change one, edit `vibebox.env`,
then `vibebox rebuild -Confirm` and restore from a backup. `vibebox status`
reports create-time drift, so the file and the live VM never disagree
silently. Guest policy (`GUEST_UFW`, `GUEST_SWAP_GB`, `GUEST_TIMEZONE`,
`NODE_MAJOR`, `TOOLS_*`) applies any time via the idempotent
`vibebox provision`.

The shipped timezone is `America/Los_Angeles`. It is an IANA timezone and can
be changed by provisioning.

## Backup and restore

Backups are host-initiated and use a restricted key:

```powershell
.\vm\host\vibebox.ps1 backup -Label before-change
.\vm\host\vibebox.ps1 restore -Archive D:\vibebox-backups\vibebox-vm\vibebox-vm-backup-before-change.tar.gz -DryRun
.\vm\host\vibebox.ps1 restore -Archive D:\vibebox-backups\vibebox-vm\vibebox-vm-backup-before-change.tar.gz
```

Restore is name-bound, refuses unsafe archive paths, maps ownership by Linux
login name, and stops the guest's managed services while extracting. Backup
archives without quiesce hooks are labeled crash-consistent.

Tailnet names are tracked in `vm/guest/tailnet.d/` and reconciled through the
namespaced command:

```powershell
.\vm\host\vibebox.ps1 tailnet list
.\vm\host\vibebox.ps1 tailnet add hermes --target http://127.0.0.1:8787
.\vm\host\vibebox.ps1 tailnet apply
```

The guest uses one Tailscale node and Tailscale Services. The tailnet policy
must grant each service before it can obtain a name and certificate.

## Updates and rebuilds

`update` upgrades the OS packages and the toolchain. It runs from inside the
guest or from the host, and both execute the same `/opt/vibebox/update.sh`:

```bash
update            # in the guest: apt + toolchain
update tools      # toolchain only -- safe mid-session
update os         # apt only
```

```powershell
.\vm\host\vibebox.ps1 update [-ToolsOnly|-OsOnly]
```

It uses `apt-get upgrade`, never `full-upgrade`: full-upgrade may remove
packages to satisfy dependencies, which an unattended update should not
decide. The toolchain half re-runs `provision/30-tools`, so `update` and
`provision` cannot disagree about how a tool is installed. Existing Hermes
installs use `hermes update` instead of the bootstrap installer, and the
managed Hermes gateway and WebUI are restarted after a successful Hermes
update. `TOOLS_UPDATE_POLICY=locked` pins tools to `manifest.lock`.

It does not silently change the OS contract -- release, guest user and other
create-time settings need `vibebox rebuild`.

APT services are not restarted automatically. `needrestart` runs in list-only
mode, because restarting `dbus` or `sshd` mid-command kills the channel the
command arrived on: the upgrade succeeds while the caller sees a failure.
Other services needing a restart and any pending reboot are reported; action
them with `vibebox restart`.

`vibebox provision` re-runs all idempotent guest phases. `vibebox rebuild`
creates a clean official Ubuntu guest and provisions it again. Restore user
data only after inspecting a dry run.

## Diagnostics

```powershell
.\vm\host\vibebox.ps1 status -Json
.\vm\host\vibebox.ps1 conformance -Json
.\vm\host\vibebox.ps1 console
```

Inside the guest, use `systemctl --failed`, `journalctl -b`, `ss -tlnp`,
`docker info`, `tailscale status`, and `df -h`. GPU is intentionally reported
as `none`; GPU workloads stay on the Windows Docker Desktop/WSL2 path.

## Migrating a legacy home directory

`vibebox migrate` brings a home directory from the container-era box into the
VM. It is read-only at the source: the input is a tarball the legacy box
produced, and nothing is ever run against the legacy container.

```powershell
.\vm\host\vibebox.ps1 migrate -Archive <path\to\backup.tar.gz> -SourceUser dev -DryRun
.\vm\host\vibebox.ps1 migrate -Archive <path\to\backup.tar.gz> -SourceUser dev
```

Use an archive the **legacy box itself** created, not a copy of the home
directory taken from Windows. A Windows-side copy sits on NTFS and has already
lost POSIX modes, executable bits and the `600` on private keys; the container's
own backup preserves all of it.

`-SourceUser` is the account the archive was made under. When it differs from
`GUEST_USER`, the migration:

1. extracts into a staging directory, never straight into `/`, so nothing can
   land outside the tree and the result is inspectable first;
2. copies into the existing home rather than replacing it, keeping the
   provisioned account's shell and tool state;
3. assigns ownership by name, never by numeric UID;
4. **retargets absolute symlinks** from `/home/<source>/...` to
   `/home/<target>/...`. Dotfile trees are full of these, and without this step
   every one of them silently dangles.

Regenerable caches (`.cache`, `.npm`, `.cargo/registry`, `.cargo/git`,
`go/pkg`) are skipped by default; they usually dominate the archive and rebuild
on first use. Pass `-IncludeCaches` to copy them anyway.

The command reports the entry count, resulting size, how many symlinks it
retargeted, and how many dangling symlinks remain. A non-zero dangling count
means something referenced a path outside the home directory and needs a look.

## Scheduled backups

```powershell
.\vm\host\vibebox.ps1 schedule enable -At 02:47
.\vm\host\vibebox.ps1 schedule status
.\vm\host\vibebox.ps1 schedule disable
```

`enable` registers a Windows scheduled task that runs `vibebox backup` daily.
The backup is host-initiated by design — the host pulls through a restricted,
forced-command SSH key — so the schedule lives on the host. A timer inside the
guest could not reach the archive destination.

The task runs as the current user at normal privilege. It deliberately does
*not* use "run whether logged on or not", which would mean storing credentials.
It is configured with `StartWhenAvailable` so a missed run (asleep, powered
off) catches up rather than being skipped, and it is allowed to run on battery
— a backup that only runs on mains power and never catches up is not a backup.

If the VM is stopped when the schedule fires, `backup` starts it, takes the
archive, and stops it again. A backup fires on a clock, not on the VM's state.

### What is backed up

Everything in the guest home **except** the paths listed in
`vm/guest/regenerable.conf`. That file is the single source of truth: the
guest-side backup producer reads it from `/opt/vibebox/regenerable.conf`, and
host-side `vibebox migrate` reads it from the repository, so the two cannot
drift apart.

The test for putting something in that list: if the VM were rebuilt, would a
normal provision or a single install command recreate it? If yes it is
regenerable. If it holds anything you typed, it is not.

On the legacy home this took the archive from 40.3 GB to 4.03 GB.

### Checking that it is actually working

`schedule status` reports the task state, last and next run, and — more
usefully — the newest archive and its age. It warns when the newest archive is
more than two days old, because a schedule that has never produced an archive
is not a backup. Check this occasionally rather than assuming.

Retention is `BACKUP_RETENTION_DAYS` (default 7). Archives whose label contains
`-safety-` are never pruned.
