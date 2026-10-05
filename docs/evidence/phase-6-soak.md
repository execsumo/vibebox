# Phase 6 synthetic soak evidence

Status: not started.

The soak requires seven consecutive days, at least three host reboots, five
sleep/resume cycles, one full rebuild, a post-resume clock offset of at most
two seconds, and a no-manual-step Windows restart. Record each cycle's
timestamp, VM state, Tailscale state, SSH result, clock offset, and any repair.
Only synthetic fixtures are allowed before Gate A.
