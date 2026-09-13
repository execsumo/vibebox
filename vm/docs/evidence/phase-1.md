# Phase 1 evidence: architecture proof

Status: **verified on the real host, 2026-09-13.**

Supersedes the earlier "blocked on the host prerequisite gate" record. That
record was wrong about its own blockers; §4 explains why, because the mistake
is more instructive than the result.

Host: Microsoft Windows 11 Pro, build 22631. Multipass 1.16.3+win (client and
daemon). PowerShell 7. Instance `vibebox-vm`, Ubuntu 24.04.4 LTS,
image hash `d0fe84bb5f80`.

## 1. Guest authenticity

```
$ ps -p 1 -o comm=
systemd
$ systemd-detect-virt
microsoft
$ test ! -e /.dockerenv && echo "absent (ok)"
absent (ok)
$ mount | grep -iE "9p|drvfs|//"
none (ok)
$ which systemctl npm pip3 tailscale docker
/usr/bin/systemctl
/usr/bin/npm
/usr/bin/pip3
/usr/bin/tailscale
/usr/bin/docker
```

systemd is PID 1, the hypervisor is reported as `microsoft` rather than a
container runtime, and every tool resolves to its upstream path. No 9p, drvfs
or SMB mount exists, so no Windows filesystem is reachable from the guest.

`multipass info vibebox-vm` reports `Mounts: --`. The mount-drift check in
`vibebox status` and conformance check `60-mounts` both assert this
independently; `60-mounts` had to be fixed first, because Multipass reports
"no mounts" as an empty object and an empty `PSCustomObject` is truthy in
PowerShell, so the check was reporting a false failure.

## 2. Guest policy

```
$ id herwin
uid=1000(herwin) gid=1000(herwin) groups=1000(herwin),27(sudo),988(docker)
$ getent passwd herwin | cut -d: -f7
/bin/zsh
$ timedatectl show -p Timezone --value
America/Los_Angeles
$ swapon --show --noheadings
/swapfile file   2G   0B   -2
```

**Deviation from §2.2**: the working user's UID *is* 1000. The work order
specified "whatever cloud-init assigns (not 1000)" so that name-based
ownership mapping would be exercised rather than assumed. Cloud-init assigned
1000 anyway. The name-based mapping is implemented and is now also exercised
deliberately by the `-SourceUser` rename path, but it is not proven by an
accidental UID difference. Recorded rather than papered over.

## 3. A11 — GPU

```
$ (Get-CimInstance Win32_OperatingSystem).Caption
Microsoft Windows 11 Pro
$ multipass launch --help | Select-String gpu
(no matches)
$ Get-VMHostAssignableDevice
Query unavailable: You do not have the required permission to complete this
task.
```

Multipass exposes no GPU option at all, which settles the question for this
adapter regardless of what the host could theoretically do. The DDA query
needs elevation and returned nothing usable; **this row is therefore partially
evidenced, not fully.** It is consistent with plan D14 and nothing contradicts
it, so no stop condition (§8.11) is triggered — but the honest statement is
"Multipass cannot pass a GPU through," not "this host cannot."

## 4. A2 — rescue console: **still open**

Not proven. `vmconnect.exe` exists at `C:\Windows\System32\vmconnect.exe`, but
the check is whether a human reaches a **login prompt** with `sshd` stopped,
and that cannot be asserted by a program that only sees exit codes.

This remains the work order's hard gate (§8.4). See
[`gate-a-report.md`](./gate-a-report.md) §7 for the exact steps and why it is
worth doing before any real data moves.

## 5. Why the previous record was wrong

The earlier evidence file reported three blockers. None of them blocked
anything:

| Reported | Actual |
|---|---|
| "administrator: current shell is not elevated" | Irrelevant. `multipassd` runs as a LocalSystem service; the client needs no elevation. Elevation was required only by `config apply`, which has since been removed (deviations D-1). |
| "hyperv: authorization unavailable to this shell" | Hyper-V was enabled and running the whole time. `vmms` and `vmcompute` were both `Running`, readable without elevation. The preflight asked via `Get-VMHost`, which needs admin. |
| "resource-headroom-memory: 5.94 GB free; 8 GB required" | The host has 31.77 GB. The rule demanded the VM's *maximum* dynamic memory plus a 4 GB reserve be free simultaneously, which is not how dynamic memory works. |

The actual blocker was never diagnosed: **`multipassd` was wedged.** It held
its socket open on `127.0.0.1:50051` and answered nothing — `multipass
--help` returned instantly while `multipass -vvvv version` timed out with no
output, and two orphaned client processes had been stuck since 2026-09-12. A
wedged daemon is indistinguishable from a healthy one in `Get-Service`, which
is why it went unnoticed.

Recovery required force-killing the process; `Restart-Service` alone hung
waiting for a stop that never completed:

```powershell
taskkill /F /T /IM multipassd.exe
Start-Service Multipass
```

`vibebox doctor` now has a `multipass-daemon` check that calls the daemon with
a 20-second timeout and prints that recovery command by name. The lesson is
the check, not the incident: the preflight tested three things that could not
stop the work and never tested the one thing that did.
