#!/usr/bin/env bash

set -u
source "$(dirname "$0")/../../lib.sh"

id=20-upstream-tools
for tool in node python3 go docker tailscale; do
    require_cmd "$tool" "$id" || exit 1
done
node --version >/dev/null 2>&1 || { fail "$id" "Node runs through its upstream binary"; exit 1; }
python3 -m venv /tmp/vibebox-conformance-venv || { fail "$id" "Python venv works"; exit 1; }
/tmp/vibebox-conformance-venv/bin/python -c 'import sys; assert sys.prefix != sys.base_prefix' ||
    { fail "$id" "Python venv is isolated"; exit 1; }
rm -rf /tmp/vibebox-conformance-venv
if [[ ! -f /etc/apt/sources.list.d/nodesource.list ]]; then
    fail "$id" "NodeSource is a normal apt source"
    exit 1
fi
ok "$id" "Node, Python venv, Go, Docker, and Tailscale use normal guest paths"
