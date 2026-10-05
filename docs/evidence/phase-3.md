# Phase 3 evidence: guest provisioning

Status: implementation present; no guest run is claimed.

The provisioning driver is grouped into base policy, Docker, Tailscale,
toolchain, and native systemd services. It installs persistent journald,
security-only unattended upgrades without auto-reboot, timesync, swap, SSH
hardening, native Docker, and the required/optional tool verification policy.
Tailnet names are declarative files under `guest/tailnet.d/` and reconcile
through one native Tailscale node and the `vibebox-tailnet.service` unit.

The required two-run system-state diff, reboot readiness budget, and
multi-day re-run must be recorded on a real proof VM. This phase does not read
or copy user data. A12 also requires the tailnet administrator to grant the
Services policy before the HTTPS name can be proven.
