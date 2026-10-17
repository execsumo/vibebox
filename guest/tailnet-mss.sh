#!/usr/bin/env bash

# Clamp the TCP MSS on the tailnet interface. Tailscale's MTU is 1280, so peers
# negotiate 1240-byte segments, but some client paths (double NAT, router
# hairpinning) silently drop anything over roughly 1210 bytes. A full-size
# segment then vanishes and the connection stalls -- for SSH, at
# "expecting SSH2_MSG_KEX_ECDH_REPLY", because a newer client's KEXINIT is the
# first message big enough to fill a segment, and later on any large screen
# redraw. Rewriting the MSS in SYNs both leaving and arriving on tailscale0
# keeps both directions under the limit for every client.

set -Eeuo pipefail

MSS=1100
action=${1:-apply}

# Outgoing SYN/SYN-ACK (host services in OUTPUT, containers in FORWARD) caps
# what peers send us; incoming SYNs in PREROUTING cap what we send them.
rules=(
    "OUTPUT -o tailscale0"
    "FORWARD -o tailscale0"
    "PREROUTING -i tailscale0"
)

for tool in iptables ip6tables; do
    command -v "$tool" >/dev/null 2>&1 || continue
    for spec in "${rules[@]}"; do
        read -r chain dir iface <<<"$spec"
        rule=("$dir" "$iface" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS")
        case "$action" in
            apply)
                "$tool" -t mangle -C "$chain" "${rule[@]}" 2>/dev/null ||
                    "$tool" -t mangle -A "$chain" "${rule[@]}"
                ;;
            remove)
                while "$tool" -t mangle -D "$chain" "${rule[@]}" 2>/dev/null; do :; done
                ;;
            *)
                printf 'usage: %s [apply|remove]\n' "$0" >&2
                exit 2
                ;;
        esac
    done
done
