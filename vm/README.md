# Vibebox VM edition

The VM edition is a clean Ubuntu 24.04 guest managed from Windows through
`host/vibebox.ps1`. It uses Multipass with Hyper-V, cloud-init for the
non-secret first boot, and native Ubuntu systemd services.

## Prerequisites

Run on the Windows host in PowerShell 7:

- Hyper-V enabled and an elevated shell available.
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

## Lifecycle

```powershell
.\vm\host\vibebox.ps1 create
.\vm\host\vibebox.ps1 status
.\vm\host\vibebox.ps1 ssh
.\vm\host\vibebox.ps1 stop
.\vm\host\vibebox.ps1 start
```

Edit `vm/vibebox.env` for resource changes, then use `config diff` and
`config apply`. The VM disk is grow-only. `destroy` and `rebuild` require
`-Confirm` and refuse unmanaged instances.

The primary remote address is the enrolled Tailscale name. The local SSH
alias is regenerated from the current NAT address on `start`, `status`, and
`ssh`. `console` opens the Hyper-V rescue path when SSH is unavailable.

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
