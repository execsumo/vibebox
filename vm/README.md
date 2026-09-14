# Vibebox VM edition

The VM edition is a clean Ubuntu 24.04 guest managed from Windows through
`host/vibebox.ps1`. It uses Multipass with Hyper-V, cloud-init for the
non-secret first boot, and native Ubuntu systemd services.

## Prerequisites

Run on the Windows host in **PowerShell 7 (`pwsh`)**. Elevation is not needed:

- Hyper-V enabled (its `vmms` and `vmcompute` services running).
- Canonical Multipass installed with the Hyper-V driver.
- Git and the Windows OpenSSH client.
- Enough RAM and disk for the VM while the current container and WSL2 remain
  running.

The preflight command checks these prerequisites and creates the ignored
`vm/vibebox.env` from `vibebox.env.example`:

```powershell
.\vm\host\vibebox.ps1 doctor
```

The current environment has not passed this gate because Multipass is not
installed. No VM is claimed to exist.

Windows PowerShell 5.1 is not supported. Open PowerShell 7 (`pwsh`) and run
the commands below. **No elevation is required.** Multipass drives Hyper-V
through its own daemon, which already runs as a LocalSystem service.

## Lifecycle

```powershell
.\vm\host\vibebox.ps1 doctor
.\vm\host\vibebox.ps1 create
.\vm\host\vibebox.ps1 status
.\vm\host\vibebox.ps1 ssh
.\vm\host\vibebox.ps1 stop
.\vm\host\vibebox.ps1 start
```

If `doctor` reports that `multipassd` did not answer, the daemon is wedged
rather than missing. Restart it from an elevated shell — and force-kill the
process first if the stop hangs, which it does when the daemon is stuck:

```powershell
taskkill /F /T /IM multipassd.exe; Start-Service Multipass
```

## Configuration changes

Edit the ignored host configuration file:

```powershell
notepad .\vm\vibebox.env
```

```powershell
.\vm\host\vibebox.ps1 config show    # effective values and where each came from
```

`VM_CPUS`, `VM_MEMORY`, `VM_DISK`, `UBUNTU_RELEASE`, `VM_NAME` and
`GUEST_USER` are **create-time** settings: change the file, then
`vibebox rebuild -Confirm` and restore. `vibebox status` reports create-time
drift so the file and the live VM never disagree silently.

Guest policy (`GUEST_UFW`, `GUEST_SWAP_GB`, `GUEST_TIMEZONE`, `NODE_MAJOR`,
`TOOLS_*`) applies any time via `vibebox provision`, which is idempotent.

The VM disk is grow-only. `destroy` and `rebuild` require `-Confirm` and
refuse unmanaged instances.

The primary remote address is the enrolled Tailscale name. The local SSH
alias is regenerated from the current NAT address on `start`, `status`, and
`ssh`. `console` opens the Hyper-V rescue path when SSH is unavailable.

## Connecting

### From this Windows host

```powershell
ssh vibebox
```

The alias is written into `~/.ssh/config` in a marker-delimited block and is
refreshed by `vibebox start`, `status` and `ssh`. That matters because Hyper-V
hands the VM a new NAT address fairly often -- it changed three times during
one afternoon of rebuilds -- so a hardcoded IP goes stale but the alias does
not. If `ssh vibebox` ever fails, run `vibebox status` once to refresh it.

`vibebox ssh -- <command>` runs a single command and exits. Neither form needs
an elevated shell.

### Over Tailscale, from any other device

Once enrolled, the VM is an ordinary tailnet node named `vibebox`:

```bash
ssh herwin@vibebox                      # MagicDNS short name
ssh herwin@vibebox.<tailnet>.ts.net     # full name, if MagicDNS is off
```

Key-only; password authentication is disabled on the network path. Your
existing key migrated with the home directory, so devices already trusted by
the legacy box keep working.

**The host key is new.** The VM is a different machine from the container, so
the first connection from each device will warn about an unknown host, and any
device with the old `vibebox` entry in `known_hosts` will refuse to connect
with a host-key-mismatch error. Remove the stale entry once per device:

```bash
ssh-keygen -R vibebox
```

### Enrolling in the tailnet

```powershell
.\vm\host\vibebox.ps1 enroll tailscale                     # prompts for the key
.\vm\host\vibebox.ps1 enroll tailscale -KeyFrom .\.env     # reads TS_AUTHKEY from a file
```

