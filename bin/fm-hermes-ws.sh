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
# logs a credential. The env/.env resolution itself is shared with
# bin/fm-hermes-vps-bridge.sh (bin/fm-hermes-ws-env-lib.sh is the one owner).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-}"
if [ -z "$FM_HOME" ]; then
  FM_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

# shellcheck source=bin/fm-hermes-ws-env-lib.sh
. "$SCRIPT_DIR/fm-hermes-ws-env-lib.sh"
fm_hermes_ws_load_env "$FM_HOME"

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
