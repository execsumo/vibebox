#!/usr/bin/env bash

set -u
source "$(dirname "$0")/../../lib.sh"

id=32-published-port
docker run -d --rm --name vibebox-conformance-http -p 18080:80 nginx:alpine >/dev/null 2>&1 || {
    fail "$id" "guest Docker can publish a port"
    exit 1
}
trap 'docker stop vibebox-conformance-http >/dev/null 2>&1 || true' EXIT
for _ in $(seq 1 10); do
    sleep 1
    curl -fsS http://127.0.0.1:18080 >/dev/null 2>&1 || continue
    guest_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
    [[ "$guest_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
    curl -fsS --max-time 5 "http://$guest_ip:18080" >/dev/null 2>&1 && {
        ok "$id" "guest Docker published port is reachable through the guest network address"
        exit 0
    }
done
fail "$id" "published guest container port responds through the guest network address"
exit 1
