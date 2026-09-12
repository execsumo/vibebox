# Vibebox VM edition — work orders

Status: Ready to delegate
Last updated: 2026-09-11
Companion to: [`vm-transition-plan.md`](./vm-transition-plan.md)
Continues in: [`vm-work-orders-2.md`](./vm-work-orders-2.md) (Phases 7–9)

---

## 0. How to use this document

`vm-transition-plan.md` is the **decision record**: it says what must be true
and why. This document is the **work order**: it says what to build, where to
put it, what to run, and how to prove it worked.

Where the two disagree, the plan wins on *architecture and security*; this
document wins on *parameters and sequencing*. Report the conflict either way.

Read the plan first. Then work phases in order. Do not skip ahead, do not
batch phases, and do not cross a 🛑 gate.

---

## 1. Execution model

### Where the agent runs

**On the Windows host**, not inside Vibebox. The delegated agent needs:

| Requirement | Check |
|---|---|
| PowerShell 7+ (`pwsh`) | `$PSVersionTable.PSVersion.Major -ge 7` |
| Elevated shell available | Hyper-V cmdlets require admin |
| Hyper-V enabled | `(Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V).State` |
| Multipass installed | `multipass version` |
| Git | `git --version` |
| OpenSSH client | `ssh -V` |
| The repo checked out | this file is at `docs/vm-work-orders.md` |

An agent running *inside* the current Vibebox container cannot do this work.
That environment has no systemd, no Hyper-V, no Multipass, and no Windows
interop; it can author files but verify nothing. If you are reading this from
inside the container, stop and report that the execution environment is wrong.

### What the agent owns vs what the user owns

| Agent owns | User owns |
|---|---|
| All code under `vm/` | Whether data migrates (Gate A) |
| The `legacy/` split (Phase 0) | When cutover happens (Gate B) |
| Creating, destroying, rebuilding the **VM** | Any secret or credential |
| Running conformance and recording evidence | Accepting a conformance exception |
| Proposing exceptions, defaults, and schedules | Rebooting the Windows host |
| Reporting honestly when something fails | Retiring the legacy edition |

### Standing constraints

1. **Never modify, stop, restart, or rebuild the legacy container.** It is the
   user's running machine. Read it; do not touch it. Phase 0 moves its *files*
   and nothing else.
2. **Never `multipass delete` / `Remove-VM` anything you did not create.**
   Resolve the exact target and print it before any destructive call.
3. **Never write a secret into cloud-init user-data, a repo file, or a log.**
4. **Never reboot the Windows host.** Ask; the user may be mid-work.
5. **Every phase writes evidence** (§7). A phase without evidence is not done.

---

## 2. Resolved parameters

These were open questions in the plan. They are now decided. Use them. If one
turns out to be wrong, say so and propose a change — do not silently deviate.

**Every value in §2.1–§2.6 is a default, not a constant.** They are the shipped
values of `vm/vibebox.env` (§2.0), which the user can edit at any time. Nothing
in the codebase may hardcode one of these numbers; read them from config.

### 2.0 The configuration file

**`vm/vibebox.env`** — a `KEY=VALUE` file, deliberately the same shape as the
legacy `.env` so it is familiar. `vm/vibebox.env.example` is committed;
`vm/vibebox.env` is gitignored and created by `vibebox doctor` on first run.

Parsed by both PowerShell (host) and bash (guest provisioning) — so: no shell
expansion, no quotes required, no multi-line values, `#` comments only at the
start of a line.

Precedence: **CLI flag > `vibebox.env` > built-in default.**

```ini
# ---- Instance (see "when it applies" below) ----
VM_NAME=vibebox-vm
UBUNTU_RELEASE=24.04
VM_CPUS=4
# Hyper-V dynamic memory: minimum / startup / maximum.
VM_MEMORY_MIN=0.5G
VM_MEMORY_STARTUP=2G
VM_MEMORY=4G
VM_DISK=32G                   # grow-only; cannot be shrunk after create

# ---- Host behavior ----
VM_AUTOSTART=true
VM_STOP_ACTION=shutdown       # shutdown | save
VM_NESTED_VIRT=false

# ---- Guest policy ----
GUEST_USER=dev
GUEST_SHELL=/bin/zsh
GUEST_UFW=false
GUEST_SWAP_GB=2
GUEST_TIMEZONE=America/Los_Angeles   # PST/PDT

# ---- Toolchain ----
NODE_MAJOR=22
TOOLS_OPTIONAL=agy,herdr,rtk,droid,hermes,codeburn,pi,codegraph,gws,docling
TOOLS_UPDATE_POLICY=latest    # latest | locked  (locked = honor manifest.lock)

# ---- Operations ----
BACKUP_DEST=D:/vibebox-backups
BACKUP_RETENTION_DAYS=7
READINESS_TIMEOUT_SEC=90
```

**No secrets in this file.** This is the one place the VM edition deliberately
breaks with legacy habit: the old `.env` held `TS_AUTHKEY`, `HERMES_WEBUI_PASSWORD`,
and API keys, and forwarded all of it into every shell. Here, secrets go through
`vibebox enroll` only. `vibebox doctor` **fails** if it finds a key-shaped value
in `vibebox.env`, naming the variable.

#### When a change takes effect

