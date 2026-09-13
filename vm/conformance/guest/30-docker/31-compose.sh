#!/usr/bin/env bash

set -u
source "$(dirname "$0")/../../lib.sh"

id=31-compose
directory=$(mktemp -d)
trap 'rm -rf "$directory"' EXIT
cat > "$directory/compose.yml" <<'EOF'
services:
  probe:
    image: alpine:3.20
    command: ["sh", "-c", "test -f /probe/marker"]
    volumes:
      - ./marker:/probe/marker:ro
EOF
touch "$directory/marker"
(cd "$directory" && docker compose run --rm probe) >/dev/null 2>&1 || {
    fail "$id" "Compose bind paths refer to guest paths"
    exit 1
}
ok "$id" "Docker Compose uses native guest paths"
