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