This is the part that must not be papered over — a config file that silently
ignores half its own settings is worse than no config file.

| Setting | Applies | How |
|---|---|---|
| `VM_CPUS`, `VM_MEMORY_MIN`, `VM_MEMORY_STARTUP`, `VM_MEMORY` | VM **stopped** | `vibebox config apply` — refuses on a running VM unless `-Restart` |
| `VM_DISK` | VM stopped, **grow only** | `vibebox config apply` resizes the VHDX, then `growpart` + `resize2fs` in-guest on next boot. Shrink is refused with a clear message. |
| `VM_AUTOSTART`, `VM_STOP_ACTION`, `VM_NESTED_VIRT` | VM stopped | `vibebox config apply` (Hyper-V properties) |
| `VM_NAME`, `UBUNTU_RELEASE`, `GUEST_USER` | **Create-time only** | Changing requires `vibebox rebuild`; `config apply` says so rather than half-applying |
| `GUEST_UFW`, `GUEST_SWAP_GB`, `GUEST_TIMEZONE`, `NODE_MAJOR`, `TOOLS_*` | Anytime | `vibebox provision` (idempotent) |
| `BACKUP_*`, `READINESS_TIMEOUT_SEC` | Immediately | Read at point of use |

#### Config subcommands

```
vibebox config show              # effective values + where each came from
vibebox config diff              # declared vs actual VM state
vibebox config apply [-Restart]  # reconcile what can be reconciled
```

`vibebox status` reports config drift as a non-fatal warning: if the configured
dynamic-memory bounds differ from the Hyper-V VM, say so and name the command
that fixes it.
Silent drift is how a user ends up convinced they gave the VM more RAM than
they did.

**Resource-bump walkthrough** (the case the user actually cares about):

```powershell
# edit vm/vibebox.env: VM_CPUS=8, VM_MEMORY_STARTUP=4G, VM_MEMORY=32G, VM_DISK=256G
vibebox config diff                # shows resource deltas, flags disk as grow-only
vibebox stop
vibebox config apply
vibebox start                      # growpart/resize2fs run on boot
vibebox status                     # no drift
```

This flow is a Phase 2 deliverable and a Phase 2 DoD item.

### 2.1 Instance

| Parameter | Value | Source / rationale |
|---|---|---|
| Instance name (Phases 1–7) | `vibebox-vm` | Temp name; avoids colliding with the live legacy node |
| Instance name (post-cutover) | `vibebox` | Matches `SANDBOX_NAME` default |
| Ubuntu release | 24.04 LTS | Plan D4 |
| Image source | Multipass `release:24.04` | Record the resolved image hash in evidence |
| vCPUs | 4 | Matches legacy `SANDBOX_CPUS=4` |
| Memory | 0.5 GB minimum, 2 GB startup, 4 GB maximum | Hyper-V Dynamic Memory bounds |
| Disk | 32 GB, dynamically allocated | Grow-only (risk A5); real consumption is what's allocated |
| VM disk location | Multipass default on `C:` | User decision; keeps create/destroy on the supported path |
| Generation | Hyper-V Gen 2 | Plan security model |
| Autostart on host boot | Enabled | Plan D12 |
| Host stop action | ACPI shutdown, not Save | Plan D12 |
| Nested virtualization | **Off** | Document it; enabling is a separate decision |

### 2.2 Accounts

| Parameter | Value | Rationale |
|---|---|---|
| Working user | `dev` | Matches legacy `SANDBOX_USERNAME` |
| Working user UID | Whatever cloud-init assigns (**not** 1000) | Plan D9 |
| Working user shell | `/bin/zsh` | Matches legacy |
| Working user sudo | `NOPASSWD` | Matches legacy posture; this is a convenience box |
| Rescue user | `ubuntu` (Multipass-owned) | Plan D9 |
| Rescue password | Generated post-boot, never in user-data | See work order 4.4 |
| SSH auth | Key only; `PasswordAuthentication no` on the network path | Console keeps password auth |

### 2.3 Guest policy

| Parameter | Value | Rationale |
|---|---|---|
| `ufw` | **Inactive by default** | Matches stock Ubuntu cloud images and DO/Hetzner droplets. The VM sits behind Hyper-V NAT; the tailnet is governed by ACLs. An active firewall plus no console is the classic unrecoverable box. Opt-in, documented. |
| Guest firewall opt-in | Documented in `vm/docs/`, not enabled | — |
| Swap | Enabled, 2 GB file | A VPS has swap; absence changes OOM behavior |
| Persistent journald | Enabled | `Storage=persistent` |
| Unattended upgrades | Enabled, security only, no auto-reboot | — |
| Timezone | `America/Los_Angeles` (PST/PDT) | User decision. The IANA zone, not a literal `PST`, so DST transitions are handled. **Changes from legacy**, which runs `Etc/UTC`. |
| Timesync | `systemd-timesyncd` + `hv_utils` | Plan D13 |
| Tailnet names | One node + N Tailscale Services (plan D15) | Not one `tailscaled` per name |
| Tailnet registry | `vm/guest/tailnet.d/<name>.conf`, git-tracked | A name not in the registry does not survive a rebuild |
| Primary node mode | Kernel TUN (`tailscale0`) | Matches legacy `TS_USERSPACE=false` for the SSH node |

### 2.4 Toolchain

