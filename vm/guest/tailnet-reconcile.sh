#!/usr/bin/env bash

set -Eeuo pipefail

registry_dir=${VIBEBOX_TAILNET_REGISTRY:-/etc/vibebox/tailnet.d}
[[ -d "$registry_dir" ]] || exit 0
if ! tailscale status --json >/dev/null 2>&1; then
    printf 'Tailscale is not enrolled; tailnet Services will reconcile after enrollment\n'
    exit 0
fi

declare -A desired=()
funnel_desired=0
for file in "$registry_dir"/*.conf; do
    [[ -f "$file" ]] || continue
    SERVICE= TARGET= PORT= MODE=
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "${line//[[:space:]]/}" || "$line" == \#* ]] && continue
        key=${line%%=*}
        value=${line#*=}
        case "$key" in
            SERVICE) SERVICE=$value ;;
            TARGET) TARGET=$value ;;
            PORT) PORT=$value ;;
            MODE) MODE=$value ;;
            *) printf 'unknown tailnet registry key in %s\n' "$file" >&2; exit 1 ;;
        esac
    done < "$file"
    [[ "${SERVICE:-}" =~ ^[a-z][a-z0-9-]{0,62}$ ]] || {
        printf 'invalid tailnet service in %s\n' "$file" >&2
        exit 1
    }
    [[ "${TARGET:-}" =~ ^https?://127\.0\.0\.1:[0-9]+$ ]] || {
        printf 'tailnet target must be a loopback HTTP(S) URL in %s\n' "$file" >&2
        exit 1
    }
    [[ "${PORT:-}" =~ ^[0-9]+$ && "$PORT" -ge 1 && "$PORT" -le 65535 ]] || {
        printf 'invalid tailnet port in %s\n' "$file" >&2
        exit 1
    }
    [[ "${MODE:-serve}" == "serve" || "${MODE:-}" == "funnel" ]] || {
        printf 'tailnet mode must be serve or funnel in %s\n' "$file" >&2
        exit 1
    }
    desired["$SERVICE"]=1
    if [[ "$MODE" == "funnel" ]]; then
        # Funnel is node-scoped in the upstream CLI; it does not accept the
        # Service selector used by `tailscale serve`.
        ((funnel_desired += 1))
        if (( funnel_desired > 1 )); then
            printf 'only one node-scoped Funnel entry can be active\n' >&2
            exit 1
        fi
        tailscale funnel --https="$PORT" "$TARGET"
    else
        tailscale serve --service="svc:$SERVICE" --https="$PORT" "$TARGET"
    fi
done

if (( funnel_desired == 0 )); then
    # Funnel is node-scoped, so reset it when no registry entry owns it.
    tailscale funnel reset || true
fi

# Remove services that are live but no longer declared. The CLI/API is
# intentionally kept here, not hidden behind a replacement tailscale command.
status=$(tailscale serve status --json 2>/dev/null || printf '{}')
while IFS= read -r name; do
    [[ -n "$name" && -z "${desired[$name]+yes}" ]] || continue
    tailscale serve clear "svc:$name" || true
done < <(printf '%s' "$status" | python3 -c '
import json,sys
try:
    value=json.load(sys.stdin)
except Exception:
    value={}
def walk(v):
    if isinstance(v,dict):
        for k,x in v.items():
            if isinstance(k,str) and k.startswith("svc:"):
                print(k.removeprefix("svc:"))
            if isinstance(k,str) and k.lower() in {"service","servicename","service_name"}:
                if isinstance(x,str):
                    print(x.removeprefix("svc:"))
                elif isinstance(x,dict):
                    for field in ("Name","name","Service","service"):
                        if isinstance(x.get(field),str):
                            print(x[field].removeprefix("svc:"))
            if isinstance(k,str) and k.lower()=="services" and isinstance(x,dict):
                for service in x:
                    if isinstance(service,str) and service.startswith("svc:"):
                        print(service.removeprefix("svc:"))
            walk(x)
    elif isinstance(v,list):
        for x in v: walk(x)
walk(value)
')