The key goes straight into the guest's stdin -- never printed, never logged,
never stored host-side. Order matters: release the name `vibebox` from any
existing node in the admin console **first**, or the VM enrolls as `vibebox-1`.

If the tailnet requires tags, set `TAILSCALE_TAG` in `vibebox.env` (e.g.
`tag:vibebox`) and make sure the auth key was issued with that same tag and the
tag exists in the ACL `tagOwners`. A mismatch here makes `tailscale up` reject
the key outright, which is a confusing failure to diagnose. Empty means
advertise no tag.

Check with `vibebox status`: it reports the Tailscale backend state verbatim,
so a logged-out node reads `NeedsLogin` rather than being reported as running.

## Authorizing SSH access

**Nothing to configure for the host.** `vibebox` generates its own key at
`vm/state/ssh/id_ed25519` (gitignored), cloud-init installs the public half at
create time, and `vibebox migrate` re-asserts it -- a migrated home carries the
old box's `authorized_keys`, which would otherwise overwrite it and lock the
host out of the VM it just populated.

**To authorize another device**, drop its public key in as its own file:

```
vm/guest/authorized_keys.d/laptop.pub
vm/guest/authorized_keys.d/phone.pub
```

then:

```powershell
.\vm\host\vibebox.ps1 provision
```

Provisioning writes every `.pub` in that directory into the guest user's
`~/.ssh/authorized_keys`, inside a marker-delimited block it owns:

```
# >>> vibebox authorized_keys.d >>>
...declared keys...
# <<< vibebox authorized_keys.d <<<
```

**To revoke a key, delete its `.pub` and re-provision.** The guest tree is
mirrored from the repository rather than accumulated, so the key is removed
from `authorized_keys` too.

Anything outside those markers is left alone, so a key you added by hand in the
guest survives and re-provisioning cannot lock you out of your own box. The
flip side is that a hand-added key is not revoked by this mechanism -- remove
it from the guest directly.

### Why keys belong in git

`~/.ssh/authorized_keys` in the guest is real state but it is not reproducible:
`vibebox rebuild` without a restore starts from a fresh home, and every key
added by hand is gone with no error to say so. Anything that must survive a
rebuild has to be declared somewhere reproducible -- the same reason the tailnet
registry lives in `guest/tailnet.d/`.

Public keys are not secrets. You hand them to every server you connect to, and
committing them is the point. **Never put a private key there**; nothing under
`vm/guest/` should ever hold one, and `vibebox doctor` fails on key-shaped
values in configuration for the same reason.

Password authentication is disabled on the network path (`ssh_pwauth: false`
plus a hardening drop-in). The console keeps password auth as the rescue path,
which is what the rescue password in `vm/state/rescue/` is for.

## Memory

```ini
VM_MEMORY_MIN=1G        # Hyper-V reclaims down to this
VM_MEMORY_STARTUP=2G    # what the guest boots with
VM_MEMORY=4G            # ceiling it can grow to
```

These are Hyper-V **dynamic memory** bounds. `create` and `rebuild` apply them
automatically while the instance is stopped. To change them on an existing VM:

```powershell
.\vm\host\vibebox.ps1 memory show     # configured vs live
.\vm\host\vibebox.ps1 memory apply    # stops, applies, restarts
```

**This is the one thing that needs an elevated shell.** Multipass sets a fixed
`--memory` at launch and cannot configure dynamic memory, so Hyper-V has to be
asked directly and `Set-VM` requires administrator. `memory apply` requests
elevation for that single call rather than making you open an admin shell; if
`create` runs unelevated it warns that the bounds were not applied and names
the command, rather than failing the create.

Dynamic memory is a real trade-off, not free: the guest boots at the startup
size and grows under pressure, which suits a box that idles most of the time,
but ballooning can hurt workloads that allocate aggressively. Setting all three
values equal gives static allocation.

`MemTotal` in the guest reflects the **startup** value, not the maximum -- 2G
here shows as roughly 1.9 GiB. That is expected, not a misconfiguration.

## Updating

`update` upgrades the operating system packages and the pre-installed toolchain.
It runs from either side and both forms execute the same
`/opt/vibebox/update.sh`, so they cannot drift.

From inside the guest:

```bash
update           # OS packages and toolchain (default)
update tools     # toolchain only -- fast, safe to run mid-session
update os        # apt packages only
update --help
```

From the Windows host:

