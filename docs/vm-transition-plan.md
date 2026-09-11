# Vibebox transition to a VPS-style Ubuntu VM

Status: Proposed (revised after pressure test)
Last updated: 2026-09-11
Implementation work orders: [`vm-work-orders.md`](./vm-work-orders.md) (Phases 0–6)
  and [`vm-work-orders-2.md`](./vm-work-orders-2.md) (Phases 7–9)

This document is the decision record: what must be true, and why. The companion
work-orders document is the executable plan: resolved parameters, deliverables,
interface contracts, validation commands, and per-phase definitions of done.
Read this first; build from that.

## Executive summary

Vibebox currently runs a long-lived Docker container as if it were a Linux
machine. That forces the project to emulate machine behavior with a custom PID
1, a `systemctl` stub, hand-written daemon supervisors, a shared Tailscale
network namespace, Docker socket forwarding, host-filesystem workarounds, and
environment forwarding through SSH.

The transition will replace that runtime with a genuine Ubuntu Server virtual
machine. The VM will use systemd, its own Linux filesystem, its own network
identity, native Tailscale, and its own Docker Engine. Applications running in
the guest may detect that they are virtualized, as they can on a normal VPS,
but must not observe Docker or WSL as the machine substrate.

**The objective is compatibility, not novelty.** The measure of success is that
software written for an ordinary Ubuntu VPS — systemd units, timers, socket
activation, `apt` repositories, upstream install scripts, Docker Engine,
language runtimes, anything that assumes a real machine — works with its stock
instructions and no Vibebox-specific accommodation. Every decision below is
subordinate to that.

The recommended foundation is:

