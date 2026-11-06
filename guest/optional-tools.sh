#!/usr/bin/env bash
# The optional tools vibebox can install. Each is controlled by a TOOL_<NAME>
# flag in vibebox.env (for example TOOL_HERDR=true). Sourced by provision/30-tools
# and status.sh so both agree on the set. Keep this list in step with
# host/lib/config.ps1.

VIBEBOX_OPTIONAL_TOOLS=(agy herdr droid hermes hermes-webui deepseek-harness codeburn pi codegraph gws docling infisical)

optional_tool_var() {
    local name=${1//-/_}
    printf 'TOOL_%s' "${name^^}"
}

# The host validates each flag as true or false; anything but true is off.
optional_tool_enabled() {
    local var
    var=$(optional_tool_var "$1")
    [[ "${!var:-false}" == true ]]
}