Derived from the existing `Dockerfile` verification block — this is already the
project's own required/optional split, so adopt it verbatim.

| Tier | Tools | Failure behavior |
|---|---|---|
| **Required** | `claude` `codex` `bun` `node` `go` `gh` `docker` | Provisioning **fails** if any is missing or fails `--version` |
| **Optional** | `agy` `herdr` `rtk` `droid` `hermes` `codeburn` `pi` `codegraph` `gws` `docling` | Warn, continue, record in evidence |

Verify with `--version` (or `go version`), never bare `command -v` — the legacy
Dockerfile comments explain why: npm optional-dependency failures leave a
working wrapper around a missing binary.

Version pinning: `NODE_MAJOR=22`; everything else `latest` by default, with the
**resolved** version recorded in `vm/guest/manifest.lock` on every provision run.

### 2.5 GPU policy

Decided: **the VM is CPU-only.** Plan D14 explains why this is structural
rather than a deferral — a Hyper-V Linux guest on a Windows client host cannot
receive a GPU by any supported mechanism.

| Parameter | Value |
|---|---|
| GPU in the VM | None. Do not attempt passthrough, DDA, or GPU-PV. |
| GPU workloads | Stay on Docker Desktop / WSL2 on the host, unchanged |
| Docling PyTorch wheels in the guest | CPU (already the legacy default) |
| `vibebox status` | Reports `gpu: none` explicitly — never leave the user to discover it |
| `vibebox doctor` | Warns if `vibebox.env` contains a GPU-ish knob, pointing at D14 |

**Do not** add a `VM_GPU` setting to `vibebox.env`. A config knob that cannot
work is worse than its absence.

Two obligations follow:

1. **Phase 1** verifies the constraint on the real host (risk A11) — Windows
   edition, DDA availability, Multipass GPU support — so this rests on evidence
   from the actual machine, not on assertion.
2. **Phase 9** must extract a standalone `gpu/` project *before* deleting
   `legacy/`. The GPU container definition currently lives only in
   `legacy/docker-compose.gpu.yml` and the CUDA `BASE_IMAGE` path, and deleting
   it would silently remove the user's GPU capability.

### 2.6 Operations

| Parameter | Value |
|---|---|
| Backup retention | 7 days + labeled safety backups (matches legacy). Assumes work is also pushed to git remotes; the archive is depth, not the only copy. |
| Backup destination | `D:/vibebox-backups` — a **different physical drive** from the VM disk on `C:`, so a drive failure does not take both |
| Soak duration (Phase 6) | 7 consecutive days, ≥3 host reboots, ≥5 sleep/resume cycles, ≥1 full rebuild |
| Post-resume clock tolerance | ≤2 s offset, measured 60 s after resume. Compare in UTC; a local-zone comparison will read a DST transition as an 8-hour failure. |
| Service readiness timeout | 90 s from boot to all-green `vibebox status` |
| Rollback window (Phase 8→9) | 30 days, confirmed at Gate B |
| Compatibility repo suite | Agent proposes candidates at Gate A; user picks |

---

## 3. Interface contracts

Build to these. They are the parts the plan left as properties rather than
deliverables, and inventing a different shape later is expensive.

### 3.1 The `vibebox` command

Single entry point: `vm/host/vibebox.ps1`. Subcommands:

```
vibebox doctor                        # host preflight; no instance required
vibebox config   <show|diff|apply> [-Restart]
vibebox create   [-Name] [-Cpus] [-Memory] [-Disk] [-Release]   # flags override vibebox.env
vibebox start    [-Name]
vibebox stop     [-Name]
vibebox restart  [-Name]
vibebox destroy  [-Name] -Confirm     # refuses without explicit confirm
vibebox status   [-Name] [-Json]
vibebox ssh      [-Name] [-- <cmd>]   # refreshes the SSH alias first
vibebox console  [-Name]              # launches vmconnect; the rescue path
vibebox provision [-Name]             # idempotent; safe to re-run forever
vibebox update   [-Name]              # tools per manifest policy; never the OS contract
vibebox rebuild  [-Name] -Confirm     # destroy + create + provision (+ optional restore)
vibebox backup   [-Name] [-Label <s>]
vibebox restore  [-Name] -Archive <p> [-DryRun]
vibebox conformance [-Name] [-Json]
vibebox enroll   <tailscale|github|hermes>
vibebox tailnet  <list|add|remove|apply>   # declarative tailnet names (D15)
```

Exit codes — stable, because automation and the conformance harness depend on
them:

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Usage or argument error |
| 2 | Host preflight failure |
| 3 | Instance not found or wrong state |
| 4 | Operation failed |
| 5 | Validation / conformance failure |

Rules:
- Every destructive subcommand prints the fully-resolved target and requires
  `-Confirm`.
- Every subcommand is idempotent or explicitly refuses to repeat.
- `-Json` output goes to stdout alone; human text goes to stderr.
- No subcommand named after a standard Unix command, in the guest or the host.

### 3.2 `vibebox status -Json` schema

