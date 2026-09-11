#!/usr/bin/env bash

set -Eeuo pipefail

source /opt/vibebox/read-env.sh
read_vibebox_env /etc/vibebox/vibebox.env

json_escape() {
    python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().rstrip("\n")))'
}

service_json() {
    local units=("$@")
    local unit active sub
    for unit in "${units[@]}"; do
        active=$(systemctl is-active "$unit" 2>/dev/null || true)
        sub=$(systemctl show "$unit" --property=SubState --value 2>/dev/null || true)
        [[ -n "$active" ]] || active=inactive
        [[ -n "$sub" ]] || sub=dead
        printf '%s\t%s\t%s\n' "$unit" "$active" "$sub"
    done
}

root_stats=$(df -P / | awk 'NR==2 {gsub(/%/,"",$5); print $5}')
uptime_seconds=$(awk '{print int($1)}' /proc/uptime)
sync_state=$(timedatectl show --property=NTPSynchronized --value 2>/dev/null || true)
[[ "$sync_state" == "yes" ]] && synced=true || synced=false
offset_usec=$(timedatectl show-timesync --property=OffsetUSec --value 2>/dev/null || true)
[[ "$offset_usec" =~ ^-?[0-9]+$ ]] || offset_usec=
tailscale_state=$(tailscale status --json 2>/dev/null || printf '{}')
tailnet_state=$(/opt/vibebox/tailnet-status.sh 2>/dev/null || printf '{"node":"vibebox","services":[],"drift":[]}')

python3 - "$root_stats" "$uptime_seconds" "$synced" "$offset_usec" "$tailscale_state" "$tailnet_state" <<'PY'
import json
import os
import subprocess
import sys

disk_used = int(sys.argv[1])
uptime = int(sys.argv[2])
synced = sys.argv[3] == "true"
try:
    clock_offset = abs(int(sys.argv[4])) / 1_000_000
except (TypeError, ValueError):
    clock_offset = 0 if synced else None
try:
    tailscale = json.loads(sys.argv[5])
except json.JSONDecodeError:
    tailscale = {}
try:
    tailnet = json.loads(sys.argv[6])
except json.JSONDecodeError:
    tailnet = {"node": "vibebox", "services": [], "drift": []}

def version(tool):
    try:
        args = ["go", "version"] if tool == "go" else [tool, "--version"]
        result = subprocess.run(args, text=True, capture_output=True, timeout=10)
        return result.returncode == 0, (result.stdout or result.stderr).splitlines()[0] if result.returncode == 0 else ""
    except (OSError, subprocess.SubprocessError):
        return False, ""

required = {}
for tool in ("claude", "codex", "bun", "node", "go", "gh", "docker"):
    required[tool] = version(tool)[0]
optional = {}
configured_optional = [item.strip() for item in os.environ.get("TOOLS_OPTIONAL", "").split(",") if item.strip()]
for tool in configured_optional:
    optional[tool] = version(tool)[0]

service_names = [
    "ssh.service",
    "tailscaled.service",
    "docker.service",
    "systemd-timesyncd.service",
    "vibebox-grow-disk.service",
    "vibebox-tailnet.service",
]
for prefix in ("vibebox-hermes-gateway@", "vibebox-droid-daemon@", "vibebox-hermes-webui@"):
    for unit in subprocess.run(
        ["systemctl", "list-units", "--all", "--no-legend", f"{prefix}*.service"],
        text=True, capture_output=True
    ).stdout.splitlines():
        if unit:
            service_names.append(unit.split()[0])

services = []
for unit in service_names:
    active = subprocess.run(["systemctl", "is-active", unit], text=True, capture_output=True).stdout.strip()
    sub = subprocess.run(["systemctl", "show", unit, "--property=SubState", "--value"], text=True, capture_output=True).stdout.strip()
    services.append({"unit": unit, "active": active == "active", "sub": sub or "dead"})

tailscale_self = tailscale.get("Self", {})
tailscale_info = {
    "state": "Running" if tailscale_self else "Stopped",
    "name": tailscale_self.get("HostName", ""),
    "ip": (tailscale_self.get("TailscaleIPs") or [""])[0],
}
print(json.dumps({
    "diskUsedPct": disk_used,
    "uptimeSec": uptime,
    "clock": {"offsetSec": clock_offset, "synced": synced},
    "net": {"tailscale": tailscale_info},
    "tailnet": tailnet,
    "services": services,
    "tools": {
        "required": {"ok": sum(required.values()), "missing": [k for k,v in required.items() if not v]},
        "optional": {"ok": sum(optional.values()), "missing": [k for k,v in optional.items() if not v]},
    },
}, separators=(",", ":")))
PY
