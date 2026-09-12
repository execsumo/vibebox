# Vibebox VM edition

The VM edition is a clean Ubuntu 24.04 guest managed from Windows through
`host/vibebox.ps1`. It uses Multipass with Hyper-V, cloud-init for the
non-secret first boot, and native Ubuntu systemd services.

## Prerequisites

Run on the Windows host in **PowerShell 7 (`pwsh`) as Administrator**:

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

Windows PowerShell 5.1 is not supported. Open an elevated PowerShell 7 window
by running `pwsh`, then run the commands below. Hyper-V identity checks require
elevation for the lifecycle commands (`create`, `start`, `stop`, `restart`,
`config apply`, `destroy`, and `rebuild`). With `VM_AUTOSTART=true`, Hyper-V
starts the VM automatically when Windows boots.

## Lifecycle

```powershell
.\vm\host\vibebox.ps1 create
.\vm\host\vibebox.ps1 status
.\vm\host\vibebox.ps1 ssh
.\vm\host\vibebox.ps1 stop
.\vm\host\vibebox.ps1 start
```

## Configuration changes

Edit the ignored host configuration file:

```powershell
notepad .\vm\vibebox.env
```

Then inspect and apply changes from elevated PowerShell 7:

```powershell
.\vm\host\vibebox.ps1 config show
.\vm\host\vibebox.ps1 config diff
.\vm\host\vibebox.ps1 config apply
```

CPU, memory, and disk changes require a stopped VM. Use `-Restart` with
`config apply` to stop, apply, and start automatically. The dynamic-memory
settings are `VM_MEMORY_MIN`, `VM_MEMORY_STARTUP`, and `VM_MEMORY`.

The VM disk is grow-only. `destroy` and `rebuild` require `-Confirm` and
refuse unmanaged instances.

The primary remote address is the enrolled Tailscale name. The local SSH
alias is regenerated from the current NAT address on `start`, `status`, and
`ssh`. `console` opens the Hyper-V rescue path when SSH is unavailable.

## Connecting without elevation

After the managed local alias has been generated, connect without an elevated
PowerShell session:

```powershell
ssh vibebox-vm
```

The `vibebox ssh` wrapper performs Hyper-V lifecycle checks and therefore uses
an elevated PowerShell 7 session. Direct `ssh` does not.

After Tailscale enrollment, connect from any tailnet device with the guest
user and its Tailscale MagicDNS name:

```powershell
ssh dev@<tailnet-name>
```

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
