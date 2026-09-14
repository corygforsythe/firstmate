#!/usr/bin/env bash
# fm-hermes-ws.sh - thin env-resolving wrapper around fm-hermes-ws.py, the
# JSON-RPC-over-WebSocket client for a Hermes Agent dashboard/serve
# gateway's /api/ws session API.
#
# Standalone dispatch primitive only: no fm-spawn.sh/fm-control.sh/
# fm-crew-state.sh/fm-busy-lib.sh wiring, per this task's captain-approved
# scope. See docs/verification/hermes.md for the source evidence this was
# built from and what remains live-unverified, and fm-hermes-ws.py's own
# header for the exact subcommand and environment-variable contract - this
# wrapper only resolves environment/.env, it does not restate that contract.
#
# Usage: fm-hermes-ws.sh <create|submit|status|history|steer|interrupt|close|dispatch> [args...]
#
# Configuration and credentials are read from the environment, filling
# missing keys from the gitignored $FM_HOME/.env (same "env wins over
# .env" convention as fm-mail.sh and the Relay/FMX token). FM_HOME falls
# back to the repo root when unset. Required: FM_HERMES_WS_BASE_URL, plus
# either FM_HERMES_WS_TOKEN (loopback/--insecure) or FM_HERMES_WS_USER +
# FM_HERMES_WS_PASS (gated mode) - fm-hermes-ws.py enforces this and never
# logs a credential.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-}"
if [ -z "$FM_HOME" ]; then
  FM_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
fi
ENV_FILE="$FM_HOME/.env"

# One KEY=VALUE lookup from a .env-style file: last assignment wins,
# tolerates a leading "export ", surrounding whitespace, and one layer of
# matching quotes. Prints nothing when the file or key is absent.
_hermes_ws_env_get() {
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

for var in FM_HERMES_WS_BASE_URL FM_HERMES_WS_TOKEN FM_HERMES_WS_USER FM_HERMES_WS_PASS \
           FM_HERMES_WS_PROVIDER FM_HERMES_WS_ORIGIN FM_HERMES_WS_TIMEOUT; do
  if [ -z "${!var:-}" ]; then
    val=$(_hermes_ws_env_get "$var" "$ENV_FILE")
    if [ -n "$val" ]; then
      export "$var=$val"
    fi
  fi
done

PY="$(command -v python3 || true)"
if [ -z "$PY" ]; then
  echo "fm-hermes-ws: python3 required" >&2
  exit 1
fi
PY_BIN="$SCRIPT_DIR/fm-hermes-ws.py"
if [ ! -f "$PY_BIN" ]; then
  echo "fm-hermes-ws: $PY_BIN missing" >&2
  exit 1
fi

exec "$PY" "$PY_BIN" "$@"
