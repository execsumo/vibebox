#!/usr/bin/env bash

set -u

ok() {
    printf 'ok %s - %s\n' "$1" "$2"
}

fail() {
    printf 'not ok %s - %s\n' "$1" "$2"
    shift
    [[ $# -gt 0 ]] && printf '%s\n' "$*" >&2
    return 1
}

skip() {
    printf 'skip %s - %s\n' "$1" "$2"
    shift
    [[ $# -gt 0 ]] && printf '%s\n' "$*" >&2
    return 0
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        fail "$2" "required command '$1' is missing"
        return 1
    }
}

run_check() {
    local id=$1 desc=$2
    shift 2
    if "$@"; then
        ok "$id" "$desc"
    else
        fail "$id" "$desc"
    fi
}
