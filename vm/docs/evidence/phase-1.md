# Phase 1 evidence: architecture proof

Status: blocked on the host prerequisite gate.

The repository contains the host preflight implementation and the conformance
checks, but this environment reported:

```text
PowerShell 7
Git 2.55.0.windows.3
OpenSSH_for_Windows_9.5p1
Windows 10.0.22631
Multipass 1.16.3+win
Multipass daemon 1.16.3+win
Host preflight blockers:
- administrator: current shell is not elevated
- hyperv: Hyper-V authorization is unavailable to this shell
- hyperv-feature: feature query is unavailable without the required permission
- resource-headroom-memory: 5.94 GB free; 8 GB required by the 4 GB VM plus reserve
```

No proof instance was created, no host reboot was requested, and no legacy
container was touched. Therefore no row A1-A12 is claimed as verified, and
the A2 console hard gate remains open. Re-run from an elevated PowerShell
session after freeing sufficient memory:

```powershell
.\vm\host\vibebox.ps1 doctor
.\vm\host\vibebox.ps1 create -Name vibebox-proof
.\vm\conformance\run.ps1 -Name vibebox-proof -Json
```

The evidence must include the commands and verbatim output for the Windows
edition, Hyper-V assignable devices, Multipass GPU help, exact VM generation,
mount list, autostart/stop policy, disk growth, snapshot behavior, nested
virtualization, Tailscale Services availability and policy (A12), and the
`vmconnect.exe` test with SSH stopped. Destroy only
the exact proof instance after the evidence is captured.