```powershell
.\vm\host\vibebox.ps1 update              # OS packages and toolchain
.\vm\host\vibebox.ps1 update -ToolsOnly   # toolchain only
.\vm\host\vibebox.ps1 update -OsOnly      # apt only
```

### What each mode touches

| Mode | Does |
|---|---|
| `os` | `apt-get update`, `apt-get upgrade`, `autoremove`, `clean`. Not `full-upgrade` -- that can *remove* packages to resolve dependencies, which is not a decision an update should make unattended. |
| `tools` | Re-runs `guest/provision/30-tools`, the same code path `provision` uses, so the two cannot disagree about how a tool is installed. Records resolved versions in `manifest.lock`. |
| `all` | Both, in that order. |

`update` does **not** touch the OS contract: it never changes the Ubuntu
release, the guest user, or anything set at create time. Those need
`vibebox rebuild`.

### Version policy

With `TOOLS_UPDATE_POLICY=latest` (the default) each tool is reinstalled at its
newest version. npm globals are reinstalled at `@latest` rather than
`npm update -g`, because for globals npm stays inside the semver range the
package was installed under and never crosses a major -- and these CLIs move
majors.

With `TOOLS_UPDATE_POLICY=locked` the toolchain is pinned to `manifest.lock`
and the tools half becomes a no-op.

### Output

It reports what actually changed rather than scrolling raw apt output:

```
== changes ==
packages upgraded:
  libc6: 2.39-0ubuntu8.8 -> 2.39-0ubuntu8.9
  perl:  5.38.2-3.2ubuntu0.3 -> 5.38.2-3.2ubuntu0.4
tools:
  was: hermes = "Hermes Agent v0.21.2 · upstream bdb14f5f"
  now: hermes = "Hermes Agent v0.21.2 · upstream a8843ab9"
services needing restart: vibebox-hermes-gateway@herwin.service
run: vibebox restart
reboot required: linux-image-generic
```

### It never restarts anything

`needrestart` runs in **list-only** mode during the upgrade. Restarting `dbus`
or `sshd` mid-command kills the channel the command arrived on, so the upgrade
succeeds while the caller sees a failure -- which is exactly what happened the
first time this ran. Services needing a restart, and any pending reboot, are
reported for you to action with `vibebox restart`.

A kernel or libc upgrade sets `reboot required`. Nothing reboots on its own.

### Why one command, when legacy had two

The container had `update` for tools and `update-image` for the OS, and skipped
APT deliberately: a system upgrade was slow *and its results were discarded by
the next `docker compose down/up`*. **A VM persists, so that split buys
nothing.**

Guest commands live in `vm/guest/bin/` and provisioning installs them to
`/usr/local/bin`. The container-era shims for `npm`, `pip3`, `systemctl` and
`tailscale` are deliberately **not** carried over -- they existed to print
friendly errors on a box with no init, and shadowing a real CLI is what the
design forbids.


## Tailnet URLs

The VM is one Tailscale node. Extra HTTPS names are **Tailscale Services**
advertised by that node, declared in git under `vm/guest/tailnet.d/` — one
`.conf` per name:

```ini
SERVICE=grafana                   # -> grafana.<tailnet>.ts.net
TARGET=http://127.0.0.1:3000      # what the node proxies to
PORT=443
MODE=serve                        # serve = tailnet only; funnel = public
```

Manage them with `vibebox tailnet`, never by calling `tailscale serve` directly
— a name added by hand is not in the registry and will not survive a rebuild:

```powershell
.\vm\host\vibebox.ps1 tailnet add grafana --target http://127.0.0.1:3000
.\vm\host\vibebox.ps1 tailnet add docs --target http://127.0.0.1:8080 --mode funnel
.\vm\host\vibebox.ps1 tailnet list      # registry vs live, side by side
.\vm\host\vibebox.ps1 tailnet remove grafana
.\vm\host\vibebox.ps1 tailnet apply     # reconcile registry -> live
```

`apply` is a reconcile, not an append: it adds what is missing, withdraws what
is orphaned, and leaves matches alone, so running it twice changes nothing the
second time. **After `vibebox rebuild`, a single `tailnet apply` restores every
URL** — that is the entire point of keeping the registry in git.

`vibebox status` reports registry-versus-live drift, so a name that silently
stopped being served shows up as a failed check rather than a dead link.

Two constraints worth knowing before you add one:

- The target must actually be listening in the guest. A Service pointing at a
  dead port still resolves and still gets a certificate; it just fails to
  answer. The registry ships empty for this reason.
