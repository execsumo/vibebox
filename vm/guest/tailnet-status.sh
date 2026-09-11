#!/usr/bin/env bash

set -Eeuo pipefail

registry_dir=${VIBEBOX_TAILNET_REGISTRY:-/etc/vibebox/tailnet.d}
python3 - "$registry_dir" <<'PY'
import json
import pathlib
import subprocess
import sys

registry = []
directory = pathlib.Path(sys.argv[1])
for path in sorted(directory.glob("*.conf")):
    values = {}
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
    if values.get("SERVICE"):
        registry.append({
            "name": values["SERVICE"],
            "target": values.get("TARGET", ""),
            "port": int(values.get("PORT", "443")),
            "mode": values.get("MODE", "serve"),
            "inRegistry": True,
        })

try:
    raw = subprocess.run(
        ["tailscale", "serve", "status", "--json"],
        text=True, capture_output=True, check=False, timeout=10
    ).stdout
    live_json = json.loads(raw or "{}")
except (OSError, subprocess.SubprocessError, json.JSONDecodeError):
    live_json = {}

try:
    funnel_raw = subprocess.run(
        ["tailscale", "funnel", "status", "--json"],
        text=True, capture_output=True, check=False, timeout=10
    ).stdout
    funnel_json = json.loads(funnel_raw or "{}")
except (OSError, subprocess.SubprocessError, json.JSONDecodeError):
    funnel_json = {}

live_names = set()
def add_name(value):
    if isinstance(value, str):
        value = value.removeprefix("svc:")
        if value and value != "localhost":
            live_names.add(value)

def collect(value, key=""):
    if isinstance(value, dict):
        for key, item in value.items():
            if isinstance(key, str) and key.startswith("svc:"):
                add_name(key)
            if isinstance(key, str) and key.lower() in {"service", "servicename", "service_name"}:
                if isinstance(item, str):
                    add_name(item)
                elif isinstance(item, dict):
                    for item_key in ("Name", "name", "Service", "service"):
                        if item_key in item:
                            add_name(item[item_key])
            if isinstance(key, str) and key.lower() == "services" and isinstance(item, dict):
                for item_key in item:
                    if isinstance(item_key, str) and (item_key.startswith("svc:") or item_key.isidentifier()):
                        add_name(item_key)
            collect(item, key)
    elif isinstance(value, list):
        for item in value:
            collect(item, key)
collect(live_json)

funnel_live = any(
    isinstance(funnel_json.get(section), dict) and bool(funnel_json[section])
    for section in ("Web", "TCP")
)
if funnel_live and not any(item["mode"] == "funnel" for item in registry):
    registry.append({"name": "node-funnel", "target": "", "port": None, "mode": "funnel", "live": True, "inRegistry": False})
for item in registry:
    item["live"] = funnel_live if item["mode"] == "funnel" else item["name"] in live_names
for name in sorted(live_names - {item["name"] for item in registry}):
    registry.append({"name": name, "target": "", "port": None, "mode": "", "live": True, "inRegistry": False})

print(json.dumps({
    "node": "vibebox",
    "services": registry,
    "drift": [item["name"] for item in registry if item.get("live") != item.get("inRegistry")],
}, separators=(",", ":")))
PY
