#!/usr/bin/env bash
# Behavior tests for bin/fm-hermes-ws.py / bin/fm-hermes-ws.sh, the
# standalone JSON-RPC-over-WebSocket dispatch client for a Hermes Agent
# dashboard/serve gateway's /api/ws session API.
#
# This is offline and portable: tests/fixtures/fm-hermes-ws-stub-server.py
# is a from-scratch, independently-written HTTP + RFC 6455 WebSocket
# double standing in for the real Hermes dashboard, so these tests exercise
# real sockets and real framing without Hermes installed or a live VPS.
# What is pinned here:
#   1. Loopback/--insecure mode's static ?token= auth works end to end
#      across every RPC primitive the client exposes.
#   2. Gated mode's password-login -> cookie -> ws-ticket -> ?ticket= flow
#      works end to end, and bad credentials fail closed with no ticket
#      minted.
#   3. `dispatch` blocks until a real message.complete event (not an
#      earlier event) and surfaces a turn's `error` event as a failure,
#      matching scripts/iso-certify.py's real first-party Hermes client
#      (docs/verification/hermes.md).
#   4. Missing required configuration fails closed with a clear message,
#      never a partial/guessed connection attempt.
#   5. dispatch sends the server a real session.close RPC on a failed turn
#      AND on a client-side timeout, not just on the success path - a
#      failed/timed-out dispatch must not leak the server-side session.
#      Proven via the stub's optional RPC log (a real wire artifact), since
#      the client's own exit code proves nothing about what it sent.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

WRAPPER="$ROOT/bin/fm-hermes-ws.sh"
STUB="$ROOT/tests/fixtures/fm-hermes-ws-stub-server.py"
TMP_ROOT=$(fm_test_tmproot fm-hermes-ws)

STUB_USER="probeuser"
STUB_PASS="probepass"
STUB_TOKEN="probetoken"
STUB_PID=""

free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}

start_stub() {
  local port=$1 rpc_log=${2:-}
  python3 "$STUB" "$port" "$STUB_USER" "$STUB_PASS" "$STUB_TOKEN" "$rpc_log" \
    >"$TMP_ROOT/stub.out" 2>"$TMP_ROOT/stub.err" &
  STUB_PID=$!
  local tries=0
  while [ "$tries" -lt 100 ]; do
    if python3 -c "
import socket, sys
s = socket.socket()
s.settimeout(0.2)
try:
    s.connect(('127.0.0.1', $port))
except OSError:
    sys.exit(1)
sys.exit(0)
" 2>/dev/null; then
      return 0
    fi
    tries=$((tries + 1))
    sleep 0.05
  done
  fail "stub server on port $port never accepted a connection"
}

stop_stub() {
  if [ -n "$STUB_PID" ]; then
    kill "$STUB_PID" >/dev/null 2>&1 || true
    wait "$STUB_PID" 2>/dev/null || true
    STUB_PID=""
  fi
}
trap stop_stub EXIT

# --- token-mode env for a given port ----------------------------------------
token_env() {
  local port=$1
  shift
  env -i PATH="$PATH" \
    FM_HERMES_WS_BASE_URL="http://127.0.0.1:$port" \
    FM_HERMES_WS_TOKEN="$STUB_TOKEN" \
    FM_HOME="$TMP_ROOT/home-unused" \
    "$@"
}

password_env() {
  local port=$1 user=$2 pass=$3
  shift 3
  env -i PATH="$PATH" \
    FM_HERMES_WS_BASE_URL="http://127.0.0.1:$port" \
    FM_HERMES_WS_USER="$user" \
    FM_HERMES_WS_PASS="$pass" \
    FM_HOME="$TMP_ROOT/home-unused" \
    "$@"
}

