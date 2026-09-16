#!/usr/bin/env bash
# fm-hermes-router.sh - standalone introspection/live-verification CLI for
# bin/fm-hermes-router-lib.sh, the multi-host Hermes registry and
# capability-based host selection bin/fm-spawn.sh drives a hermes-vps
# dispatch through. Never used by fm-spawn.sh itself (it sources the lib
# directly); this wrapper exists so the registry and the router's selection
# logic can be inspected and exercised from a shell without spawning a task.
#
# Usage: fm-hermes-router.sh list
#        fm-hermes-router.sh select [<capability>...]
#
#   list    prints each registered host's id and capabilities as JSON
#           ("[]" when config/hermes-hosts.json is absent or empty).
#   select  runs the same selection fm-spawn.sh would for a hermes-vps
#           dispatch requiring every given capability (none required when no
#           capability is given), printing the resolved host id to stdout
#           and the selection reasoning to stderr; exits nonzero with a
#           clear refusal when no host matches.
#
# FM_HOME selects the registry (config/hermes-hosts.json under it); falls
# back to this script's own repo root when unset, matching every other
# fm-hermes-*.sh wrapper's convention.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-}"
if [ -z "$FM_HOME" ]; then
  FM_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

# shellcheck source=bin/fm-hermes-router-lib.sh
. "$SCRIPT_DIR/fm-hermes-router-lib.sh"

command -v jq >/dev/null 2>&1 || { echo "fm-hermes-router: jq required" >&2; exit 1; }

usage() {
  echo "usage: fm-hermes-router.sh list | select [<capability>...]" >&2
  exit 1
}

[ $# -ge 1 ] || usage
cmd=$1
shift

case "$cmd" in
  list)
    [ $# -eq 0 ] || usage
    fm_hermes_router_hosts_json "$FM_HOME"
    echo
    ;;
  select)
    caps_csv=$(IFS=,; printf '%s' "$*")
    fm_hermes_router_select "$FM_HOME" "$caps_csv"
    ;;
  *)
    usage
    ;;
esac
