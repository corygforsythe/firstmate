#!/usr/bin/env bash
# fm-hermes-router-lib.sh - the ONE owner of the multi-host Hermes registry
# schema (config/hermes-hosts.json) and the capability-based host selection
# that lets a hermes-vps crewmate/scout be routed to one of several
# configured Hermes hosts instead of the single implicit one.
# Sourced by bin/fm-spawn.sh and bin/fm-hermes-router.sh (the standalone
# introspection/live-verification CLI); has no side effects on source.
#
# docs/configuration.md "Hermes hosts (config/hermes-hosts.json)" is the one
# owner of the registry field contract; this file only implements it.
#
# Backward compatibility (v1): an absent or empty registry means exactly one
# implicit host, printed as the id "default", carrying no capabilities at
# all - it matches only an empty capability requirement. fm_hermes_router_
# write_host_env writes nothing for "default", which is what keeps a
# launched bridge's env resolution byte-identical to the pre-router single-
# host path (bin/fm-hermes-ws-env-lib.sh's fm_hermes_ws_load_env alone,
# straight from $FM_HOME/.env).
#
# Selection is superset match then first-listed tie-break: a host matches
# when its "capabilities" array is a superset of the required set, and among
# several matches the first one listed in the registry wins. This is a
# deliberately naive v1 tie-break, not final routing policy - ranking
# matched hosts by anything smarter (load, latency, cost) is future work,
# not a gap this router silently works around today.

set -u -o pipefail

# fm_hermes_router_registry_path <fm-home> -> prints the registry path,
# whether or not it exists.
fm_hermes_router_registry_path() {
  printf '%s/config/hermes-hosts.json\n' "$1"
}