```json
{
  "name": "vibebox-vm",
  "state": "running|stopped|unknown",
  "checkedAt": "2026-09-11T10:04:00Z",
  "host":  { "multipassVersion": "", "hyperV": true, "consoleAvailable": true },
  "vm":    { "cpus": 4, "memoryGb": 8, "diskGb": 128, "diskUsedPct": 37,
             "uptimeSec": 90210, "mounts": [] },
  "net":   { "localIp": "172.x.x.x", "sshAlias": "vibebox-vm", "sshReachable": true,
             "tailscale": { "state": "Running", "name": "vibebox-vm", "ip": "100.x.x.x" } },
  "clock": { "offsetSec": 0.3, "synced": true },
  "gpu":   "none",
  "tailnet": { "node": "vibebox", "services": [
      { "name": "hermes", "target": "http://127.0.0.1:8080", "live": true, "inRegistry": true } ] },
  "services": [ { "unit": "docker.service", "active": true, "sub": "running" } ],
  "tools":  { "required": { "ok": 7, "missing": [] },
              "optional": { "ok": 9, "missing": ["docling"] } },
  "checks": [ { "id": "no-mounts", "ok": true, "detail": "0 mounts configured" } ],
  "ok": true
}
```

`mounts` must be `[]`. A non-empty `mounts` array sets `ok: false` and exits 5 —
that is the drift detector the plan's security model depends on.

### 3.3 The tailnet name registry

Plan D15: one node, N Tailscale Services, declared in git.

```ini
# vm/guest/tailnet.d/hermes.conf
SERVICE=hermes                      # -> hermes.<tailnet>.ts.net
TARGET=http://127.0.0.1:8080
PORT=443
MODE=serve                          # serve | funnel
```

```
vibebox tailnet list                       # registry vs live, side by side
vibebox tailnet add <name> --target <url>  # writes the .conf, then applies
vibebox tailnet remove <name>              # removes the .conf, then applies
vibebox tailnet apply                      # reconcile
```

`apply` is a **reconcile, not an append**: diff `tailscale serve status --json`
against the registry, add what is missing, withdraw what is orphaned, leave
matches alone. Re-running it changes nothing. After `vibebox rebuild`, a single
`apply` must restore every URL — that is the whole point of the registry, and
it is a Phase 5 rebuild-test assertion.

`vibebox tailnet`, never a `tailscale` wrapper. Plan D6 forbids shadowing the
real CLI, and the fallback design (A12) is the exact scenario where a wrapper
would be tempting.

### 3.4 The conformance harness

```
vm/conformance/
├── run.ps1               # host-side driver: runs host checks, then guest checks over SSH
├── lib.sh                # ok / fail / skip / require helpers
├── guest/                # run in the VM over SSH
│   ├── 10-authenticity/  NN-<name>.sh
│   ├── 20-vps/           NN-<name>.sh   # unmodified upstream install instructions
│   ├── 30-docker/
│   ├── 40-services/
│   └── 50-recovery/
└── host/                 # run on Windows (PowerShell)
    ├── 60-isolation/
    └── 70-lifecycle/     # console, autostart, sleep/resume, reboot
```

Each check is one file, exits 0 pass / 1 fail / 77 skip, and prints one
`ok <id> - <desc>` or `not ok <id> - <desc>` line plus freeform detail on
stderr. `run.ps1 -Json` emits a summary object; overall exit 0 only if zero
failures. Skips must state why and are surfaced in the Gate A report — a
silently skipped check is a failed check.

Checks derive directly from the plan's validation matrix. Do not invent a
different taxonomy.

---

## 4. Work orders

Each phase: **Deliverables → Validation → DoD**. A phase is done when every DoD
box is checkable by someone re-running the listed commands.

---

### Phase 0 — Repository split

**Deliverables**
- `legacy/` containing, moved via `git mv` in a single commit: `Dockerfile`,
  `docker-compose.yml`, `docker-compose.gpu.yml`, `.dockerignore`, `scripts/`,
  `hermes-serve/`, `setup-sandbox.*`, `update-image.*`, `backup.*`, `restore.*`,
  `authorized_keys.example`, `.env.example`, `README.md`, `NO_SYSTEMD.md`,
  `BUGS.md`, `PLAN-hermes-webui.md`, `handoff.md`.
- Root forwarding shims: `setup-sandbox.ps1`, `update-image.ps1`, `backup.ps1`,
  `restore.ps1` — each prints a one-line relocation notice and delegates to
  `legacy/`, passing all arguments through.
- Root `README.md` rewritten as a chooser: legacy is current, VM is under
  construction, where each lives, which docs to read.
- `vm/` skeleton per plan D0.1, with `.gitkeep`s and a stub `vm/README.md`.
- `.github/workflows/no-legacy-refs.yml` (or a pre-commit hook if the repo has
  no CI): fails if any file under `vm/` matches `legacy/`.
- `legacy/.frozen` — a short file stating the freeze policy: security fixes
  only, no features, no refactors.

**Validation**
```powershell
git log --follow -- legacy/Dockerfile        # history preserved
git grep -n "legacy/" -- vm/                 # must return nothing
.\setup-sandbox.ps1 -WhatIf                  # shim resolves (if supported)
```
Confirm with the user's running box untouched: `docker ps` still shows the
legacy container, same ID as before the commit.

**DoD**
- [ ] One commit, `git mv` only, no content edits to moved files.
- [ ] `git log --follow` traces history through the move for at least
      `Dockerfile`, `scripts/entrypoint`, `README.md`.
