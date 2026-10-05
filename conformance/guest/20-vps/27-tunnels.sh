#!/usr/bin/env bash

set -u
source "$(dirname "$0")/../../lib.sh"

skip "27-tunnels" "SSH reverse/forward tunnel needs a second endpoint; run the documented two-host check"
exit 77
