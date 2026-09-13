# Phase 6 conformance evidence

Status: **run for the first time on 2026-09-13.** 16 pass, 1 fail, 5 skip.

Previous record said "not run; the host has no Multipass installation." That
was wrong on both counts — Multipass 1.16.3 was installed, and its daemon was
wedged rather than absent. See [`phase-1.md`](./phase-1.md) §5.

Run against instance `vibebox-vm`, Ubuntu 24.04.4, guest user `herwin`.

```
.\vm\conformance\run.ps1 -Full
```

## Results

| id | result | note |
|---|---|---|
| 10-systemd | ok | systemd is PID 1; not Docker or WSL |
| 11-filesystem | ok | native filesystem; no host mount |
| 12-kernel-policy | ok | cgroup v2, timesync, swap |
| 20-upstream-tools | ok | Node, Python venv, Go, Docker, Tailscale on normal guest paths |
| 21-systemd-service | ok | hand-written `Restart=on-failure` unit survives `kill -9` |
| 22-timer | ok | systemd timer scheduled and fired |
| 23-logs-network | ok | journal and `ss` reporting are truthful |
| 24-databases-web | ok | PostgreSQL and nginx from unmodified apt |
| 25-user-services | ok | `loginctl enable-linger` survives logout |
| 26-sysctl-cgroup | ok | sysctl persistence, cgroup v2 delegation |
| 27-tunnels | skip | needs a second endpoint; documented two-host check |
| 30-engine | ok | Docker Engine guest-local |
| 31-compose | ok | Compose uses native guest paths |
| 32-published-port | ok | published port reachable on the guest address |
| 40-boot-services | ok | base services are enabled native units |
| **41-tailnet** | **not ok** | **Hermes registry entry not live — Tailscale is not enrolled** |
| 50-rebuild-contract | ok | no host socket or drive mount at the recovery boundary |
| 60-mounts | ok | zero host directories mounted |
| 61-console | skip | needs a human to see a login prompt |
| 70-state | skip | Hyper-V generation needs elevation; Multipass state verified instead |
| 71-sleep-resume | skip | host sleep/resume is user-controlled |
| 72-autostart | skip | Hyper-V start/stop policy needs elevation |

Total runtime: **32 seconds**, including the PostgreSQL and nginx installs.

## The one failure

`41-tailnet` fails because `tailscaled` is running but logged out
(`BackendState: NeedsLogin`). This needs a Tailscale auth key, which is a
secret and therefore the user's to provide (work order §8.3). It is a real
failure, not an exception to accept: the registry declares `hermes` and no
such Service exists.

## Skips, and why none of them is a silent pass

The work order says a silently skipped check is a failed check. Each skip
states its reason in its own output:

- **61-console** is the A2 hard gate. It cannot be automated because the
  assertion is "a human sees a login prompt." Still open; see the Gate A
  report.
- **70-state / 72-autostart** need `Get-VM`, which needs elevation. `70-state`
  verifies what Multipass can see instead (instance exists, is running).
  `72-autostart` now checks a property Vibebox no longer sets — see
  [`deviations.md`](./deviations.md) D-1 — so it is arguably obsolete rather
  than skipped.
- **71-sleep-resume** cannot be triggered safely from a script.
- **27-tunnels** needs a second host.

## Defects found and fixed by running this suite

The suite had never been executed, and four of its own bugs surfaced
immediately. This is the argument for running things rather than reviewing
them:

1. **Every guest check exited 127.** `run.ps1` flattened the `guest/`
   directory when transferring, so each check's `../../lib.sh` resolved one
   level too high and the `ok`/`fail` helpers were undefined. All 13 guest
   checks were "failing" for a reason that had nothing to do with the guest.
2. **`60-mounts` reported a false failure.** Multipass reports "no mounts" as
   an empty JSON object, and an empty `PSCustomObject` is truthy in
   PowerShell, so the check counted one mount where there were none.
3. **`25-user-services` hardcoded the account name `dev`**, so it broke the
   moment `GUEST_USER` changed.
4. **`25-user-services` then exposed a real product bug** (below), which is
   the only reason it was found.

## The CRLF defect

After `25-user-services` was changed to read `GUEST_USER` from
`/opt/vibebox/vibebox.env`, it failed with:

```
Failed to look up user herwin
: No such process
```

The mangled second line is the tell. The host wrote that file with
`Set-Content`, which emits CRLF on Windows, so the parsed value was
`herwin\r` — a login name that does not exist. `guest/read-env.sh` strips the
carriage return defensively, which is why provisioning never noticed and the
file had been shipping broken the whole time.

Fixed at the source: `New-VibeboxGuestPayload` now writes both
`vibebox.env` and the cloud-init user-data with LF endings via
`File::WriteAllText`. Verified in the guest:

```
$ file /opt/vibebox/vibebox.env
/opt/vibebox/vibebox.env: ASCII text
$ sed -n 's/^GUEST_USER=//p' /opt/vibebox/vibebox.env | od -c
0000000   h   e   r   w   i   n  \n
```