- [ ] All four shims execute and reach the legacy script.
- [ ] The no-legacy-refs check runs and passes.
- [ ] `vm/` contains zero lines copied from `legacy/`.
- [ ] The legacy container was never stopped (evidence: `docker ps` before/after
      showing identical container ID and uptime continuity).

---

### Phase 1 — Architecture proof and adapter risk register

**Deliverables**
- `vm/docs/evidence/phase-1.md` — a verified answer for **every** row A1–A10 of
  the plan's adapter risk register, each with the command run and its output.
- `vm/host/lib/preflight.ps1` — the checks from §1 plus host resource headroom.
- A disposable instance named `vibebox-proof`, destroyed at phase end.
- A recorded answer for risk **A11** (GPU, §2.5): the host's Windows edition,
  whether DDA is available, and whether Multipass exposes any GPU option.
- A recorded answer for risk **A12** (tailnet, plan D15): whether Tailscale
  Services is available on this tailnet, and the policy-file/grant syntax
  required to advertise one. Verify against the admin console, not just the
  CLI — `tailscale serve --service` exists in 1.102.3, which proves the client
  supports it, not that this tailnet permits it.

**Validation** — the plan's Phase 1 exit gate, plus:
```bash
ps -p 1 -o comm=                  # systemd
systemd-detect-virt               # microsoft (not docker/wsl)
test ! -e /.dockerenv && echo ok
mount | grep -iE "9p|drvfs|//"    # must be empty
```
```powershell
# A2 — the hard one. Stop sshd, then prove the console still works.
multipass exec vibebox-proof -- sudo systemctl stop ssh
vmconnect.exe localhost vibebox-proof      # must reach a login prompt
```

**DoD**
- [ ] All ten risk-register rows answered with evidence, not inference.
- [ ] **A2 passes**: console reaches a login prompt with sshd stopped. If it
      does not, 🛑 stop and ask — this triggers the direct-Hyper-V fallback,
      which is a scope change the user must approve.
- [ ] Canary test: a file at a known Windows path is unreadable from the guest.
- [ ] The proof instance is destroyed and no Hyper-V artifact remains.
- [ ] Every "no" answer names its fallback and its cost.
- [ ] A12 recorded: Services available yes/no. If no, the fallback (one
      userspace `tailscaled` per name) is confirmed workable **before** Phase 3
      commits to a design.
- [ ] A11 recorded with evidence:
      `(Get-ComputerInfo).WindowsProductName`, `Get-VMHostAssignableDevice`,
      and `multipass launch --help | Select-String -Pattern gpu`. If any of
      these contradicts D14, 🛑 stop and report — do not opportunistically
      enable a GPU mid-phase.

---

### Phase 2 — Host lifecycle foundation

**Deliverables**
- `vm/host/vibebox.ps1` implementing `doctor config create start stop restart
  destroy status ssh console` per §3.1.
- `vm/host/lib/` — `preflight.ps1`, `config.ps1`, `lifecycle.ps1`,
  `sshconfig.ps1`, `status.ps1`.
- `vm/vibebox.env.example` per §2.0, plus a bash reader used by guest
  provisioning, so host and guest parse one file identically.
- `vibebox config show|diff|apply` and config-drift reporting in `status`.
- `vm/cloud-init/user-data.yaml.tmpl` — working user, SSH key, and a call to
  the provisioning entry point. **No secrets, no substantive config.**
- Managed `~/.ssh/config` block, marker-delimited, rewritten on `start`,
  `status`, and `ssh`.

**Validation**
```powershell
vibebox create -Name vibebox-vm      # then run it again: must be a clean no-op
vibebox start; vibebox start         # idempotent
vibebox status -Json | ConvertFrom-Json
vibebox destroy -Name vibebox-vm     # must refuse without -Confirm
```
Interrupt a create (Ctrl-C mid-launch), re-run it, confirm recovery.
Reboot Windows, confirm the alias still resolves (D10).

**DoD**
- [ ] Every lifecycle verb is idempotent or refuses explicitly.
- [ ] Interrupted create is safely retryable.
- [ ] `vibebox destroy` without `-Confirm` exits 1 and changes nothing.
- [ ] An unrelated Multipass instance created by hand is untouched by every
      verb (create one, run all verbs, confirm).
- [ ] SSH alias survives a Windows reboot that changes the NAT subnet.
- [ ] `vibebox doctor` refuses on insufficient headroom for VM + legacy
      container + WSL2 concurrently.
- [ ] `status -Json` validates against the §3.2 schema.
- [ ] **No resource value is hardcoded**: `git grep -nE "\b(4|8G|128G)\b" vm/host/`
      finds no literal standing in for a config value.
- [ ] The §2.0 resource-bump walkthrough works end to end: edit `vibebox.env`,
      `config diff` shows the deltas, `config apply` reconciles, the guest sees
      the new CPU/RAM and the grown filesystem.
- [ ] `config apply` refuses a disk *shrink* with a clear message, and refuses
      create-time-only changes rather than half-applying them.
- [ ] `config apply` on a running VM refuses without `-Restart`.
- [ ] `status` reports drift when `vibebox.env` and the live VM disagree.
- [ ] `doctor` fails on a key-shaped value in `vibebox.env`, naming it.
- [ ] `doctor` warns if `BACKUP_DEST` resolves to the same physical drive as
      the VM disk — that silently defeats the point of an external backup.