- Tailscale Services must be permitted for your tailnet, and the node needs
  policy approval to advertise one. The guest cannot self-authorize; that is an
  admin-console step.


Use the tailnet name shown for the VM in Tailscale. This path does not depend
on the Hyper-V NAT address or an elevated Windows session.

## Guest contract

The guest has its own systemd, ext4 filesystem, Docker Engine, Tailscale
node, swap, persistent journald, security-only unattended upgrades, and
`America/Los_Angeles` timezone by default. No Windows drive, Docker socket,
clipboard, device, or SSH agent is mounted into it. `status` reports
`gpu: none`; GPU workloads stay on the host Docker Desktop/WSL2 path.

Tailnet service names are declarative files under `guest/tailnet.d/` and are
reconciled through `vibebox tailnet`, not a replacement for the upstream
`tailscale` command.

## Operations and gates

Read [`docs/operations.md`](docs/operations.md) for lifecycle, backup,
restore, tailnet, and diagnostics. Read [`docs/security.md`](docs/security.md)
before enrolling credentials. The phase evidence is under
[`docs/evidence/`](docs/evidence/).

Phases 0–6 use synthetic data only and stop at Gate A. Do not migrate,
authenticate, or cut over real user data until the user has reviewed and
explicitly approved the Gate A report.

## Project state, for picking this up later

Last substantive session: 2026-09-13.

**Where it stands.** The VM is real and holds live data. `vibebox` runs Ubuntu
24.04 on Hyper-V via Multipass, guest user `herwin` (uid 1000, zsh), 4 vCPU /
4 GB / 64 GB. The legacy home was migrated from a backup the container itself
produced: 154,141 entries, ~10 GB, every file owned by `herwin`, 170 absolute
symlinks retargeted from `/home/dev`. Conformance runs 16 pass / 1 fail /
5 skip; the failure is Tailscale enrollment.

**Decisions that are settled**, with reasoning in
`docs/evidence/deviations.md`:

- No `config apply` reconciler. CPU/RAM/disk are create-time; change them by
  editing `vibebox.env` and running `vibebox rebuild`. This is why nothing
  needs an elevated shell.
- Secrets live in Infisical only. `vibebox.env` is non-secret configuration and
  `doctor` fails if a key-shaped value appears in it. The legacy `.env` API
  keys were deliberately not migrated.
- Regenerable content is defined once in `guest/regenerable.conf` and read by
  both backup and migrate. It took the home from 40.3 GB to 4.03 GB.
- The rescue console (A2) is unproven by explicit decision; the argument rests
  on backups and git, which makes the backup schedule load-bearing.
- Hermes WebUI is not installed, and the tailnet registry ships empty so
  nothing advertises a dead port.

**Tailnet.** Enrolled as `vibebox.goose-marlin.ts.net` (100.113.103.44),
untagged. Because it is untagged the node key **expires 2027-03-12**, after
which the VM drops off the tailnet until it is re-authenticated. To make that
permanent instead, add `tag:vibebox` to the ACL `tagOwners`, set
`TAILSCALE_TAG=tag:vibebox` in `vibebox.env`, and re-enroll with a key issued
for that tag -- tagged nodes do not expire.

**Known open items.**

- No host reboot, sleep/resume, or multi-day soak has been run. Post-resume
  clock skew and Tailscale reconnect are the untested failure modes.
- Backup and restore have not been exercised end to end against this data.
  `restore` gained cross-account rename support that the migration used, but
  the full backup → rebuild → restore loop is unproven.
- `multipassd` wedged twice in one session, holding its socket open while
  answering nothing. `doctor` now detects it and prints the recovery command,
  but the underlying flakiness is unexplained and is the main argument against
  Multipass as the adapter.
- First use of any project needs `npm install` / `bun install`; virtualenvs
  need rebuilding. That is the deliberate cost of excluding regenerable trees.

**If something looks wrong, run `vibebox status` first.** It distinguishes VM,
SSH, Tailscale, Docker, disk, clock, mounts and individual services, and
reports each honestly rather than collapsing them into one green tick. A
non-empty `mounts` array is a security failure by design and exits 5.

**Reading order for a new session**: this file, then
`docs/evidence/deviations.md` for why the shipped design differs from
`../docs/vm-work-orders.md`, then `docs/operations.md` for day-to-day
procedures. The work-order documents describe the original plan, not all of
what was built.
