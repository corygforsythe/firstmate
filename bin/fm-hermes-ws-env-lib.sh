#!/usr/bin/env bash
# fm-hermes-ws-env-lib.sh - the ONE owner of FM_HERMES_WS_* environment
# resolution, shared by every local process that needs to reach the
# captain's VPS Hermes gateway: bin/fm-hermes-ws.sh (the one-shot RPC CLI)
# and bin/fm-hermes-vps-bridge.sh (the long-lived fleet-dispatch bridge).
# Extracted so the two callers can never drift on how a credential is
# resolved or filled from $FM_HOME/.env - see bin/fm-hermes-ws.py's header
# for the exact variable contract this fills.
#
# Sourced by scripts; has no side effects on source beyond defining
# fm_hermes_ws_load_env. Never logs or echoes a credential value.

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

# fm_hermes_ws_load_env: export every unset FM_HERMES_WS_* variable from
# <fm-home>/.env (env wins over .env, matching fm-mail.sh's convention).
fm_hermes_ws_load_env() {  # <fm-home>
  local fm_home=$1 env_file="$1/.env" var val
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
