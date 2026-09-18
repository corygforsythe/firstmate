#!/usr/bin/env bash
# fm-hermes-ws-env-lib.sh - the ONE owner of FM_HERMES_WS_* environment
# resolution, shared by every local process that needs to reach a Hermes
# gateway: bin/fm-hermes-ws.sh (the one-shot RPC CLI) and
# bin/fm-hermes-vps-bridge.sh (the long-lived fleet-dispatch bridge).
# Extracted so callers can never drift on how a credential is resolved or
# filled - see bin/fm-hermes-ws.py's header for the exact variable contract
# this fills.
#
# fm_hermes_ws_load_env_file is the generic "fill every unset FM_HERMES_WS_*
# variable from this one file" primitive; fm_hermes_ws_load_env is just that
# primitive applied to <fm-home>/.env. bin/fm-hermes-router-lib.sh's
# multi-host layer (docs/configuration.md "Hermes hosts") is the other
# caller of the generic form: a resolved host's file is loaded first so its
# values win, then fm_hermes_ws_load_env fills whatever that host's registry
# entry left unset from .env, the identical "first setter wins" convention
# either way.
#
# Sourced by scripts; has no side effects on source beyond defining these
# functions. Never logs or echoes a credential value.

# One KEY=VALUE lookup from a .env-style file: last assignment wins,
# tolerates a leading "export ", surrounding whitespace, and one layer of
# matching quotes. Prints nothing when the file or key is absent.
_fm_hermes_ws_env_get() {
  local key=$1 file=$2 line val
  [ -f "$file" ] || return 0
  line=$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "$file" 2>/dev/null | tail -n1) || return 0
  [ -n "$line" ] || return 0
  val=${line#*=}
  val=${val#"${val%%[![:space:]]*}"}
  val=${val%"${val##*[![:space:]]}"}
  case "$val" in
    \"*\") val=${val#\"}; val=${val%\"} ;;
    \'*\') val=${val#\'}; val=${val%\'} ;;
  esac
  printf '%s' "$val"
}

# fm_hermes_ws_load_env_file: export every unset FM_HERMES_WS_* variable
# found in <file> (env wins over the file - the same "first setter wins"
# convention every caller layers on top of). A missing or empty <file> is a
# no-op, so calling this with an absent path never errors.
fm_hermes_ws_load_env_file() {  # <file>
  local env_file=$1 var val
  for var in FM_HERMES_WS_BASE_URL FM_HERMES_WS_TOKEN FM_HERMES_WS_USER FM_HERMES_WS_PASS \
             FM_HERMES_WS_PROVIDER FM_HERMES_WS_ORIGIN FM_HERMES_WS_TIMEOUT; do
    if [ -z "${!var:-}" ]; then
      val=$(_fm_hermes_ws_env_get "$var" "$env_file")
      if [ -n "$val" ]; then
        export "$var=$val"
      fi
    fi
  done
}

# fm_hermes_ws_load_env: export every unset FM_HERMES_WS_* variable from
# <fm-home>/.env (env wins over .env, matching fm-mail.sh's convention).
fm_hermes_ws_load_env() {  # <fm-home>
  fm_hermes_ws_load_env_file "$1/.env"
}
