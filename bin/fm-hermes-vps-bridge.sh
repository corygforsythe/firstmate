#!/usr/bin/env bash
# fm-hermes-vps-bridge.sh - thin env-resolving wrapper around
# fm-hermes-vps-bridge.py, the long-lived local process that renders a
# captain's remote VPS Hermes /api/ws session into an ordinary firstmate
# pane so a VPS-dispatched Hermes crewmate shows up and behaves like any
# other crewmate. See fm-hermes-vps-bridge.py's own header for exactly what
# it does inside the pane, and docs/verification/hermes.md's "hermes-vps"
# section for the live evidence this was built from.
#
# Usage: fm-hermes-vps-bridge.sh --cwd <path>
#
# Configuration and credentials are resolved the identical way
# bin/fm-hermes-ws.sh resolves them (bin/fm-hermes-ws-env-lib.sh is the one
# owner of that env/.env fill), so the captain's VPS login lives only in
# $FM_HOME/.env, never in a launch command, task brief, or status line.

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
  echo "fm-hermes-vps-bridge: python3 required" >&2
  exit 1
fi
PY_BIN="$SCRIPT_DIR/fm-hermes-vps-bridge.py"
if [ ! -f "$PY_BIN" ]; then
  echo "fm-hermes-vps-bridge: $PY_BIN missing" >&2
  exit 1
fi

exec "$PY" "$PY_BIN" "$@"