---

### Phase 3 — Guest provisioning

**Deliverables**
- `vm/guest/provision/` — `00-base`, `10-docker`, `20-tailscale`, `30-tools`,
  `40-services`, plus `provision.sh` driver. Re-runnable, fail-loud.
- `vm/guest/manifest.toml` (policy) and generated `manifest.lock` (resolved).
- `vm/guest/units/` — real unit files replacing `hermes-gateway`, `droid-daemon`,
  and the Hermes WebUI boot call.
- `vm/guest/tailnet.d/` registry + `vibebox-tailnet.service` (oneshot,
  idempotent reconcile) + `vibebox tailnet` per §3.3. Ships with `hermes.conf`
  as the first entry.
- The tailnet policy/grant requirement documented as an enrollment step — the
  guest cannot self-authorize a service.
- Guest policy from §2.3: swap, persistent journald, unattended-upgrades,
  timesync.

**Validation**
```bash
sudo /opt/vibebox/provision.sh            # run 1
sudo dpkg -l > /tmp/a; systemctl list-unit-files > /tmp/b
sudo /opt/vibebox/provision.sh            # run 2
sudo dpkg -l | diff - /tmp/a              # must be empty
systemctl list-unit-files | diff - /tmp/b # must be empty
for t in claude codex bun node go gh docker; do "$t" --version || echo "FAIL $t"; done
systemctl is-enabled ssh tailscaled docker
```
Then reboot and confirm all-green within the 90 s readiness budget.

**DoD**
- [ ] Idempotence proven by **diffing system state** across two runs, not by
      reading the script.
- [ ] Provisioning succeeds on a VM that has been running for days, not only
      on first boot.
- [ ] All 7 required tools pass `--version`; optional misses are recorded.
- [ ] Zero custom supervisors, PID-file loops, or init stubs exist.
- [ ] Every long-running service is a native unit with `Restart=` and journal
      logging.
- [ ] `which systemctl npm pip3 tailscale` all resolve to upstream paths.
- [ ] Reboot → all-green `vibebox status` in ≤90 s with no host login.
- [ ] `vibebox tailnet add` creates a reachable HTTPS name end to end, with a
      valid auto-provisioned cert.
- [ ] `vibebox tailnet apply` run twice changes nothing the second time.
- [ ] A name removed from the registry is actually withdrawn from the tailnet
      by `apply` — orphan removal works, not just addition.
- [ ] `vibebox status` reports registry-vs-live drift for tailnet names.

---

### Phase 4 — Security and secret enrollment

**Deliverables**
- `vibebox enroll <tailscale|github|hermes>` — interactive, one secret at a
  time, never logged, never persisted host-side.
- Rescue password flow: generated **after** first boot, set over SSH, stored in
  a host file with restricted ACL, displayed once. Never in user-data.
- Restricted backup key: dedicated keypair, `authorized_keys` entry with
  `command="..."`, `no-pty,no-port-forwarding,no-agent-forwarding`.
- `vm/docs/security.md` — the boundary, the Windows firewall posture, the
  Tailscale ACL/tag for this node, and rotation/recovery procedures.
- Mount-drift detection wired into `vibebox status`.

**Validation**
```powershell
multipass get local.vibebox-vm.* | Select-String -Pattern "KEY|TOKEN|PASSWORD"   # empty
multipass info vibebox-vm --format json | ConvertFrom-Json   # no mounts
ssh -i .\backup_key dev@vibebox-vm "id"                      # must NOT get a shell
multipass mount . vibebox-vm:/mnt/test; vibebox status        # must go red, exit 5
multipass umount vibebox-vm
```

**DoD**
- [ ] No reusable secret appears anywhere in instance metadata or cloud-init.
- [ ] Backup key cannot obtain an interactive shell, a pty, or a port forward.
- [ ] Rescue password works at the console and exists in no repo file.
- [ ] No Windows drive, clipboard, device, agent socket, or Docker socket is
      reachable from the guest (re-run the Phase 1 canary).
- [ ] An added mount turns `vibebox status` red and exits 5.
- [ ] Tailscale node is tagged and least-privilege; rotation documented.

---

### Phase 5 — Operations parity

**Deliverables**
- `vibebox backup` (host-initiated pull, name-based ownership in the archive),
  `vibebox restore` (name-based mapping per plan D9, with `-DryRun`),
  `vibebox update`, `vibebox rebuild`.
- Quiesce hook directory in the guest: `/etc/vibebox/backup.d/{pre,post}`.
- `vm/docs/operations.md` — backup, restore, update, rollback, diagnostics.

**Validation** — **synthetic data only.**
```powershell
# Seed a synthetic home: files with known owners, modes, symlinks, a git repo,
# a sparse file, unicode + spaces in names, a deep path, a 2 GB file.
vibebox backup -Label synthetic-01
vibebox rebuild -Confirm
vibebox restore -Archive <archive> -DryRun
vibebox restore -Archive <archive>
```
Then assert, in the guest: every restored path is owned by `dev` **by name**,
modes match, symlinks are intact, the git repo is clean, and content hashes
match the pre-backup manifest.

**DoD**
- [ ] Destroy → rebuild → restore recovers 100% of synthetic data.
- [ ] After rebuild, a single `vibebox tailnet apply` restores **every** tailnet
      name from the registry, with working certs (§3.3).
