#!/usr/bin/env bash

set -u
source "$(dirname "$0")/../../lib.sh"

id=41-tailnet
[[ -f /etc/vibebox/tailnet.d/hermes.conf ]] || {
    fail "$id" "tailnet registry contains the Hermes service"
    exit 1
}
if ! tailscale status --json >/dev/null 2>&1; then
    skip "$id" "Tailscale enrollment and Services policy are user-controlled"
    exit 77
fi
systemctl start vibebox-tailnet.service || {
    fail "$id" "tailnet service reconciliation succeeds"
    exit 1
}
service_json=$(/opt/vibebox/tailnet-status.sh) || {
    fail "$id" "tailnet status reports live Services"
    exit 1
}
printf '%s' "$service_json" | python3 -c '
import json,sys
value=json.load(sys.stdin)
assert any(x.get("name")=="hermes" and x.get("inRegistry") and x.get("live") for x in value["services"])
' || {
    fail "$id" "Hermes registry entry is live in tailnet Services"
    exit 1
}
tailnet_suffix=$(tailscale status --json | python3 -c '
import json,sys
self_info=json.load(sys.stdin).get("Self", {})
name=(self_info.get("DNSName") or "").rstrip(".")
parts=name.split(".", 1)
assert len(parts) == 2
print(parts[1])
') || {
    fail "$id" "Tailscale publishes a MagicDNS suffix for the Service"
    exit 1
}
if ! curl --fail --silent --show-error --max-time 15 \
    --output /dev/null "https://hermes.$tailnet_suffix/"; then
    fail "$id" "Hermes Service has a valid certificate and responds over HTTPS"
    exit 1
fi
ok "$id" "tailnet registry reconciles with live Service, certificate, and HTTPS reachability"
