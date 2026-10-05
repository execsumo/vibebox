# Phase 2 evidence: host lifecycle foundation

Status: implementation present; runtime validation is blocked until
Multipass and Hyper-V are available.

Implemented contracts include:

- shared `vibebox.env` parsing with CLI precedence;
- host preflight and concurrent RAM/disk headroom checks;
- idempotent create/start/stop/restart;
- intent markers for interrupted create recovery;
- exact managed-instance checks before destructive actions;
- managed SSH alias refresh on start, status, and ssh;
- config show/diff/apply with create-time and disk-shrink refusals;
- status JSON with explicit `gpu: none` and mount drift failure.

The resource-bump walkthrough, Windows reboot alias refresh, unrelated-instance
isolation, and `status -Json` schema still require the host gate.
