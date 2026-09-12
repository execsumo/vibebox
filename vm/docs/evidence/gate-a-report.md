# Gate A report

Status: **blocked; Gate A has not been reached.**

This report is intentionally an honest holding document. The VM repository
implementation exists, but the host proof and synthetic soak have not run
because the current shell cannot access Hyper-V with elevation and has 5.94 GB
free against the 8 GB requirement for the configured 4 GB VM plus reserve.
Multipass 1.16.3 is installed and detected. No real user data, credentials,
dotfiles, history, or projects were read or moved.

## 1. Conformance results

No pass/fail/skip counts are claimed. Run
`vm/conformance/run.ps1 -Json` on a fresh synthetic VM and paste its output
here. A skip is not an acceptance; each one needs a reason and a proposed
exception for user review.

## 2. Soak findings

Not started. The required seven-day run, three host reboots, five
sleep/resume cycles, full rebuild, clock tolerance, Tailscale reconnect, and
zero-manual-step restart remain open.

## 3. Proposed data inventory

No inventory is proposed because the current delegation has not received an
approved list of real paths. The next phase must name every source path,
approximate size, credential risk, and migrate decision before copying
anything.

| Source path | Contents | Approximate size | Credential-bearing | Migrate |
|---|---|---:|---:|---|
| Not supplied | No real data inspected | Unknown | Unknown | No decision |

## 4. Deliberate exclusions

Until the user approves Gate A and a path-level inventory, exclude all real
projects, dotfiles, shell history, agent state, GitHub credentials, Tailscale
state, Hermes credentials, API keys, private SSH keys, caches, build outputs,
machine binaries, and container-era service state. Those exclusions imply
fresh enrollment and regenerated keys later.

The current work order records two explicit later exceptions that must be
reconfirmed before Phase 7: E1 carries `~/.claude` in full, including
credentials, and E2 copies the existing SSH private key. Tailscale state is
still never copied.

## 5. Resource assessment

Not measured with both the VM, the current container, WSL2, and Docker Desktop
resident. `vibebox doctor` implements a conservative headroom check, but its
result must be recorded on the real host.

## 5a. GPU workload inventory

Not collected. No GPU workload was inspected. The VM remains CPU-only by
policy; the user must identify which existing workloads stay on the Windows
Docker Desktop/WSL2 path before migration approval.

## 6. Compatibility repo candidates

No repositories were read or proposed. The user must select candidates after
the synthetic VPS conformance run.

## 7. Honest risk list

- Multipass and Hyper-V adapter behavior, especially the rescue console, are
  unverified.
- The actual guest tool installers and optional CLI versions have not run.
- Backup/restore has not been tested against even synthetic data.
- Host sleep/resume, autostart, NAT address refresh, and Windows restart have
  not been observed.

**Stop condition:** do not begin Phase 7. Gate A requires the user's explicit
approval after the evidence above is complete.