- [ ] Ownership maps by name; restore **refuses** on a detected UID mismatch it
      cannot resolve (test this deliberately).
- [ ] Backup with a deliberately failing quiesce hook fails loudly, not
      silently.
- [ ] An archive is labeled crash-consistent when no hooks ran.
- [ ] A failed `update` is diagnosable and has a documented rollback that was
      executed at least once.
- [ ] `vibebox status` distinguishes all of: VM, SSH, Tailscale, Docker, disk,
      clock, mounts, individual services.
- [ ] `restore` cannot write to a Windows path or a differently-named instance
      (test both).

---

### Phase 6 — VPS conformance and synthetic soak

**Deliverables**
- The full `vm/conformance/` suite per §3.4, covering every row of the plan's
  validation matrix.
- `vm/docs/evidence/phase-6-conformance.md` and `-soak.md`.
- The **Gate A report** (§5).

**Validation** — run every §2.6 soak requirement, plus the VPS conformance
checks using **unmodified upstream instructions**:
Docker apt repo · Tailscale install · a second tailnet name via `vibebox
tailnet add`, HTTPS-reachable with a valid cert and surviving a reboot ·
PostgreSQL from apt · nginx on :80/:443
reachable over the tailnet · Node via NodeSource · Python venv · a hand-written
unit with `Restart=on-failure` + `EnvironmentFile` proven to survive `kill -9` ·
a timer that actually fires · `journalctl -u X -f` · `ss -tlnp` truthfulness ·
`loginctl enable-linger` surviving logout · `apt full-upgrade` + reboot ·
sysctl persistence · cgroup v2 delegation.

**DoD**
- [ ] Conformance suite runs green, or every failure has a written, *proposed*
      exception — the agent does not accept its own exceptions.
- [ ] Zero checks silently skipped; every skip states why.
- [ ] No upstream install needed a Vibebox-specific accommodation. Any that did
      is a defect fixed in this phase, not documented around.
- [ ] 7-day soak completed: ≥3 host reboots, ≥5 sleep/resume cycles, ≥1 full
      rebuild.
- [ ] Post-resume clock offset ≤2 s at every cycle; Tailscale reconnected; SSH
      worked.
- [ ] VM reachable after full Windows restart with zero manual steps.
- [ ] Gate A report written.

> ## 🛑 GATE A — STOP HERE
>
> **Do not copy, sync, read, or migrate any of the user's real data.** Not
> projects, not dotfiles, not shell history, not credentials. Not "just to
> test." Phases 0–6 are synthetic-data-only and this is the line.
>
> Deliver the Gate A report (§5) and **wait for an explicit go-ahead.**
>
> If the user says "not yet," that is a complete and successful outcome. Leave
> the VM as a synthetic test box and stop. Holding here costs nothing.

---

### Phase 7 — Side-by-side migration with real data

> Full work order: [`vm-work-orders-2.md` §4](./vm-work-orders-2.md).

Begins **only** after the user approves Gate A, and only for the data inventory
they approved.

**Deliverables**
- `vm/host/lib/migrate.ps1` — copies the approved inventory from the legacy box
  to the VM. **Read-only at the source.**
- `vm/docs/evidence/phase-7.md` — per-path migration record.
- Compatibility results for the repos the user picked.

**Validation**
- Legacy is read-only throughout: nothing deleted, nothing moved, nothing
  reconfigured. Prove it — record `docker ps` uptime continuity and a
  before/after checksum of the legacy home volume's top-level listing.
- Each chosen repo builds and tests in the VM with **zero** Vibebox-specific
  changes.
- File watchers fire on native edits; permissions, `localhost`, bind mounts,
  and Docker volume paths behave as native Linux.

**DoD**
- [ ] Every approved path migrated, verified by checksum.
- [ ] Nothing outside the approved inventory was copied.
- [ ] Restored data has correct ownership, modes, and git state.
- [ ] Node, Python, Go, Compose, localhost-server, and systemd workflows all
      behave like ordinary Ubuntu.
- [ ] The legacy box is demonstrably untouched and still the daily driver.
- [ ] Backup/restore re-proven on **real** data.

> ## 🛑 GATE B — STOP HERE
>
> Cutover is identity-changing and disruptive. **Schedule it with the user.**
> Present the §6 cutover plan and get agreement on each item — especially the
> Tailscale identity handover, which is the most likely cutover-day failure.
>
> An unanswered scheduling question is a blocker. Do not pick a date.

---

### Phase 8 — Cutover

> Full runbook: [`vm-work-orders-2.md` §5](./vm-work-orders-2.md).

Execute the agreed plan, in the agreed window, nothing more.

**DoD**
- [ ] Final legacy backup taken **and restore-tested**, not merely created.
- [ ] Legacy Tailscale node released *before* the VM claims the name; the VM is
      `vibebox`, not `vibebox-1` (check the admin console, not just the CLI).
- [ ] Delta sync completed and verified.
- [ ] Local and tailnet SSH reach the VM at the documented names, **verified
      from a second device**.
- [ ] All services survive VM reboot and Windows restart.
- [ ] `vm/README.md` promoted to root; root README describes only the VM path.
- [ ] Rollback rehearsed during the window and shown to work.

