#!/bin/sh
export DELEGATE_LABEL="agy-backup-identity"
exec 'agy' '-i' 'Read and execute the spec at .delegate/spec.md' '--add-dir' '/Users/hgill/projects/vibebox-worktrees/agy-backup-identity' '--dangerously-skip-permissions' '--model' 'Gemini 3.1 Pro (High)'
