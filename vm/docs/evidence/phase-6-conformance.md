# Phase 6 conformance evidence

Status: not run. The host has no Multipass installation, so no conformance
pass, failure, or skip count is asserted.

`vm/conformance/run.ps1` is the host driver. It runs every guest check over
Multipass SSH and every host check locally, emits `ok`, `not ok`, or `skip`
records, and returns validation exit code 5 when any check fails.

Run it on a fresh synthetic VM and attach the JSON output here. Every skip
must retain its reason; in particular, interactive console and host
sleep/resume checks cannot be silently treated as passes.