---

### Phase 9 — Retire the legacy edition

> Full work order: [`vm-work-orders-2.md` §7](./vm-work-orders-2.md).

Only on the user's explicit decision, after the 30-day window and ≥1 successful
real recovery.

**Deliverables**
- `gpu/` — a standalone, minimal GPU project extracted from the legacy edition
  before it is deleted (§2.5): a CUDA base image, a Compose file, and a README
  covering how to run it on Windows against Docker Desktop. It owns GPU work
  and nothing else, and has no dependency on `legacy/` or `vm/`.

**DoD**
- [ ] `gpu/` exists and has run a real GPU job end to end (evidence: the job's
      output plus `nvidia-smi` from inside the container).
- [ ] **Retirement is blocked until the box above is checked.** Deleting
      `legacy/` without it destroys the user's GPU capability.
- [ ] `legacy-final` tag pushed before deletion.
- [ ] `legacy/` and the four root shims removed.
- [ ] `NO_SYSTEMD.md` deleted, not rewritten.
- [ ] Migration notes preserved in `docs/`.
- [ ] The no-legacy-refs CI check removed (nothing left to reference).

---

## 5. The Gate A report

Write to `vm/docs/evidence/gate-a-report.md`. Sections, all required:

1. **Conformance results** — pass/fail/skip counts, and every proposed
   exception with its risk.
2. **Soak findings** — what broke, what was fixed, what remains flaky.
3. **Proposed data inventory** — a table: source path, what it is, approximate
   size, whether it carries credentials, migrate yes/no.
4. **Deliberate exclusions** — what will *not* migrate and the re-authentication
   work that implies (agents, GitHub, Tailscale, Hermes, API keys).
5. **Resource assessment** — disk and RAM with VM + legacy container + WSL2 all
   running.
5a. **GPU workload inventory** — what the user actually runs on the GPU today,
   and which of it will live on the WSL2 path after cutover (D14, §2.5). The user
   should see this split before approving migration, not after.
6. **Compatibility repo candidates** — proposed, for the user to choose from.
7. **Honest risk list** — what you are least confident about. This section
   being short is a warning sign, not a good result.

Then stop.

---

## 6. The Gate B cutover plan

Present for agreement; do not act on any of it unilaterally.

| Item | Needs |
|---|---|
| Window | A date/time the user picks, accounting for in-flight work. Not a default, not a Friday. |
| Delta sync | What changed since Phase 7, and how long it takes |
| Tailscale handover | Exact order: remove/rename legacy node → VM claims `vibebox` → verify in the admin console |
| SSH host keys | New host identity; `known_hosts` update on every device the user connects from |
| Abort trigger | Defined *before* starting — what specifically means "roll back" |
| Rollback window | Default 30 days; confirm |
| Presence | What the user must be there for |

---

## 7. Evidence and reporting

Every phase writes `vm/docs/evidence/phase-N.md` containing: commands run,
verbatim output for each DoD item, anything that failed and how it was fixed,
and anything still unresolved. Evidence is what makes the gates reviewable
instead of a trust exercise — the Gate A report is assembled from it.

Report progress in terms of DoD boxes checked, not phases "mostly done." A
phase with an unchecked box is not done.

---

## 8. Stop conditions

Halt and ask the user when any of these occur. This list is exhaustive for
"must stop"; use judgment beyond it.

1. **Gate A** — before any real user data moves.
2. **Gate B** — before cutover.
3. **A secret is needed** — Tailscale auth key, GitHub credentials, Hermes
   password, anything else. Never invent, reuse from `legacy/.env`, or read one
   out of the running container.
4. **Risk-register A2 fails** — no working rescue console. This triggers the
   direct-Hyper-V fallback, a scope change the user must approve.
5. **Any adapter fallback** — replacing Multipass with direct Hyper-V
   automation, for any reason.
6. **A conformance check fails and you want to accept it** — propose the
   exception; the user accepts it.
7. **Anything would modify, stop, or reconfigure the legacy box** outside the
   Phase 0 file move.
8. **A Windows host reboot is needed** — the user may be mid-work.
9. **A resolved parameter in §2 appears wrong** — propose the change, don't
   silently deviate.
10. **A destructive operation would target something you did not create.**
11. **Phase 1 finds GPU passthrough is actually available** (contradicting
    D14/§2.5). Report it; enabling it is a scoped decision, not an in-flight
    scope change.

---

## 9. Overall definition of done

The delegation is complete when:

- [ ] Phases 0–6 are done with every DoD box checked and evidence recorded.
- [ ] The conformance suite is green or carries only user-accepted exceptions.
- [ ] The 7-day soak passed, including reboots, sleep/resume, and a rebuild.
- [ ] A clean Windows host can go from `git clone` to a working VM using only
      `vm/docs/` — verified by following your own docs literally.
- [ ] The Gate A report is written and delivered.
- [ ] The agent has stopped at Gate A and is waiting.

Phases 7–9 are **not** part of a single delegation. They resume on the user's
go-ahead, each behind its own gate, and are specified in
[`vm-work-orders-2.md`](./vm-work-orders-2.md).

A delegation that reaches Gate A with honest evidence — including failures — has
succeeded. One that reaches Phase 8 without asking has failed, regardless of
whether the VM works.
