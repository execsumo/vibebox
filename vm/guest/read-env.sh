#!/usr/bin/env bash
# Parse the shared KEY=VALUE format without evaluating shell syntax.

set -euo pipefail

trim() {
    local value=$1
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

read_vibebox_env() {
    local file=${1:?configuration file is required}
    [[ -r "$file" ]] || {
        printf 'configuration file is not readable: %s\n' "$file" >&2
        return 1
    }

    local line key value line_number=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        ((line_number += 1))
        line="${line%$'\r'}"
        [[ -z "${line//[[:space:]]/}" || "$line" == \#* ]] && continue
        [[ "$line" == *=* ]] || {
            printf 'invalid configuration syntax at %s:%s\n' "$file" "$line_number" >&2
            return 1
        }
        key=$(trim "${line%%=*}")
        value=$(trim "${line#*=}")
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
            printf 'invalid configuration key %s at %s:%s\n' "$key" "$file" "$line_number" >&2
            return 1
        }
        # export with an assignment argument, never with eval, so values cannot
        # execute shell syntax or expand another variable.
        export "$key=$value"
    done < "$file"
}