test_token_mode_full_rpc_cycle() {
  local port out
  port=$(free_port)
  start_stub "$port"

  out=$(token_env "$port" "$WRAPPER" create /tmp/some-worktree) \
    || fail "create failed: $(cat "$TMP_ROOT/stub.err" 2>/dev/null)"
  local sid
  sid=$(printf '%s' "$out" | jq -r '.session_id')
  [ "$sid" = "test-session-1" ] || fail "create did not return the stub's session_id, got: $out"

  out=$(token_env "$port" "$WRAPPER" submit "$sid" "hello") || fail "submit failed: $out"
  [ "$(printf '%s' "$out" | jq -r '.status')" = "streaming" ] \
    || fail "submit did not report status streaming, got: $out"

  out=$(token_env "$port" "$WRAPPER" status "$sid") || fail "status failed: $out"
  printf '%s' "$out" | jq -e 'has("agent_running")' >/dev/null \
    || fail "status result missing agent_running, got: $out"

  out=$(token_env "$port" "$WRAPPER" history "$sid") || fail "history failed: $out"
  [ "$(printf '%s' "$out" | jq -r '.messages[0].text')" = "stub reply" ] \
    || fail "history did not return the stub transcript, got: $out"

  out=$(token_env "$port" "$WRAPPER" steer "$sid" "redirect") || fail "steer failed: $out"
  [ "$(printf '%s' "$out" | jq -r '.steered')" = "true" ] || fail "steer result unexpected: $out"

  out=$(token_env "$port" "$WRAPPER" interrupt "$sid") || fail "interrupt failed: $out"
  [ "$(printf '%s' "$out" | jq -r '.interrupted')" = "true" ] || fail "interrupt result unexpected: $out"

  out=$(token_env "$port" "$WRAPPER" close "$sid") || fail "close failed: $out"
  [ "$(printf '%s' "$out" | jq -r '.closed')" = "true" ] || fail "close result unexpected: $out"

  stop_stub
  pass "token mode: every RPC primitive round-trips over a real WebSocket"
}

test_gated_password_ticket_flow_succeeds() {
  local port out
  port=$(free_port)
  start_stub "$port"

  out=$(password_env "$port" "$STUB_USER" "$STUB_PASS" "$WRAPPER" create /tmp/gated-worktree) \
    || fail "gated create failed: $(cat "$TMP_ROOT/stub.err" 2>/dev/null)"
  [ "$(printf '%s' "$out" | jq -r '.session_id')" = "test-session-1" ] \
    || fail "gated create did not return the stub's session_id, got: $out"

  stop_stub
  pass "gated mode: password-login -> cookie -> ws-ticket -> /api/ws?ticket= round-trips for real"
}

test_gated_bad_credentials_fail_closed() {
  local port rc
  port=$(free_port)
  start_stub "$port"

  rc=0
  password_env "$port" "$STUB_USER" "wrong-password" "$WRAPPER" create /tmp/x >/dev/null 2>"$TMP_ROOT/err.txt" \
    || rc=$?
  [ "$rc" -ne 0 ] || fail "bad credentials must fail closed, but the client exited 0"
  grep -q "wrong-password" "$TMP_ROOT/err.txt" && fail "the password leaked into stderr"

  stop_stub
  pass "gated mode: bad credentials fail closed with no ticket minted and no leaked secret"
}

test_dispatch_waits_for_message_complete() {
  local port out
  port=$(free_port)
  start_stub "$port"

  out=$(token_env "$port" "$WRAPPER" dispatch /tmp/dispatch-worktree "a normal prompt" 10) \
    || fail "dispatch failed on a normal (non-error) turn: $out"
  [ "$(printf '%s' "$out" | jq -r '.messages[0].text')" = "stub reply" ] \
    || fail "dispatch did not print the final session.history, got: $out"

  stop_stub
  pass "dispatch: waits past message.start/message.delta and completes only on message.complete"
}

test_dispatch_surfaces_a_turn_error() {
  local port rc errtext
  port=$(free_port)
  start_stub "$port"

  rc=0
  token_env "$port" "$WRAPPER" dispatch /tmp/dispatch-worktree "TRIGGER_ERROR please" 10 \
    >/dev/null 2>"$TMP_ROOT/dispatch-err.txt" || rc=$?
  [ "$rc" -ne 0 ] || fail "dispatch must fail when the turn emits an error event"
  errtext=$(cat "$TMP_ROOT/dispatch-err.txt")
  case "$errtext" in
    *"stub turn error"*) ;;
    *) fail "dispatch's error did not surface the turn's error payload message, got: $errtext" ;;
  esac

  stop_stub
  pass "dispatch: a turn's error event fails the call and surfaces its message"
}

