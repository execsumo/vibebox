# VM operations

The host entry point is `vm/host/vibebox.ps1`. Run it from **PowerShell 7
(`pwsh`) as Administrator** on the Windows host. Windows PowerShell 5.1 is not
supported. The guest remains usable with ordinary Ubuntu commands:
`systemctl`, `journalctl`, `apt`, `ss`, and the native Docker CLI.

Hyper-V identity checks require elevation for `create`, `start`, `stop`,
`restart`, `config apply`, `destroy`, and `rebuild`. `VM_AUTOSTART=true`
configures Hyper-V to start the VM automatically when Windows boots, so manual
startup is normally unnecessary.

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
.\vm\host\vibebox.ps1 config diff
.\vm\host\vibebox.ps1 config apply
```

CPU, memory, and disk changes require a stopped VM. `-Restart` performs the
stop/apply/start sequence. Hyper-V Dynamic Memory uses
`VM_MEMORY_MIN` / `VM_MEMORY_STARTUP` / `VM_MEMORY` as its minimum, startup,
and maximum bounds. Disk growth is applied to the VHDX and the guest grows
its root filesystem at boot. Disk shrink and create-time-only changes are
refused.

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

`vibebox update` updates the guest toolchain according to
`TOOLS_UPDATE_POLICY`; it does not silently change the OS contract.
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
