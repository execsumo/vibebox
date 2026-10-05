# Phase 5 evidence: operations parity

Status: implementation present; synthetic destructive testing is pending.

The host backup path is pull-only, hook-aware, name-bound, and has a dry-run
restore path. Restore stops a running VM for maintenance, extracts without
numeric ownership, and maps ownership to the configured login name.
The declarative tailnet registry is restored by one `vibebox tailnet apply`
after rebuild; Tailscale policy grants remain an explicit administrator step.

The required synthetic tree, UID mismatch refusal, failing-hook behavior,
update rollback, and rebuild/restore checks must be run only after the proof
VM is available. No real user data is in scope.
