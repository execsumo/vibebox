# Add hermes-webui to vibebox + serve as hermes.goose-marlin.ts.net

## Context

Vibebox already installs the Hermes Agent CLI (Dockerfile step 8). [hermes-webui](https://github.com/nesquena/hermes-webui) is a self-hosted web UI that runs the Hermes Agent **in-process**, reading `~/.hermes` directly — so it must run *inside the sandbox container* (same toolchain, same workspace, same `~/.hermes`), not as a separate app container.

Goal: install hermes-webui as part of the image (right after Hermes, step 8b), auto-start it on container boot, and expose it at **https://hermes.goose-marlin.ts.net** — while `vibebox.goose-marlin.ts.net` keeps working unchanged for SSH.

**The hostname challenge:** one Tailscale node = one hostname. The existing `tailscale` sidecar owns the netns and identity `vibebox`; you cannot hang a second hostname off it. The solution (same pattern as excalidraw on vps-lab) is a **second Tailscale sidecar** with its own identity `hermes`, running `tailscale serve` (via `TS_SERVE_CONFIG`) to terminate TLS on 443 and proxy to the webui.

### Topology decision

The webui listens inside the *vibebox* netns (sandbox shares it with the `tailscale` service). The new `hermes-ts` sidecar gets its **own netns** on the compose default network and proxies across it:

```
tailnet ──https──> hermes-ts (node "hermes", userspace, serve 443)
                        │  proxy http://tailscale:8787  (compose DNS)
                        ▼
                   vibebox netns:  hermes-webui bound 0.0.0.0:8787
                                   (runs inside sandbox container)
tailnet ──ssh────> tailscale (node "vibebox", unchanged)
```

- serve.json proxy targets by compose service name are supported (validation restricting targets to localhost is CLI-only; community projects use `http://service:port` in `TS_SERVE_CONFIG`).
- `hermes-ts` runs `TS_USERSPACE=true` — no TUN device, no NET_ADMIN, no port clashes. Serve is an L7 proxy and works fine in userspace mode.
- Webui must bind `0.0.0.0` so `hermes-ts` can reach it. Upstream requires/strongly recommends `HERMES_WEBUI_PASSWORD` for non-localhost binds — we add it to `.env`. Note: the existing `TS_DEST_IP=127.0.0.1` DNAT already forwards *all* ports of the vibebox node to loopback, so the webui would be reachable at `vibebox:8787` over the tailnet even bound to 127.0.0.1 — password is warranted regardless. Exposure is tailnet-only in every case (no Funnel).
- Rejected alternative: joining `hermes-ts` into the existing tailscale netns (`network_mode: service:tailscale`) to use a `127.0.0.1` proxy target — it means two tailscaled daemons in one netns (fragile, hard to debug) and couples lifecycles. Kept as fallback (see Risks).

### Install-location decision

Clone + venv go to **`/opt/hermes-webui` in the image** (Dockerfile), not the home volume via `onboard`:
- Repo philosophy (docker-compose.yml:69-73): only `/home` is a pet; "everything durable belongs in the Dockerfile; a rebuild is the way to change the rest".
- Upstream warns webui/agent version skew causes breakage ("upgrade both together") — image install means one rebuild updates hermes + webui in lockstep.
- Mutable state is unaffected: PID/log/sessions all live in `~/.hermes/` (persisted volume, already in `dotfiles.manifest`).

hermes-webui needs Python 3.11+ — Ubuntu 24.04 ships 3.12, and `python3`/`python3-venv`/`python3-pip` are already in apt step 1. No new system deps.

## Changes

### 1. `Dockerfile`
- **New step 8b** (immediately after Hermes step 8, before CodeGraph step 9), tolerated like its siblings:
  ```dockerfile
  # 8b. Install Hermes WebUI (web frontend for the Hermes Agent installed in step 8).
  # Cloned into /opt (image-managed) so a rebuild updates agent + webui together —
  # upstream warns against version skew between the two. Runtime state (sessions,
  # pid, logs) lands in ~/.hermes/webui on the persisted home volume.
  RUN (git clone --depth 1 https://github.com/nesquena/hermes-webui.git /opt/hermes-webui && \
       python3 -m venv /opt/hermes-webui/.venv && \
       /opt/hermes-webui/.venv/bin/pip install --no-cache-dir -r /opt/hermes-webui/requirements.txt && \
       chown -R 1000:1000 /opt/hermes-webui) || echo "Hermes WebUI setup skipped"
  ```
  (`chown 1000` = the sandbox user; created later in the Dockerfile but numeric IDs are fine. Owned by the user so `update` can `git pull` and `ctl.sh` can run without sudo.)
- **Step 9b verification**, add to the warn loop line:
  `[ -x /opt/hermes-webui/ctl.sh ] || echo "WARNING: hermes-webui not installed (non-fatal)"`

### 2. `scripts/entrypoint` — auto-start on container boot
After host-key generation, before `exec "$@"`:
```bash
# Start Hermes WebUI as the sandbox user if installed (daemonized via ctl.sh; non-fatal).
# Binds 0.0.0.0 so the hermes-ts tailscale sidecar can proxy to it across the compose
# network. HERMES_WEBUI_PASSWORD comes from .env via the compose environment.
if [ -x /opt/hermes-webui/ctl.sh ]; then
  SANDBOX_USER="$(getent passwd 1000 | cut -d: -f1)"
  runuser -u "$SANDBOX_USER" -- env \
    HERMES_WEBUI_HOST="${HERMES_WEBUI_HOST:-0.0.0.0}" \
    HERMES_WEBUI_PORT=8787 \
    HERMES_WEBUI_PASSWORD="${HERMES_WEBUI_PASSWORD:-}" \
    /opt/hermes-webui/ctl.sh start || echo "hermes-webui failed to start (non-fatal)"
fi
```
`ctl.sh start` daemonizes (PID `~/.hermes/webui.pid`, log `~/.hermes/webui.log`), so sshd startup is not blocked.

### 3. `docker-compose.yml`
- **New `hermes-ts` service** (independent lifecycle — a restart of it never orphans the sandbox netns):
  ```yaml
  hermes-ts:
    image: tailscale/tailscale:latest
    container_name: ${SANDBOX_NAME:-vibebox}-hermes-ts
    hostname: ${HERMES_HOSTNAME:-hermes}   # tailnet name -> hermes.goose-marlin.ts.net
    environment:
      - TS_STATE_DIR=/var/lib/tailscale
      - TS_USERSPACE=true          # L7 serve only; no TUN/NET_ADMIN needed
      - TS_AUTHKEY=${TS_AUTHKEY:-}
      - TS_SERVE_CONFIG=/config/serve.json
    volumes:
      - hermes_ts_state:/var/lib/tailscale
      - ./hermes-serve:/config:ro   # directory mount — required for config change detection
    healthcheck: (same tailscale status check as the tailscale service)
    restart: unless-stopped
  ```
- **New volume**: `hermes_ts_state` → `name: ${SANDBOX_NAME:-vibebox}-hermes-ts-state` (persists the `hermes` node identity, same rationale as the vibebox node).
- **`sandbox` service**: add `HERMES_WEBUI_PASSWORD=${HERMES_WEBUI_PASSWORD:-}` to `environment` (entrypoint consumes it).

### 4. New file `hermes-serve/serve.json`
```json
{
  "TCP": { "443": { "HTTPS": true } },
  "Web": {
    "${TS_CERT_DOMAIN}:443": {
      "Handlers": { "/": { "Proxy": "http://tailscale:8787" } }
    }
  }
}
```
`${TS_CERT_DOMAIN}` is expanded by containerboot to `hermes.goose-marlin.ts.net`. Target `tailscale` is the compose DNS name of the netns that the webui actually listens in.

### 5. `.env.example`
Add:
- `HERMES_HOSTNAME=hermes` — tailnet hostname for the webui node (one node = one hostname, hence the second sidecar).
- `HERMES_WEBUI_PASSWORD=` — commented: required because the webui binds beyond localhost; everything is tailnet-only (no Funnel), but any tailnet device can otherwise reach it. Also note the existing `TS_AUTHKEY` is reused by `hermes-ts` (a *reusable* key covers both nodes), and if the key is tagged `tag:vibebox`, ACLs must permit tailnet users to reach that tag on 443.

### 6. `scripts/update`
Renumber `N/9` → `N/10`; add before the closing summary:
```bash
echo "10/10 Updating Hermes WebUI..."
(git -C /opt/hermes-webui pull --ff-only && \
 /opt/hermes-webui/.venv/bin/pip install -q -r /opt/hermes-webui/requirements.txt && \
 /opt/hermes-webui/ctl.sh restart) || true
```
(Same semantics as other tools: non-durable until rebuild — the existing closing note already covers this.)

### 7. Docs
- **`README.md`**: add Hermes WebUI to the coding-tools table; new short section "Hermes WebUI (https://hermes.<tailnet>.ts.net)" covering: auto-start on boot, `ctl.sh status|logs|restart` inside the box, `HERMES_WEBUI_PASSWORD`, tailnet HTTPS-certs prerequisite (already enabled on this tailnet — excali uses it), and ~10 s first-visit delay while the LetsEncrypt cert provisions.
- **`handoff.md`**: add a row to the installed-tools reference (`Hermes WebUI | git clone + venv (tolerated) | /opt/hermes-webui | git pull + pip (update step 10) | state under .hermes/`).
- No `dotfiles.manifest` change — webui state lives under `~/.hermes/`, already covered by the existing `dir|.hermes` entry.

### 8. Save plan copy (user request)
Copy this plan into the repo as `d:\Coding\vibebox\PLAN-hermes-webui.md` as the first implementation step.

## Verification

1. `docker compose build` — confirm step 8b succeeds (no "Hermes WebUI setup skipped") and 9b prints no webui warning.
2. `docker compose up -d` — `docker compose ps` shows `tailscale`, `sandbox`, `hermes-ts` all healthy.
3. `docker exec vibebox-hermes-ts tailscale status --peers=false` — node is `hermes`; `docker exec vibebox-hermes-ts tailscale serve status` shows 443 → `http://tailscale:8787`.
4. In the sandbox: `curl -s http://127.0.0.1:8787/health` returns OK; `~/.hermes/webui.log` clean.
5. Cross-netns reachability: `docker exec vibebox-hermes-ts wget -qO- http://tailscale:8787/health`.
6. From another tailnet device: open `https://hermes.goose-marlin.ts.net` — cert provisions on first hit, login with `HERMES_WEBUI_PASSWORD`.
7. Regression: `ssh vibebox` (tailnet) and local `ssh` alias still work.

## Risks / fallbacks

- **Serve refuses the non-localhost target** (unlikely — JSON config bypasses the CLI-only localhost validation): fallback is `network_mode: service:tailscale` on `hermes-ts` + `TS_HOSTNAME=hermes` (container `hostname:` is disallowed with shared netns) + proxy target `http://127.0.0.1:8787`, webui can then stay near-localhost. Second tailscaled runs userspace so no TUN clash.
- **Webui refuses `0.0.0.0` without a password**: set `HERMES_WEBUI_PASSWORD` in `.env` before `up`; the README section documents it as effectively required.
- **Stale `~/.hermes/webui.pid` after an unclean container stop**: `ctl.sh` handles stale-PID detection per upstream; if a start-loop appears in practice, clear the pid file in the entrypoint before `ctl.sh start`.
- **Ephemeral auth key**: the `hermes` node disappears from the tailnet while the stack is down (same documented trade-off as the vibebox node); identity persists in the new state volume.