test_dispatch_closes_session_on_turn_error() {
  local port rc rpc_log
  port=$(free_port)
  rpc_log="$TMP_ROOT/rpc-error.log"
  : > "$rpc_log"
  start_stub "$port" "$rpc_log"

  rc=0
  token_env "$port" "$WRAPPER" dispatch /tmp/dispatch-worktree "TRIGGER_ERROR please" 10 \
    >/dev/null 2>"$TMP_ROOT/dispatch-err2.txt" || rc=$?
  [ "$rc" -ne 0 ] || fail "dispatch must fail when the turn emits an error event"

  jq -e 'select(.method == "session.close" and .session_id == "test-session-1")' "$rpc_log" >/dev/null \
    || fail "the server never received a session.close RPC after the turn's error event, got: $(cat "$rpc_log")"

  stop_stub
  pass "dispatch: a turn error still sends session.close to the server, not just a local socket close"
}

test_dispatch_closes_session_on_timeout() {
  local port rc rpc_log
  port=$(free_port)
  rpc_log="$TMP_ROOT/rpc-timeout.log"
  : > "$rpc_log"
  start_stub "$port" "$rpc_log"

  rc=0
  token_env "$port" "$WRAPPER" dispatch /tmp/dispatch-worktree "TRIGGER_HANG please" 1 \
    >/dev/null 2>"$TMP_ROOT/dispatch-err3.txt" || rc=$?
  [ "$rc" -ne 0 ] || fail "dispatch must fail when the turn never completes within its budget"
  case "$(cat "$TMP_ROOT/dispatch-err3.txt")" in
    *"timed out"*) ;;
    *) fail "dispatch did not report a timeout, got: $(cat "$TMP_ROOT/dispatch-err3.txt")" ;;
  esac

  jq -e 'select(.method == "session.close" and .session_id == "test-session-1")' "$rpc_log" >/dev/null \
    || fail "the server never received a session.close RPC after dispatch timed out, got: $(cat "$rpc_log")"

  stop_stub
  pass "dispatch: a timed-out turn still sends session.close to the server, not just a local socket close"
}

test_missing_base_url_fails_closed() {
  local rc out
  rc=0
  out=$(env -i PATH="$PATH" FM_HOME="$TMP_ROOT/home-unused" "$WRAPPER" create /tmp/x 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a missing FM_HERMES_WS_BASE_URL must fail closed, but the client exited 0"
  case "$out" in
    *FM_HERMES_WS_BASE_URL*) ;;
    *) fail "the missing-config error did not name FM_HERMES_WS_BASE_URL, got: $out" ;;
  esac
  pass "config: a missing FM_HERMES_WS_BASE_URL fails closed by name, no guessed connection"
}

test_env_file_credentials_are_read() {
  local port out home
  port=$(free_port)
  start_stub "$port"
  home="$TMP_ROOT/home-with-env"
  mkdir -p "$home"
  {
    echo "FM_HERMES_WS_BASE_URL=http://127.0.0.1:$port"
    echo "FM_HERMES_WS_TOKEN=$STUB_TOKEN"
  } > "$home/.env"

  out=$(env -i PATH="$PATH" FM_HOME="$home" "$WRAPPER" create /tmp/x) \
    || fail "wrapper did not pick up FM_HOME/.env config: $(cat "$TMP_ROOT/stub.err" 2>/dev/null)"
  [ "$(printf '%s' "$out" | jq -r '.session_id')" = "test-session-1" ] \
    || fail "wrapper's .env-sourced config did not reach a real dispatch, got: $out"

  stop_stub
  pass "config: fm-hermes-ws.sh fills missing env from \$FM_HOME/.env, env still wins over it"
}

test_token_mode_full_rpc_cycle
test_gated_password_ticket_flow_succeeds
test_gated_bad_credentials_fail_closed
test_dispatch_waits_for_message_complete
test_dispatch_surfaces_a_turn_error
test_dispatch_closes_session_on_turn_error
test_dispatch_closes_session_on_timeout
test_missing_base_url_fails_closed
test_env_file_credentials_are_read