- [Canonical Multipass](https://github.com/canonical/multipass) for VM lifecycle
  on Windows, using its Hyper-V driver.
- An official Ubuntu Server 24.04 LTS cloud image for the migration baseline.
- [cloud-init](https://github.com/canonical/cloud-init) for non-secret first-boot
  configuration.
- A thin Vibebox-owned layer for configuration, validation, backup, restore,
  migration, and user-facing commands.
- Ansible only if configuration grows beyond what cloud-init and small,
  idempotent guest scripts can maintain clearly.

Vibebox will consume these projects through their published interfaces. It
will not fork Multipass, build Ubuntu, or maintain a hand-edited golden image.

The container implementation is **preserved as a frozen legacy edition**, and
the VM edition is built as a **clean sibling tree that never imports from it**.
Two explicit human approval gates sit in the timeline: one before any real user
data is copied into the VM, and one before cutover.

## Why this transition is necessary

The present architecture exposes an Ubuntu-looking userspace without an Ubuntu
machine contract. Examples include:

- `scripts/entrypoint` acts as PID 1 and eventually execs `sshd`.
- `scripts/systemctl` shadows the real command because systemd is absent.
- `scripts/hermes-gateway` and `scripts/droid-daemon` implement service
  supervision that would normally belong to systemd.
- The sandbox shares the Tailscale sidecar's network namespace, including its
  `/etc/hosts`, and repairs `localhost` when that shared file is damaged.
- The Docker CLI controls the host daemon through `/var/run/docker.sock`, so
  paths and lifecycle do not behave as though Docker were running locally.
- Optional Windows home-directory mounts introduce non-Linux rename,
  ownership, watcher, and performance behavior.
- Wrappers for `npm`, `pip3`, `systemctl`, and `tailscale` change the meaning of
  standard commands.

Each workaround addresses a real symptom, but the collection makes Vibebox an
additional platform that tools and applications accidentally have to support.
The VM transition removes that platform rather than adding more emulation.

## Goals

1. Make the guest behave like an ordinary Ubuntu VPS, verified by running
   unmodified upstream installation and operation instructions.
2. Keep Windows outside the guest trust boundary.
3. Preserve the useful Vibebox experience: persistent work, SSH access,
   Tailscale access, agent tooling, backup, restore, and straightforward
   rebuilds.
4. Use maintained upstream software for virtualization, base images, and
   instance initialization.
5. Keep all Vibebox customization declarative, reviewable, idempotent, and
   reproducible from a clean upstream image.
6. Allow project-owned Docker Compose or Dev Container environments to run on
   the VM without knowing about Vibebox.
7. Provide a side-by-side migration and rollback path before retiring the
   container implementation.
8. Keep the legacy container edition intact, runnable, and untouched by VM
   work until the user explicitly agrees to cut over.

## Non-goals

- Hiding the fact that the machine is virtualized. Hyper-V hardware metadata is
  acceptable and equivalent to virtualization metadata on a cloud VPS.
- Running systemd inside the existing Vibebox container.
- Preserving host-folder mounts or Docker Desktop integration.
- Building or maintaining an Ubuntu distribution, kernel, or installer.
- Supporting every hypervisor in the first release.
- Changing Ubuntu major versions during the architecture migration.
- Delivering GPU access inside the VM. Not deferred — structurally
  unavailable on this host (D14). GPU work stays on the WSL2 path.
- Making application-specific dependencies part of the Vibebox base machine.
- Refactoring, improving, or bug-fixing the legacy container edition. It is
  frozen; it receives security-relevant fixes only.

---

## Repository layout: legacy edition and VM edition as siblings

### D0. Preserve the container implementation as a frozen legacy edition

The current implementation is a working machine the user depends on daily. It
is not deleted, rewritten in place, or gradually mutated into the VM edition.
It moves wholesale into `legacy/` and is frozen there.

### D0.1. Build the VM edition as a clean sibling, not a refactor

The VM edition lives in `vm/`. It starts empty and is written against Ubuntu +
systemd + cloud-init directly. Legacy code may be *read* for requirements — it
is the specification of what Vibebox does — but no file is copied across
without being rewritten for the VM contract.

Target layout:

```text
vibebox/
├── README.md                  # chooser: which edition is current, and why
├── docs/
│   └── vm-transition-plan.md  # this document
│
├── legacy/                    # FROZEN container edition
│   ├── Dockerfile
│   ├── docker-compose*.yml
│   ├── scripts/               # entrypoint, systemctl stub, supervisors, wrappers
│   ├── hermes-serve/
│   ├── setup-sandbox.*  update-image.*  backup.*  restore.*
│   ├── README.md              # the current README, moved verbatim
│   └── NO_SYSTEMD.md
│
└── vm/                        # VM edition (clean-room)
    ├── README.md
    ├── host/                  # Windows control plane
    │   ├── vibebox.ps1        # single namespaced entry point
    │   └── lib/               # preflight, lifecycle, ssh-config, backup, status
    ├── cloud-init/
    │   └── user-data.yaml.tmpl
    ├── guest/
    │   ├── manifest.toml      # pinned tool versions + update policy
    │   ├── provision/         # 00-base 10-docker 20-tailscale 30-tools 40-services
    │   └── units/             # real systemd unit files
    ├── conformance/           # the VPS-authenticity test suite (Phase 6)
    └── docs/
```

**Hard rule:** nothing under `vm/` may reference, source, copy at runtime, or
depend on anything under `legacy/`. A CI or pre-commit check greps for
`legacy/` inside `vm/` and fails. This is what makes "clean sibling" a fact
rather than an intention.

### D0.2. Move legacy early, with forwarding shims

The `git mv` into `legacy/` happens as one mechanical, history-preserving
commit at the start of the work — not at the end. Deferring it leaves container
files at the repo root where new VM code will keep drifting into them.

To avoid breaking the user's running box on day one, thin forwarding shims stay
at the repo root for the four host-invoked entry points — `setup-sandbox.ps1`,
`update-image.ps1`, `backup.ps1`, `restore.ps1` — each printing a one-line
relocation notice and delegating to `legacy/`. The shims are deleted in the
final retirement phase.

Rationale for the shims: these scripts are invoked by path from a Windows
shell and from muscle memory. Everything else in the legacy tree is referenced
from *inside* those scripts by relative path and moves without incident.

### D0.3. The root README becomes a chooser

Until cutover, the root `README.md` is a short page stating which edition is
current (legacy), which is under construction (VM), and where each lives. The
full current README moves to `legacy/README.md` verbatim. At cutover the VM
README is promoted to root.

---

## Decisions

### D1. Use a full virtual machine

The guest will have its own kernel, systemd as PID 1, virtual disk, virtual
network adapter, and resource boundary. A system container, privileged Docker
container, or WSL distribution does not meet the target contract.

### D2. Prefer Multipass over custom Hyper-V orchestration

Multipass already downloads Ubuntu images, creates Hyper-V VMs on Windows,
passes cloud-init data, and exposes lifecycle operations. Vibebox should wrap
that interface rather than recreate image import, virtual-disk creation,
cloud-init seed media, boot discovery, and deletion.

Direct Hyper-V automation remains the fallback if the proof-of-concept shows
that Multipass cannot enforce the required isolation, networking, naming,
backup, or recovery behavior. The guest configuration must remain independent
of Multipass so changing the lifecycle adapter does not redesign the guest.

**Pressure-test caveat.** Multipass is a convenience layer over Hyper-V, and
several properties this plan asserts are Hyper-V properties that Multipass may
not expose. Phase 1 must verify each of them against the real tool rather than
assume; see "Adapter risk register" below. The design keeps `vm/host/` thin
precisely so that swapping the adapter costs a rewrite of one directory.

### D3. Download and configure; do not build the base image

The source of truth will be a verified official Ubuntu image plus versioned
Vibebox configuration. A preconfigured image may later be generated as a
performance cache, but it must be disposable output that can be regenerated
from those inputs.

### D4. Keep Ubuntu 24.04 LTS for the first migration

The current image uses Ubuntu 24.04. Keeping that release separates runtime
architecture changes from distribution-upgrade changes. Ubuntu 26.04 LTS can
be evaluated after feature parity and stability are established.

### D5. Treat the VM like an untrusted remote VPS

Windows directories, drives, clipboards, devices, credentials, and Docker
sockets will not be mounted or forwarded into the VM. Communication will use
narrow network protocols, primarily SSH and Tailscale.

### D6. Do not shadow standard commands

Commands such as `systemctl`, `npm`, `pip3`, `tailscale`, and `update` must
retain their upstream behavior. Product operations will be namespaced under a
single `vibebox` command or remain explicit host scripts.

### D7. Separate machine configuration from user data

The operating system and installed toolchain are rebuildable. Projects,
dotfiles, selected application state, and user-created data are backed up from
the guest. Secrets and machine identities require explicit handling rather
than being swept into a generic environment or archive unnoticed.

"Explicit handling" means a deliberate, recorded decision per credential — not
necessarily refusal. The user has accepted two documented exceptions (agent
credentials and the SSH private key cross into the VM); see work-orders part 2
§3.2. The requirement this decision actually encodes is that nothing crosses
*unnoticed*, and that the resulting boundary is described accurately
afterward. Machine identity — Tailscale state in particular — is still never
duplicated, because that is a correctness constraint rather than a preference.

### D8. Keep application environments repository-owned

Vibebox supplies a normal workstation and Docker host. Each application owns
its Compose, Dev Container, package-manager, and runtime configuration. A
project that deploys to containers should test in its containers; a project
that deploys as a systemd service can test against the VM's real systemd.

### D9. Two accounts: a rescue account and the working account

Multipass creates and expects the cloud image's default `ubuntu` user (UID
1000) and uses it for `multipass shell` and `multipass exec`. Overriding
cloud-init's `users:` list to replace it with `dev` breaks Multipass's own
access path — which is also the recovery path when sshd is broken.

Decision: keep `ubuntu` as the Multipass-owned rescue/admin account, and create
`dev` as the working account that SSH, Tailscale, and all user data belong to.
`dev` will not be UID 1000.

**Consequence to handle explicitly:** legacy backups contain files owned by UID
1000 (`dev` in the container). Restore must map ownership by *name*, not by
numeric UID, or every restored file lands owned by `ubuntu`. The restore tool
must do this and the conformance suite must test it. This is the single most
likely silent data-integrity bug in the whole migration.

The alternative — forcing `dev` to UID 1000 and relocating `ubuntu` — is
rejected: it fights the image, fights Multipass, and trades a one-time restore
mapping for a permanent source of surprise.

### D10. Tailscale is the stable address; the local IP is not

The Hyper-V Default Switch assigns NAT addresses from a range that Windows
re-derives across host reboots. A Vibebox VM will not have a stable local IP,
and hard-coding one into `~/.ssh/config` will break roughly whenever the host
reboots.

Therefore:

- The primary, documented address is the Tailscale name (`ssh dev@vibebox`
  over the tailnet), which is stable by construction.
- The local-IP SSH alias is a *derived, refreshable* convenience. The
  `vibebox` command rewrites its managed block in `~/.ssh/config` on every
  `start` and `status`, and `vibebox ssh` refreshes before connecting.
- The managed block is delimited by begin/end markers and never rewrites
  user-authored entries.

### D11. Out-of-band console access is a requirement, not a nicety

A real VPS has a rescue console that works when sshd, networking, or the
firewall is broken. Without one, a bad `ufw` rule or a broken `sshd_config` is
an unrecoverable box.

`multipass shell` does **not** satisfy this: it is itself SSH into the guest
and fails in exactly the scenarios a console is for. The supported recovery
path is Hyper-V's console via `vmconnect.exe` (or Hyper-V Manager), and Phase 1
must prove it reaches a working login prompt for a Multipass-created instance.
If it cannot, that is a hard requirement failure and triggers the direct
Hyper-V adapter fallback.

A documented `ubuntu` rescue password, or a console-usable credential, must
exist for this path to be usable.

### D12. Host-boot and host-shutdown behavior must be defined

A VPS is up when you reach for it. Decisions:

- **Autostart:** the VM starts on Windows boot. Whether this is Multipass's own
  restore behavior or Hyper-V `AutomaticStartAction = Start` (with a delay) is
  determined in Phase 1; one of them must be made to work.
- **Host shutdown:** prefer ACPI shutdown (`AutomaticStopAction = Shutdown`)
  over Save state. Saved-state resume produces clock jumps, stale Tailscale
  sessions, and timers that fire in a burst — all of which read as flaky to
  applications. A clean boot is more VPS-like than a restored snapshot.

### D13. Clock correctness across host sleep is a first-class concern

This is a laptop-class host. Suspend/resume clock drift causes TLS failures,
"expired" tokens, and mass timer firing, and it is one of the most common ways
a local VM stops behaving like a VPS.

The guest must run Hyper-V integration services (`hv_utils` time sync) and
`systemd-timesyncd`, and the conformance suite must include a host
sleep/resume cycle with an assertion on post-resume clock offset, Tailscale
reconnection, and SSH reachability.

### D14. The VM is CPU-only; GPU work stays on the WSL2 path

This is a structural constraint of the host, not a deferral.

A GPU cannot be delivered to a Hyper-V **Linux** guest on a Windows **client**
host. The two mechanisms that exist do not apply:

- **DDA** (Discrete Device Assignment) is real PCIe passthrough, but requires
  Windows Server as the host, is unavailable on Windows 10/11 Pro, dismounts
  the GPU from the host for the VM's entire lifetime, and is not exposed by
  Multipass at all.
- **GPU-PV** (paravirtualization) is what WSL2 and Windows Sandbox use. It is
  supported for WSL2 and Windows guests; a Linux Hyper-V VM is not a supported
  target for it.

Vibebox's GPU capability today runs through Docker Desktop → WSL2 → GPU-PV, and
that path is unaffected by this migration. So:

- The VM is CPU-only and does not pretend otherwise. `vibebox status` reports
  no GPU rather than leaving the user to discover it.
- GPU workloads — CUDA docling, local models, anything needing `/dev/nvidia*` —
  continue to run on the host's Docker Desktop/WSL2 path.
- Docling in the guest uses CPU PyTorch wheels, which is already the legacy
  default.

**Consequence for retirement.** Phase 9 deletes `legacy/`, which is where the
GPU container definition lives. Deleting it would silently remove the user's
GPU capability. Therefore Phase 9 must first extract a minimal, standalone
`gpu/` project — a CUDA base image and Compose file, run on Windows against
Docker Desktop, owning nothing but GPU work. Retirement is blocked until that
exists and has been proven to run a GPU job.

This constraint is verified on the real host in Phase 1 rather than taken on
faith; see risk A11.

### D15. Multiple tailnet names come from Tailscale Services, not extra nodes

Vibebox needs more than one tailnet name — today `vibebox` (SSH) and `hermes`
(the WebUI), and more over time. The legacy edition achieves this by running
one Tailscale **sidecar container per name**, because a Tailscale node serves
one hostname.

The VM does not repeat that. It runs **one node and advertises N services**:

```
tailscale serve --service=svc:hermes --https=443 http://127.0.0.1:8080
```

Each service gets its own virtual IP, its own MagicDNS name, and its own
auto-provisioned TLS certificate, from a single `tailscaled`. Adding a name is
a command, not a new daemon.

Rejected alternative: multiple `tailscaled` instances, one per name, each with
its own state directory, socket, and port. It works — it is what the legacy
hermes sidecar does in userspace mode — but it costs a daemon and a tailnet
machine per name, multiplies auth and expiry lifecycles, and forces
`--socket=` onto every CLI invocation for non-primary nodes, which invites
exactly the kind of wrapper D6 forbids. It is also the container-era topology
re-expressed in systemd, which is what this migration exists to remove. It
remains the documented fallback if Services is unavailable.

Names must be **declarative and reproducible**: a registry in the repository,
reconciled by an idempotent operation, so a rebuilt VM restores every URL from
version control rather than from memory. A name that exists only because
someone once ran a command is a name that will not survive a rebuild.

Two things sit outside the guest and must be handled as explicit enrollment
steps: services have to be declared in the tailnet policy file, and the node
has to be granted permission to advertise them. The VM cannot self-serve
either. See risk A12.

---

## Target architecture

```text
Windows host
|
+-- Multipass (Hyper-V lifecycle only)  [multipassd runs as SYSTEM]
|   |
|   `-- Ubuntu Server 24.04 LTS VM  (Gen 2)
|       |-- systemd (PID 1)
|       |   |-- ssh.service
|       |   |-- tailscaled.service
|       |   |-- docker.service
|       |   |-- systemd-timesyncd.service
|       |   `-- Vibebox-managed application units
|       |
|       |-- native ext4 filesystem on the VM disk
|       |   |-- /etc and /usr: provisioned machine state
|       |   |-- /home/ubuntu: rescue/admin account (Multipass-owned)
|       |   `-- /home/dev:    persistent user data
|       |
|       |-- one Tailscale node identity  <- stable address
|       |   `-- N advertised services (hermes, ...) each with its own name+cert
|       `-- native Docker Engine
|           `-- project-owned containers
|
+-- SSH client and a dedicated per-VM client key
+-- Hyper-V console (vmconnect) as out-of-band rescue path
+-- host-controlled backup storage (pull-only, guest cannot write)
`-- no guest-visible Windows drives or Docker Desktop socket
```

Multipass is part of the host control plane, not the guest runtime contract.
Normal tools inside Ubuntu interact with Ubuntu, systemd, and the guest's
Docker daemon directly.

---

## Security model

### Isolation requirements

- Use a Generation 2 Hyper-V VM. Secure Boot **with the Microsoft UEFI CA
  (Linux-compatible) template if the adapter supports it** — see the adapter
  risk register; this is verified, not assumed.
- Do not enable Multipass directory mounts, Hyper-V drive sharing, clipboard
  redirection, USB passthrough, GPU passthrough, or enhanced-session resource
  sharing.
- Do not expose `/var/run/docker.sock` or any Docker Desktop API to the guest.
- Do not use SSH agent forwarding from Windows.
- Store the VM on a Windows volume protected by the host's normal disk
  encryption and access controls.
- Treat traffic from the VM as untrusted at the Windows firewall.
- Give the VM a dedicated Tailscale identity with least-privilege ACLs or
  grants. Compromise of the node must not imply broad tailnet access.
- Keep backups outside the VM and inaccessible for guest-initiated writes.
- Keep Hyper-V, Windows, Ubuntu, firmware, and guest packages patched.

### Host-side control-plane exposure (new)

Installing Multipass adds a privileged Windows service (`multipassd`, running
as SYSTEM) with a local control channel. Any Windows-side principal permitted
to drive it can create VMs and — relevant here — **enable host directory mounts
into an existing instance**, bypassing the isolation posture above.

This is a host-side risk, not a guest-escape path: the guest cannot reach the
control channel. It must still be recorded, because it means the isolation
guarantee is "no mounts are configured," not "mounts are impossible."

Mitigations:

- Restrict which Windows accounts can drive Multipass to the intended user.
- `vibebox status` asserts that the instance has zero mounts and reports a
  loud failure if any appear — configuration drift is detected, not assumed
  away.
- Document that a Windows admin compromise is game over for the VM's
  isolation, as it is for any local hypervisor.

### Secret handling

Static cloud-init user-data is not a secret store; it persists in guest and
host-side instance metadata readable by SYSTEM and local administrators. It may
contain public SSH keys and non-sensitive configuration, but not long-lived API
keys, reusable Tailscale keys, passwords, or private SSH keys.

Secrets must be introduced through an explicit allowlist after the VM is
reachable. One-time enrollment credentials should be short-lived and removed
after use. Services that need persistent secrets should read guest-owned files
with restrictive permissions or an appropriate systemd credential mechanism.
The current behavior of forwarding every `.env` value into every SSH session
will be removed.

### Backup channel authorization (new)

Host-initiated pull means Windows holds a credential that can read the entire
guest. That credential is:

- a dedicated SSH key used only for backup, not the interactive key;
- restricted in the guest's `authorized_keys` with a forced `command=` that
  runs only the backup producer, plus `no-port-forwarding`,
  `no-agent-forwarding`, `no-pty`;
- stored on the Windows side with the same care as any other credential.

This prevents the backup key from being a general-purpose root-equivalent
remote shell, which is what an unrestricted pull key would be.

### Expected compromise boundary

A compromised guest may control all guest data, use credentials stored inside
the guest, and attack services reachable over the network. It must not have a
filesystem path, device, management API, or forwarded credential that directly
grants control of Windows. Hypervisor escape remains a residual platform risk,
as it is for any VPS, and is mitigated by patching and minimizing integrations.

---

## Configuration model

Configuration will be divided by responsibility:

| Layer | Contents | Secret-bearing | Re-runnable |
|---|---|---:|---:|
| Host configuration | Instance name, CPU, memory, disk, Ubuntu release, SSH alias | No | Yes |
| cloud-init | User, public key, base packages, system defaults, bootstrap hooks | No | First boot |
| Guest provisioning | Docker, Tailscale package, tools, systemd units, policies | No | Yes |
| Enrollment | Tailscale authentication and user/tool logins | Yes | Explicitly |
| User state | Projects, dotfiles, selected tool configuration | Sometimes | Restorable |

**cloud-init bootstraps; it does not provision.** cloud-init runs once and
cannot be re-run cleanly, so it is limited to creating the working user,
installing SSH keys, and fetching/invoking the provisioning entry point.
Everything substantial lives in `vm/guest/provision/`, which must be runnable
any number of times, on a fresh boot or a five-month-old box, with the same
result. A provisioning step that can only run once is a bug.

The guest provisioning layer must fail loudly and be grouped by capability
rather than reproduced as one monolithic Dockerfile. Introduce Ansible only
when it materially improves idempotence, testing, or readability.

Third-party tool versions are governed by `vm/guest/manifest.toml`. `latest`
may be offered as an explicit update policy, but a clean rebuild must record
the resolved versions so a failed upgrade can be reproduced and rolled back.

---

## Current-to-target component mapping

Legacy components are not edited; each row describes what the VM edition
builds in `vm/`, and what happens to the legacy file at retirement.

| Legacy component (in `legacy/`) | VM edition disposition |
|---|---|
| `Dockerfile` | Decompose into cloud-init, `vm/guest/provision/`, and `manifest.toml` |
| `docker-compose.yml` sandbox | No equivalent; Multipass/Hyper-V owns the machine |
| Tailscale sidecar | Native `tailscaled.service` in the guest |
| Hermes Tailscale sidecar | No sidecar and no second node: a Tailscale **Service** advertised from the one guest node (D15) |
| `scripts/entrypoint` | Nothing; systemd and standard boot own initialization |
| `scripts/systemctl` | Nothing; `/usr/bin/systemctl` is real |
| `scripts/hermes-gateway` | `vm/guest/units/` unit using upstream foreground mode |
| `scripts/droid-daemon` | `vm/guest/units/` unit using upstream foreground mode |
| Hermes WebUI `ctl.sh` boot call | A systemd unit |
| Host Docker socket and GID repair | Nothing; native Docker Engine in the VM |
| `scripts/tailscale` wrapper | Nothing; native Tailscale CLI |
| `scripts/npm`, `scripts/pip3` wrappers | Nothing; upstream commands preserved, policy documented separately |
| Generic `update` and `launch` commands | Under the `vibebox` namespace to avoid collisions |
| `setup-sandbox.ps1` | `vm/host/vibebox.ps1 create` |
| `setup-sandbox.sh` | Deferred until a supported non-Windows VM backend is defined |
| `update-image.*` | `vibebox update` (guest) and `vibebox rebuild` (clean) |
| `backup.*` | Host-initiated pull over SSH with a restricted forced-command key |
| `restore.*` | Restore into a stopped or maintenance-mode guest, with name-based ownership mapping (D9) |
| `onboard` | Namespaced, user-level guest workflow; no machine boot responsibilities |
| `.env` bulk forwarding | Separate non-secret settings and explicit secret enrollment |
| `authorized_keys` bind mount | Public keys via cloud-init or an explicit host management operation |
| Docker named home volume | Selected data migrated to the VM's native `/home/dev`; protected by external backup |
| Compose CPU/memory/PID limits | VM boundary owns CPU/memory/disk; systemd controls only where needed |
| Compose health checks | Host-side readiness checks and native systemd service health |
| GPU Compose overlay | No VM equivalent (D14). Extracted to a standalone `gpu/` project at Phase 9, before `legacy/` is deleted |
| `NO_SYSTEMD.md` | Deleted at retirement, not rewritten — the concept ceases to exist |

---

## User experience contract

The user should be able to perform the following operations without learning
Multipass internals:

- Create a named Vibebox from a clean Ubuntu image.
- Start, stop, restart, inspect, and destroy it.
- Connect locally with `ssh <name>` and remotely through its Tailscale name.
- Reach a rescue console when SSH is broken.
- See whether the VM, SSH, Tailscale, Docker, disk, clock, mount posture, and
  managed services are healthy.
- Update user tools without silently changing the base OS contract.
- Rebuild the machine from configuration and restore user data.
- Back up data to Windows without making Windows storage writable from the VM.
- Diagnose failures using standard Ubuntu tools such as `systemctl`,
  `journalctl`, `ss`, `ip`, `apt`, and Docker's native CLI.

The guest must remain usable without the Vibebox CLI. Product commands provide
convenience; they must not be required to make ordinary Linux administration
work.

---

## Backup, restore, and persistence

Versioned configuration in Git is the backup for machine setup. User data is
backed up independently.

The default backup direction is host-initiated pull: Windows connects to the VM
over the restricted backup channel and stores an archive outside the virtual
disk. The guest never receives a writable mount of the backup destination.
Archives remain opaque on Windows during normal operation and are streamed back
into a controlled restore environment when needed.

**Consistency.** A pull taken while services are running captures databases and
long-lived agent state mid-write. Backup therefore supports optional quiesce
hooks — a documented `pre-backup`/`post-backup` drop-in directory in the guest
where a project can stop a service or take a database dump. Absent hooks, the
archive is explicitly "crash-consistent," and the docs say so rather than
implying more.

**Ownership.** Archives record user and group *names*. Restore maps by name
(D9). A restore that silently lands everything under `ubuntu` is a failure
condition the restore tool must detect and refuse.

The initial retention policy preserves the current seven-day default and
labeled safety backups. Multipass/Hyper-V snapshots of a stopped instance may
supplement this for short-term rollback — they are excellent as a pre-upgrade
undo — but they do not replace external user-data backups, because they live on
the same disk and die with it.

A clean migration is the default. This project has accepted two explicit
departures from it (work-orders part 2 §3.2), which is allowed precisely
because they are written down:

- Transfer project directories, dotfiles sources, shell history if desired,
  and explicitly selected application state.
- Reinstall machine tools through provisioning.
- Reauthenticate GitHub, Tailscale, and API-key-bearing services. (Agent
  credentials are an accepted exception and come across with `~/.claude`.)
- Generate a new SSH host identity and update the managed `known_hosts` entry.
- Do not automatically import cached packages, old supervisors, `.vibebox`
  internals, machine binaries, or bulk environment files.

A full-home compatibility import may remain an explicit escape hatch, but it
must be labeled as carrying old credentials and container-era state into the
new trust boundary.

---

## Transition phases

Ten phases. Two of them are **hard stops that require the user's explicit
go-ahead** before the next phase begins: Gate A before real user data is
touched, and Gate B before cutover. Work does not drift across those lines.

### Phase 0: repository split (mechanical)

Move the container edition into `legacy/` in one history-preserving commit.
Create the empty `vm/` skeleton. Add root forwarding shims and the root
chooser README. Add the CI check that forbids `legacy/` references inside
`vm/`.

Exit gate:

- The legacy box can still be set up, updated, backed up, and restored using
  the documented commands (verified, not assumed).
- `git log --follow` still traces legacy file history.
- `vm/` contains no code copied from `legacy/`.

### Phase 1: architecture proof

Create a disposable, explicitly named Multipass instance using Hyper-V and the
official Ubuntu 24.04 image. Prove the architectural claims — and the adapter's
limits — before porting anything.

Exit gate:

- PID 1 is systemd; `systemctl` and `journalctl` work normally.
- The guest is not Docker or WSL and has no Windows drive mounts.
- SSH works locally without shared folders or agent forwarding.
- Native Tailscale and Docker Engine work and survive a reboot.
- The guest cannot read a Windows-side canary file or reach a host management
  interface.
- Multipass can enforce the required CPU, memory, disk, naming, lifecycle, and
  deletion behavior.
- **Every item in the adapter risk register below has a verified answer** —
  Secure Boot state, console access, autostart, stop action, disk growth,
  snapshots, nested virtualization.
- The Hyper-V console reaches a login prompt with sshd deliberately stopped.

If Multipass fails a hard requirement and has no safe supported configuration,
replace only `vm/host/` with direct Hyper-V automation. `vm/guest/` is
unaffected — that separation is the point.

### Phase 2: host lifecycle foundation

Define the supported Windows/Hyper-V preflight checks and the Vibebox lifecycle
contract. Establish deterministic instance naming, resource configuration,
official-image selection, refreshable SSH alias management (D10), and
actionable status output.

Exit gate:

- Create, start, stop, restart, inspect, and destroy are idempotent.
- An interrupted creation can be retried safely.
- Existing unrelated Multipass or Hyper-V machines are never modified.
- Destructive operations resolve and display the exact target.
- The SSH alias survives a Windows reboot that changes the NAT subnet.
- Preflight refuses to proceed on a host without Hyper-V, without virtualization
  enabled, or without headroom for the VM alongside the still-running legacy
  box and WSL2.

### Phase 3: guest provisioning

Translate image contents into normal Ubuntu configuration. Install base
packages, native Docker Engine, native Tailscale, coding tools, language
servers, and systemd units. Establish version and update policy without
shadowing standard commands.

Exit gate:

- A clean VM reaches the same required tool availability as the container.
- Re-running provisioning produces no unintended changes (verified by diffing
  system state across two runs, not by inspection).
- Every long-running service is a native unit with restart and logging
  behavior.
- No custom process supervisor, PID file loop, or init stub exists.
- Reboot produces a healthy, reachable machine without a host login shell.
- Provisioning runs to completion on a box that has been up for weeks, not only
  on first boot.

### Phase 4: security and secret enrollment

Separate public configuration from secret enrollment, define the Windows
firewall posture, constrain the Tailscale node, and verify that no convenience
integration crosses the trust boundary.

Exit gate:

- Static instance metadata contains no reusable secret.
- No Windows drive, clipboard, device, SSH agent, or Docker socket is visible.
- The backup key is forced-command restricted and cannot obtain a shell.
- Tailscale access is least-privilege; recovery/rotation is documented.
- Guest compromise exercises demonstrate that host files and backup storage are
  not directly writable.
- `vibebox status` detects and loudly reports an added mount.

### Phase 5: operations parity

Rebuild backup, restore, update, health, diagnostics, and onboarding around the
VM boundary. Preserve useful command semantics while moving generic guest
commands under the Vibebox namespace.

Exit gate:

- Host-controlled backup and restore pass destructive recovery testing **using
  synthetic data only**.
- A clean rebuild plus restore recovers that synthetic data, with correct
  ownership by name (D9).
- Failed updates are diagnosable and have a documented rollback route.
- Health output distinguishes VM, SSH, Tailscale, Docker, disk, clock, mount
  posture, and individual service failures.

### Phase 6: VPS conformance and synthetic soak — **no user data**

This phase exists to answer the actual objective: *does this behave like a
standard Linux VPS?* It is run entirely on synthetic fixtures. The user's real
projects, dotfiles, credentials, and history stay in the legacy box and are not
copied anywhere.

Work:

- Run the conformance suite in `vm/conformance/` (see the matrix below) end to
  end on a freshly built VM.
- Install a set of real third-party packages using their **unmodified upstream
  Ubuntu instructions** and confirm none of them hit a Vibebox convention.
- Soak the VM for a defined period through ordinary host life: sleep/resume,
  host reboots, Windows updates, network changes, tailnet reconnects.
- Rebuild the VM from scratch at least once during the soak and confirm the
  rebuild is boring.

Exit gate:

- Every conformance check passes, or has an accepted, written exception.
- Host sleep/resume leaves a correct clock, live Tailscale, and working SSH.
- The VM is reachable after a full Windows restart with no manual step.
- No regression required a Vibebox-specific workaround to fix.

> ### 🛑 Gate A — STOP. Do not migrate user data.
>
> Phase 6 ends by **stopping and handing back to the user**. The next phase is
> the first one that touches real data, and it does not begin on the
> implementer's judgment.
>
> Produce a written report covering:
>
> - conformance results, including every exception and why it was accepted;
> - what soak revealed and what was fixed;
> - the exact data-migration inventory proposed — every path, what it is, and
>   whether it carries credentials;
> - what will deliberately **not** be migrated, and the re-authentication work
>   that implies;
> - a resource assessment for running both boxes concurrently;
> - known gaps and the honest risk list.
>
> Then wait. Phase 7 begins only on the user's explicit go-ahead. If the user
> says not yet, the VM stays as a synthetic test box and that is a fine
> resting state — it costs nothing to hold here.

### Phase 7: side-by-side migration with real data

Run the VM with a temporary machine and Tailscale name while the legacy Docker
Vibebox remains the daily driver. Migrate the agreed data inventory,
reauthenticate services, and exercise representative real projects.

Non-negotiable: **the legacy box is the source, and it is read-only in this
phase.** Data is copied, never moved. Nothing is deleted from legacy. The user
keeps working in legacy throughout; the VM is the one being evaluated.

Exit gate:

- Representative Node, Python, Go, Docker Compose, localhost server, and
  systemd workflows behave like ordinary Ubuntu.
- Existing projects build and test without Vibebox-specific changes.
- File watching, permissions, localhost resolution, bind mounts, and Docker
  volume paths follow native Linux expectations.
- Restored data has correct ownership, permissions, and git state.
- Backup and restore have been proven using data copied from the current box.
- The legacy environment is untouched and remains a working rollback path.

> ### 🛑 Gate B — STOP. Align the cutover with the user.
>
> Cutover is disruptive and identity-changing: the Tailscale node name moves,
> SSH host keys change, and the legacy box stops. It is scheduled with the
> user, not announced to them.
>
> Agree explicitly on:
>
> - **When** — a window the user picks, accounting for in-flight work,
>   deadlines, and travel. Not mid-sprint, not on a Friday by default.
> - **What moves** — the final delta sync of data changed since Phase 7, and
>   how long that takes.
> - **Identity handover** — the old Tailscale node is renamed or removed
>   *before* the VM claims the name, or Tailscale will silently suffix the new
>   node (`vibebox-1`) and every saved address will keep pointing at the dead
>   box. This is the most likely cutover-day failure.
> - **Rollback trigger** — what specifically constitutes "abort and go back,"
>   decided in advance rather than under pressure.
> - **Rollback window** — how long legacy stays runnable (default: 30 days,
>   confirmed with the user).
> - **Who runs it** — and what the user needs to be present for.
>
> Phase 8 begins only when that plan is agreed. An unanswered scheduling
> question is a blocker, not an excuse to pick a date.

### Phase 8: cutover

Execute the agreed plan. Take a final legacy backup, verify it restores, stop
the legacy environment, release the legacy Tailscale identity, assign the
intended Tailscale/SSH identity to the VM, and make the VM path the documented
default. Promote `vm/README.md` to the root README. Keep legacy artifacts
available for the agreed rollback window.

Exit gate:

- Local and tailnet SSH reach the VM at the documented names — verified from a
  second device, not only from the host.
- The final legacy backup has been restore-tested, not merely created.
- All required services survive reboot and host restart.
- The README and operator documentation describe only the VM path as current.
- A rollback rehearsal confirms the legacy environment can still be restored
  during the window.

### Phase 9: retire the legacy edition

After the rollback window closes, a stable soak, and at least one successful
real VM recovery, extract the standalone `gpu/` project (D14), then delete the
`legacy/` tree and the root forwarding shims.
Preserve migration notes, and tag the final legacy commit (e.g.
`legacy-final`) so the container edition remains recoverable from history
forever.

Retirement is a user decision, not an automatic consequence of the calendar.

---

## Adapter risk register

Each item is an assumption this plan makes about Multipass-on-Hyper-V that must
be **verified in Phase 1**. Each has a defined fallback, so a "no" is a known
cost rather than a surprise.

| # | Assumption to verify | If it fails |
|---|---|---|
| A1 | Instances are Gen 2 with Secure Boot usable under the MS UEFI CA template | Post-configure via Hyper-V PowerShell while stopped; if that fights Multipass, accept Secure Boot off with written rationale, or move to the direct Hyper-V adapter |
| A2 | Hyper-V console (`vmconnect`) reaches a login prompt on a Multipass instance | **Hard failure** (D11). Direct Hyper-V adapter, or a serial-console configuration in the guest |
| A3 | The instance can be made to autostart on Windows boot | Hyper-V `AutomaticStartAction`, or a host scheduled task running `vibebox start` |
| A4 | Stop action can be set to ACPI shutdown rather than Save | Accept Save state, and harden the guest for resume: aggressive timesync, Tailscale reconnect check in `vibebox status` |
| A5 | Disk can be grown after creation | Size generously at creation and document that disk is fixed for the instance's life; growth via Hyper-V + in-guest `growpart`/`resize2fs` |
| A6 | Snapshots of stopped instances work and restore cleanly | Rely solely on external backup for rollback; drop snapshots from the update flow |
| A7 | cloud-init user-data is delivered reliably and its failures are visible | Treat first boot as unreliable; make provisioning a separate re-runnable step invoked after boot (already the D-model) |
| A8 | Nested virtualization state is known | Document it. If off and a project needs KVM inside the VM, that is an explicit, separate decision — not something to discover mid-project |
| A9 | Mounts are absent by default and detectable | If undetectable, `vibebox status` cannot assert posture; downgrade the security claim in the docs to match reality |
| A10 | Multipass's own SSH key handling doesn't conflict with the managed `dev` key | Keep the two paths fully separate: `ubuntu`/Multipass for rescue, `dev`/managed key for work |
| A11 | GPU is genuinely unreachable from a Hyper-V Linux guest on this host's Windows edition (D14) | If it turns out to be reachable, that is good news — but treat enabling it as a separate, scoped decision, not an in-flight scope change |
| A12 | Tailscale Services is available on this tailnet's plan, and the policy-file/grant syntax needed to advertise a service is understood (D15) | Fall back to one userspace `tailscaled` per name, driven by a systemd template unit from the same registry — the registry and `vibebox tailnet` surface stay identical either way |

---

## Validation matrix

### Linux authenticity

- `ps -p 1` identifies systemd.
- `systemctl`, `journalctl`, `loginctl`, timers, service dependencies, and
  restart policies behave normally.
- No `/.dockerenv`, `WSL_INTEROP`, WSL kernel signature, shared container cgroup,
  or Windows filesystem mount exists.
- `systemd-detect-virt` reports a hypervisor, not a container. Hyper-V
  virtualization metadata is accepted.
- `/etc/hosts`, DNS, hostname, and `localhost` are guest-owned and stable across
  service and host reboots.
- cgroup v2 is present and delegable; `systemd-run --scope` with resource
  limits works for an unprivileged user.
- `sysctl -w` works for the settings real applications tune — notably
  `fs.inotify.max_user_watches`, `vm.max_map_count`, `net.core.somaxconn` — and
  persists via `/etc/sysctl.d`.
- `ulimit -n` is raisable per-service and per-login as on a normal host.
- Kernel modules can be loaded; AppArmor is active; `auditd` can run.
- Swap exists and is configured deliberately.
- Persistent journald survives reboot.
- `loginctl enable-linger` works and user-level timers/services survive logout.
- The full `apt full-upgrade` + reboot cycle completes unattended, and
  `unattended-upgrades` runs without tripping on a Vibebox convention.

### VPS conformance (the compatibility gate)

Run each with its **unmodified upstream instructions**, as a stranger would:

- Docker Engine from Docker's official apt repository.
- Tailscale from Tailscale's official install path.
- A database installed as a systemd service (e.g. PostgreSQL from apt),
  including socket activation and restart-on-failure.
- nginx or Caddy binding :80/:443, reachable over the tailnet.
- Node via NodeSource or `nvm`, and Python via `apt` + `venv` — neither
  intercepted by a wrapper.
- A hand-written unit with `Restart=on-failure`, `After=`, `WantedBy=`, and an
  `EnvironmentFile`, proven to restart after `kill -9`.
- A `systemd` timer, verified by `systemctl list-timers` and an actual firing.
- A `journalctl -u <svc> -f` session showing live logs.
- An `ssh -R`/`-L` tunnel and `ss -tlnp` reporting truthful listener state.

Any check that requires a Vibebox-specific accommodation is a defect in the VM
edition, not a documentation item.

### Docker behavior

- `docker info` reports a daemon running in the guest.
- Bind paths refer to guest paths.
- Project containers stop with the VM and do not become hidden siblings on
  Docker Desktop.
- Compose networking and volumes survive expected VM lifecycle operations.
- A container publishing a port is reachable from the host and over the tailnet
  as expected.

### Service behavior

- Services start through systemd, log to the journal or declared log targets,
  restart on failure, stop cleanly, and expose meaningful status.
- Installing third-party software using its documented Ubuntu instructions does
  not encounter a Vibebox stub or supervisor convention.

### Host lifecycle and time

- Host sleep → resume: clock offset within tolerance, Tailscale reconnects,
  SSH works, no timer stampede.
- Host reboot: the VM comes back without a manual step and the SSH alias is
  correct even if the NAT subnet changed.
- Ungraceful host power loss: the guest filesystem survives and boots.

### Isolation

- No host directories or backup destinations are mounted, and `vibebox status`
  proves it.
- No host or forwarded private key is readable.
- Windows firewall policy limits VM-to-host reachability.
- Tailscale policy limits lateral movement.
- The backup key cannot obtain an interactive shell.
- Destroying or corrupting the guest disk does not alter Windows user files.

### Recovery

- A destroyed VM can be recreated from the official image and repository state.
- User data can be restored without restoring the old OS or toolchain.
- Restored files are owned by `dev` by name, not by a stale numeric UID.
- A restore cannot overwrite Windows paths or another named VM.
- Credentials omitted from backup have a clear re-enrollment path.
- The rescue console works when sshd is stopped.

---

## Documentation changes

At cutover, `vm/README.md` is promoted to root and replaces the container
mental model with:

- Supported Windows and Hyper-V prerequisites.
- The distinction between host control plane, Ubuntu guest, and project
  containers.
- VM lifecycle, SSH/Tailscale access, and the rescue console.
- Standard service management and Docker behavior.
- Security boundary and prohibited integrations.
- Backup, restore, rebuild, update, and recovery.
- Migration from the final legacy container release.
- A concise troubleshooting guide based on normal Ubuntu diagnostics.

`legacy/NO_SYSTEMD.md` is deleted at retirement rather than rewritten: the
absence of systemd will no longer be a Vibebox concept.

---

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Multipass hides needed Hyper-V controls | Adapter risk register verified in Phase 1; `vm/host/` is thin and replaceable by direct Hyper-V automation without touching `vm/guest/` |
| No rescue console when SSH breaks | D11: Hyper-V console proven in Phase 1 as a hard gate |
| Clock drift after host sleep breaks TLS and timers | D13: hv_utils + timesyncd, with sleep/resume in the conformance suite |
| Unstable NAT IP breaks `ssh vibebox` | D10: Tailscale name is the documented address; local alias is regenerated on every start/status |
| UID mismatch silently corrupts restored ownership | D9: name-based ownership mapping, tested; restore refuses on detected mismatch |
| Tailscale name collision at cutover yields `vibebox-1` | Gate B requires releasing the legacy node identity before the VM claims it |
| The VM edition slowly re-absorbs legacy cruft | `vm/` may not reference `legacy/`; enforced by a CI check |
| Legacy breaks while attention is on the VM | Legacy is frozen and verified working at Phase 0 exit; security fixes only |
| Both boxes running exhausts host RAM/disk | Phase 2 preflight checks headroom for VM + legacy container + WSL2 concurrently; Gate A reports the assessment |
| Data migrated before the platform is trustworthy | Gate A is a hard stop; Phases 0–6 use synthetic data exclusively |
| Cutover lands at a bad moment for the user | Gate B schedules it with the user, with a pre-agreed rollback trigger |
| Moving image aliases reduce reproducibility | Pin the Ubuntu release, record image/version facts, verify downloads, record resolved tool versions |
| Secrets leak through cloud-init | Prohibit secrets in static metadata; explicit post-boot enrollment |
| Backup pull key becomes a root-equivalent remote shell | Forced `command=`, no pty, no forwarding |
| Backups are mid-write and unrestorable | Optional quiesce hooks; otherwise archives are labeled crash-consistent |
| Multipass's SYSTEM service can enable mounts later | Restrict who can drive Multipass; `vibebox status` asserts zero mounts |
| VM compromise reaches Windows over the network | No host integrations, least-privilege Tailscale policy, restrictive Windows firewall rules |
| Full VM disk grows or corrupts | Monitor disk health, host-controlled user-data backups, prove clean rebuild recovery |
| Migration imports container-era state | Default to selective data migration and fresh authentication |
| A tailnet name exists only as a once-run command and is lost on rebuild | D15: names live in a git-tracked registry, reconciled idempotently |
| Tailscale Services unavailable or plan-gated | A12 fallback to per-name userspace `tailscaled`, behind the same registry and command surface |
| GPU is unavailable in the VM | D14: acknowledged up front, not discovered at cutover; GPU work stays on WSL2 and `vibebox status` reports no GPU |
| Retiring `legacy/` silently destroys the GPU path | Phase 9 is blocked until a standalone `gpu/` project exists and has run a real GPU job |
| Tool installation remains brittle | Separate required from optional tools, pin/record versions, fail required capabilities loudly, test clean builds regularly |
| Customization becomes another bespoke distribution | Standard commands untouched; the VPS conformance suite is the gate |

---

## Open decisions for the implementation session

Everything the user can decide in advance has been decided and recorded in the
work-orders documents. What remains is **empirical** — it cannot be resolved by
discussion, only by running Phase 1 against the real host:

1. The twelve rows of the adapter risk register (A1–A12): Secure Boot template,
   rescue console, autostart, stop action, disk growth, snapshots, cloud-init
   reliability, nested-virt state, mount detectability, Multipass key handling,
   GPU reachability, and Tailscale Services availability.
2. Following from A1–A10: whether Multipass remains the permanent host adapter
   or direct Hyper-V replaces it.

Two items are deliberately deferred to a gate rather than being open questions:

3. The compatibility repository suite — candidates proposed in the Gate A
   report, chosen by the user then.
4. The cutover window and rollback duration — agreed at Gate B.

Previously open, now closed: optional-tool split (part 1 §2.4), VM resources
(§2.1, adjustable via `vibebox.env`), `ufw` posture (§2.3), nested
virtualization (§2.1, off), archive retention (§2.6), GPU (D14), multiple
tailnet names (D15), storage layout and credential-migration exceptions
(part 2 §3.2).

---

## Definition of done

The transition is complete when a clean Windows host can create Vibebox from an
official Ubuntu image and repository configuration; the resulting guest passes
the VPS conformance suite using unmodified upstream instructions; Windows
exposes no drives, credentials, devices, or management sockets to it;
representative projects require no Vibebox-specific workarounds; backup and
destructive recovery have been demonstrated against real data; the user
explicitly approved both the data migration and the cutover; and the legacy
container edition has been retired by the user's decision after its rollback
window closed, with its final state preserved in Git history.