# fm_hermes_router_hosts_json <fm-home> -> prints a normalized JSON array of
# every registered host (id, capabilities, and whichever FM_HERMES_WS_*
# fields it set, each null when unset), or "[]" when the registry is absent
# or empty. Refuses loudly (nonzero, message on stderr) on malformed JSON, a
# missing/empty "id", a duplicate id, or a non-array-of-strings
# "capabilities".
fm_hermes_router_hosts_json() {
  local fm_home=$1 reg
  reg=$(fm_hermes_router_registry_path "$fm_home")
  if [ ! -s "$reg" ]; then
    printf '[]'
    return 0
  fi
  if ! jq -e 'type == "array" and all(.[]; has("id") and (.id | type == "string") and (.id | length > 0))' \
      "$reg" >/dev/null 2>&1; then
    echo "error: $reg must be a JSON array of host objects, each with a non-empty string \"id\"" >&2
    return 1
  fi
  if ! jq -e '(map(.id) | length) == (map(.id) | unique | length)' "$reg" >/dev/null 2>&1; then
    echo "error: $reg has duplicate host \"id\" values" >&2
    return 1
  fi
  if ! jq -e 'all(.[]; (.capabilities // []) | type == "array" and all(.[]; type == "string"))' \
      "$reg" >/dev/null 2>&1; then
    echo "error: $reg: every host's \"capabilities\" must be an array of strings" >&2
    return 1
  fi
  jq '[.[] | {
    id: .id,
    base_url: (.base_url // null),
    token: (.token // null),
    user: (.user // null),
    pass: (.pass // null),
    provider: (.provider // null),
    origin: (.origin // null),
    timeout: (.timeout // null),
    capabilities: (.capabilities // [])
  }]' "$reg"
}

# fm_hermes_router_select <fm-home> <csv-required-capabilities> -> prints the
# resolved host id to stdout; explanatory reasoning, including this v1
# tie-break's naive first-listed-match caveat, to stderr. Refuses loudly
# (nonzero, message on stderr) when no registered host's capabilities are a
# superset of the required set - never silently falls back to a mismatched
# host. <csv-required-capabilities> may be empty.
fm_hermes_router_select() {
  local fm_home=$1 caps_csv=${2:-} hosts_json caps_json matches count chosen
  hosts_json=$(fm_hermes_router_hosts_json "$fm_home") || return 1
  caps_json=$(jq -n -c --arg s "$caps_csv" 'if $s == "" then [] else ($s | split(",") | map(select(. != ""))) end')
  if [ "$hosts_json" = '[]' ]; then
    if [ "$caps_json" = '[]' ]; then
      echo "fm-hermes-router: no config/hermes-hosts.json registry (or it is empty) - using the single implicit host resolved from FM_HERMES_WS_*/.env" >&2
      printf '%s\n' default
      return 0
    fi
    echo "error: no Hermes host registry (config/hermes-hosts.json) is configured, and no host is known to carry the required capabilities [$caps_csv]; the one implicit host declares no capabilities" >&2
    return 1
  fi
  matches=$(jq -c --argjson req "$caps_json" '[.[] | select(($req - .capabilities) == [])]' <<<"$hosts_json")
  count=$(jq 'length' <<<"$matches")
  if [ "$count" -eq 0 ]; then
    echo "error: no registered Hermes host carries every required capability [$caps_csv]; registered hosts: $(jq -c '[.[] | {id, capabilities}]' <<<"$hosts_json")" >&2
    return 1
  fi
  chosen=$(jq -r '.[0].id' <<<"$matches")
  if [ "$count" -gt 1 ]; then
    echo "fm-hermes-router: $count hosts match [$caps_csv] ($(jq -r '[.[].id] | join(", ")' <<<"$matches")) - picked the first-listed, '$chosen'; this is a naive v1 tie-break, not final routing policy" >&2
  else
    echo "fm-hermes-router: selected host '$chosen' for required capabilities [$caps_csv]" >&2
  fi
  printf '%s\n' "$chosen"
}

# fm_hermes_router_write_host_env <fm-home> <host-id> <out-file> - writes
# KEY=VALUE FM_HERMES_WS_* lines for <host-id> to <out-file> (only the
# fields that host's registry entry actually set), or truncates <out-file>
# to empty for the "default" id. bin/fm-hermes-ws-env-lib.sh's
# fm_hermes_ws_load_env_file reads this exact format. Refuses loudly when
# <host-id> is not "default" and not present in the registry - a task must
# never silently fall back to a different host than the one it recorded.
fm_hermes_router_write_host_env() {
  local fm_home=$1 host_id=$2 out_file=$3 hosts_json host
  : > "$out_file"
  chmod 600 "$out_file" 2>/dev/null || true
  [ "$host_id" != default ] || return 0
  hosts_json=$(fm_hermes_router_hosts_json "$fm_home") || return 1
  host=$(jq -c --arg id "$host_id" '[.[] | select(.id == $id)][0] // null' <<<"$hosts_json")
  if [ "$host" = null ]; then
    echo "error: Hermes host '$host_id' is not present in config/hermes-hosts.json" >&2
    return 1
  fi
  jq -r '
    [
      ["FM_HERMES_WS_BASE_URL", .base_url],
      ["FM_HERMES_WS_TOKEN", .token],
      ["FM_HERMES_WS_USER", .user],
      ["FM_HERMES_WS_PASS", .pass],
      ["FM_HERMES_WS_PROVIDER", .provider],
      ["FM_HERMES_WS_ORIGIN", .origin],
      ["FM_HERMES_WS_TIMEOUT", .timeout]
    ]
    | .[]
    | select(.[1] != null)
    | "\(.[0])=\(.[1])"
  ' <<<"$host" > "$out_file"
}

# fm_hermes_router_host_present <fm-home> <host-id> -> success when
# <host-id> is "default" or is present in the registry, failure otherwise.
# Used by a relaunch to prove a previously recorded host has not been
# removed from the registry before reusing it (AGENTS.md's "never silently
# move hosts on relaunch" contract) without writing anything.
fm_hermes_router_host_present() {
  local fm_home=$1 host_id=$2 hosts_json
  [ "$host_id" != default ] || return 0
  hosts_json=$(fm_hermes_router_hosts_json "$fm_home") || return 1
  jq -e --arg id "$host_id" 'any(.[]; .id == $id)' <<<"$hosts_json" >/dev/null 2>&1
}
