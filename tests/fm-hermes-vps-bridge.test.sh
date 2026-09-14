#!/usr/bin/env bash
# Behavior tests for harness=hermes-vps: bin/fm-hermes-vps-bridge.py (the
# local process that renders a captain's remote VPS Hermes /api/ws session
# into an ordinary firstmate pane) and the fleet-wiring pieces that depend on
# it - bin/fm-hermes-lib.sh's bridge process identity, its wiring into
# bin/fm-agent-process-lib.sh's fm_agent_process_classify, and
# bin/fm-busy-lib.sh's live status-pull classifier.
#
# Offline and portable, exactly like tests/fm-hermes-ws.test.sh: the real
# bridge script runs as a real subprocess against the same
# tests/fixtures/fm-hermes-ws-stub-server.py double over a real loopback
# socket, so this proves actual behavior rather than asserting it from
# static text. What is pinned here:
#   1. Bridge process identity (fm_hermes_vps_bridge_path_is_bridge/
#      args_are_bridge/pid_is_bridge) matches the bridge's own
#      interpreter-argv[1] shape and nothing else, and
#      fm_agent_process_classify recognizes it as `agent` so tmux/Herdr pane
#      liveness proves this harness alive/dead the same way every other
#      harness does.
#   2. fm_busy_hermes_vps_agent_running parses session.status's literal
#      "Agent Running: Yes"/"Agent Running: No" line, never anything else.
#   3. The bridge's readiness banner only prints once a real VPS session
#      exists, and carries that session's real session_id.
#   4. Brief delivery: the bridge reads a LOCAL file itself and forwards its
#      CONTENT (not the pointer sentence) as prompt.submit, because a remote
#      VPS session cannot open a local path - and echoes the pointer line
#      with a leading bullet exactly once, for fm-spawn.sh's delivery gate.
#   5. Server-pushed events (message.start/delta/complete) are rendered into
#      the bridge's own stdout in real time.
#   6. /exit sends a real session.close RPC (proven via the stub's RPC log,
#      not just the client's exit code) and then the process exits.
#   7. /interrupt sends a real session.interrupt RPC and never reaches the
#      model as a submitted message.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

BRIDGE="$ROOT/bin/fm-hermes-vps-bridge.py"
STUB="$ROOT/tests/fixtures/fm-hermes-ws-stub-server.py"
TMP_ROOT=$(fm_test_tmproot fm-hermes-vps-bridge)

STUB_TOKEN="probetoken"
STUB_PID=""

free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}

start_stub() {
  local port=$1 rpc_log=${2:-}
  python3 "$STUB" "$port" unused unused "$STUB_TOKEN" "$rpc_log" \
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

# read_line_timeout <fd> <seconds> -> prints the line or fails the test.
read_line_timeout() {
  local fd=$1 secs=$2 line
  if ! IFS= read -r -t "$secs" -u "$fd" line; then
    fail "timed out waiting for a line from the bridge"
  fi
  printf '%s' "$line"
}

# --- 1. process identity -----------------------------------------------------

test_bridge_identity_functions() {
  # shellcheck source=bin/fm-hermes-lib.sh
  . "$ROOT/bin/fm-hermes-lib.sh"

  fm_hermes_vps_bridge_path_is_bridge "$ROOT/bin/fm-hermes-vps-bridge.py" \
    || fail "the real bridge path did not match its own identity check"
  fm_hermes_vps_bridge_path_is_bridge "$ROOT/bin/fm-hermes-ws.py" \
    && fail "the standalone WS client must NOT match the bridge's identity check"
  fm_hermes_vps_bridge_path_is_bridge "/some/other/dir/hermes" \
    && fail "an unrelated path named hermes must not match the bridge's identity check"

  fm_hermes_vps_bridge_args_are_bridge "/usr/bin/python3 $ROOT/bin/fm-hermes-vps-bridge.py --cwd /tmp/x" \
    || fail "python3 <bridge path> ... did not match args_are_bridge"
  fm_hermes_vps_bridge_args_are_bridge "/usr/bin/python3 $ROOT/bin/fm-hermes-ws.py dispatch /tmp/x hi" \
    && fail "the standalone WS client's argv must NOT match the bridge's args check"
  fm_hermes_vps_bridge_args_are_bridge "/bin/zsh -c foo" \
    && fail "an unrelated shell command must not match the bridge's args check"

  pass "identity: fm_hermes_vps_bridge_path_is_bridge/args_are_bridge match only the real bridge script"
}

test_agent_process_classify_recognizes_bridge() {
  # shellcheck source=bin/fm-session-lock-lib.sh
  . "$ROOT/bin/fm-session-lock-lib.sh"
  # shellcheck source=bin/fm-gemini-lib.sh
  . "$ROOT/bin/fm-gemini-lib.sh"
  # shellcheck source=bin/fm-hermes-lib.sh
  . "$ROOT/bin/fm-hermes-lib.sh"
  # shellcheck source=bin/fm-cursor-lib.sh
  [ -f "$ROOT/bin/fm-cursor-lib.sh" ] && . "$ROOT/bin/fm-cursor-lib.sh"
  # shellcheck source=bin/fm-agent-process-lib.sh
  . "$ROOT/bin/fm-agent-process-lib.sh"

  local verdict
  verdict=$(fm_agent_process_classify python3 '' "/usr/bin/python3 $ROOT/bin/fm-hermes-vps-bridge.py --cwd /tmp/x")
  [ "$verdict" = agent ] || fail "fm_agent_process_classify did not classify the bridge's argv as 'agent', got: $verdict"

  pass "fm_agent_process_classify recognizes the bridge's interpreter-argv[1] shape as an agent"
}

# --- 2. busy-lib live status pull --------------------------------------------

test_busy_hermes_vps_agent_running_parses_status() {
  local fakebin
  fakebin="$TMP_ROOT/busy-fakebin"
  mkdir -p "$fakebin"
  # A minimal double for bin/fm-hermes-ws.sh's `status <sid>` output shape,
  # so this pins fm_busy_hermes_vps_agent_running's STRING PARSING against
  # the real vendor-rendered field (docs/verification/hermes.md's live
  # transcript: {"output": "...\nAgent Running: Yes\n"}) without a socket.
  cat > "$fakebin/fm-hermes-ws.sh" <<'SH'
#!/usr/bin/env bash
case "$2" in
  sess-yes) printf '{"output": "Hermes TUI Status\n\nAgent Running: Yes"}\n' ;;
  sess-no) printf '{"output": "Hermes TUI Status\n\nAgent Running: No"}\n' ;;
  sess-garbled) printf '{"output": "not a real status blob"}\n' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/fm-hermes-ws.sh"

  local meta_yes="$TMP_ROOT/yes.meta" meta_no="$TMP_ROOT/no.meta" \
        meta_garbled="$TMP_ROOT/garbled.meta" meta_absent="$TMP_ROOT/absent.meta"
  printf 'harness=hermes-vps\nhermes_vps_session_id=sess-yes\n' > "$meta_yes"
  printf 'harness=hermes-vps\nhermes_vps_session_id=sess-no\n' > "$meta_no"
  printf 'harness=hermes-vps\nhermes_vps_session_id=sess-garbled\n' > "$meta_garbled"
  printf 'harness=hermes-vps\n' > "$meta_absent"

  # fm_meta_get is owned by fm-backend.sh; fm_busy_hermes_vps_agent_running by
  # fm-busy-lib.sh.
  # shellcheck source=bin/fm-backend.sh
  . "$ROOT/bin/fm-backend.sh"
  # shellcheck source=bin/fm-busy-lib.sh
  . "$ROOT/bin/fm-busy-lib.sh"
  # fm-backend.sh's own init unconditionally sets this to its real bin/ dir;
  # fm_busy_hermes_vps_agent_running reads it at CALL time, so overriding it
  # here (after sourcing) routes the live pull at the fake double instead of
  # the real fm-hermes-ws.sh, without needing to fake the whole bin/ tree.
  FM_BACKEND_LIB_DIR="$fakebin"

  local got
  got=$(fm_busy_hermes_vps_agent_running "$meta_yes")
  [ "$got" = yes ] || fail "expected yes for an 'Agent Running: Yes' status blob, got: $got"
  got=$(fm_busy_hermes_vps_agent_running "$meta_no")
  [ "$got" = no ] || fail "expected no for an 'Agent Running: No' status blob, got: $got"
  got=$(fm_busy_hermes_vps_agent_running "$meta_garbled")
  [ "$got" = unknown ] || fail "expected unknown for a status blob with neither marker, got: $got"
  got=$(fm_busy_hermes_vps_agent_running "$meta_absent")
  [ "$got" = unknown ] || fail "expected unknown when no hermes_vps_session_id is recorded, got: $got"

  pass "fm_busy_hermes_vps_agent_running parses session.status's literal Agent Running field, and only that field"
}

# --- 3-7. the real bridge process over a real socket -------------------------

BRIDGE_PID=""
stop_bridge() {
  if [ -n "$BRIDGE_PID" ] && kill -0 "$BRIDGE_PID" 2>/dev/null; then
    kill "$BRIDGE_PID" >/dev/null 2>&1 || true
    wait "$BRIDGE_PID" 2>/dev/null || true
  fi
  BRIDGE_PID=""
}

test_bridge_lifecycle_over_real_socket() {
  local port rpc_log brief_path brief_content line session_id
  port=$(free_port)
  rpc_log="$TMP_ROOT/rpc.jsonl"
  rm -f "$rpc_log"
  start_stub "$port" "$rpc_log"

  brief_path="$TMP_ROOT/launch-brief.md"
  brief_content="## Captain's intent

Do the real work."
  printf '%s\n' "$brief_content" > "$brief_path"

  # bash 3.2 (macOS's system /bin/bash, what `#!/usr/bin/env bash` resolves
  # to here) has no `coproc`, so this drives the bridge's stdio through a
  # pair of named FIFOs on fd 3 (write) and fd 4 (read) instead - the
  # portable equivalent, and still a real pipe to a real subprocess, not a
  # fake terminal. Each fd is opened read-write (`<>`) on its own fifo
  # first: a fifo open for read-write never blocks, and having ANY end
  # already open is what lets the bridge's own blocking read-only/write-only
  # opens on the same fifos return immediately once it starts.
  local in_fifo out_fifo
  in_fifo="$TMP_ROOT/bridge.in"
  out_fifo="$TMP_ROOT/bridge.out"
  rm -f "$in_fifo" "$out_fifo"
  mkfifo "$in_fifo" "$out_fifo"
  exec 3<>"$in_fifo"
  exec 4<>"$out_fifo"

  env -i PATH="$PATH" \
    FM_HERMES_WS_BASE_URL="http://127.0.0.1:$port" \
    FM_HERMES_WS_TOKEN="$STUB_TOKEN" \
    python3 "$BRIDGE" --cwd /tmp/some-worktree <"$in_fifo" >"$out_fifo" 2>"$TMP_ROOT/bridge.err" &
  BRIDGE_PID=$!

  line=$(read_line_timeout 4 10)
  case "$line" in
    'Hermes VPS bridge ready. session_id='*) session_id=${line#*session_id=} ;;
    *) fail "expected the readiness banner with a session_id, got: $line (stderr: $(cat "$TMP_ROOT/bridge.err" 2>/dev/null))" ;;
  esac
  [ -n "$session_id" ] || fail "readiness banner carried no session_id"

  # Brief delivery: the exact pointer sentence fm-spawn.sh types into every
  # launch-then-send harness's pane, with a LOCAL path the bridge can read -
  # this must forward the FILE'S CONTENT, never the sentence itself, because
  # a remote VPS session has no access to this machine's filesystem.
  printf 'Read the brief at %s and follow it exactly.\n' "$brief_path" >&3
  line=$(read_line_timeout 4 10)
  case "$line" in
    "● Read the brief at $brief_path and follow it exactly.") ;;
    *) fail "expected the delivery-confirmation bullet line for the brief pointer, got: $line" ;;
  esac
  if ! grep -q '"method": "prompt.submit"' "$rpc_log" 2>/dev/null; then
    fail "the bridge never sent a real prompt.submit RPC for the brief"
  fi

  # The stub answers ANY prompt.submit with message.start -> message.delta ->
  # message.complete unconditionally, so the bridge's own event-rendering
  # loop must surface the streamed text and the turn-complete marker for
  # real, not from a canned local string.
  local saw_stub_delta=0 saw_turn_complete=0 tries=0
  while [ "$tries" -lt 20 ]; do
    if IFS= read -r -t 2 -u 4 line; then
      case "$line" in
        *stub*) saw_stub_delta=1 ;;
        '[turn complete]') saw_turn_complete=1 ;;
      esac
    fi
    [ "$saw_stub_delta" = 1 ] && [ "$saw_turn_complete" = 1 ] && break
    tries=$((tries + 1))
  done
  [ "$saw_stub_delta" = 1 ] || fail "the bridge never rendered the stub's streamed message.delta text"
  [ "$saw_turn_complete" = 1 ] || fail "the bridge never rendered a [turn complete] marker on message.complete"

  # Interrupt: a local command, not a chat message - must never reach the
  # model as a submitted line, and must call the real RPC.
  printf '/interrupt\n' >&3
  line=$(read_line_timeout 4 10)
  [ "$line" = '[interrupted]' ] || fail "expected [interrupted] after /interrupt, got: $line"
  if ! grep -q '"method": "session.interrupt"' "$rpc_log" 2>/dev/null; then
    fail "the bridge never sent a real session.interrupt RPC for /interrupt"
  fi

  # Exit: closes the server-side session for real (proven via the wire-level
  # RPC log, never just the client's own exit code) and then the local
  # process actually exits.
  printf '/exit\n' >&3
  local waited=0
  while kill -0 "$BRIDGE_PID" 2>/dev/null && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  kill -0 "$BRIDGE_PID" 2>/dev/null && fail "the bridge process did not exit after /exit"
  if ! grep -q '"method": "session.close"' "$rpc_log" 2>/dev/null; then
    fail "the bridge never sent a real session.close RPC on /exit"
  fi
  BRIDGE_PID=""
  exec 3>&- 4>&-

  stop_stub
  pass "bridge lifecycle: readiness, brief-content delivery, event rendering, /interrupt, and /exit all round-trip over a real socket"
}

test_bridge_missing_brief_never_reports_false_delivery() {
  # Regression for the false-delivery finding: when the brief pointer names a
  # path that does not exist, the bridge must NOT echo the pointer sentence
  # back with a leading bullet, because bin/fm-spawn.sh's
  # hermes_vps_delivery_is_confirmed (bin/fm-spawn.sh:3424) treats any pane
  # line matching `^●[[:space:]]*Read the brief at` as proof the brief was
  # delivered. Echoing it here would mark the task CONFIRMED/dispatched while
  # the VPS agent never received real brief content, so the real delivery
  # gate must instead see nothing and eventually time out.
  local port rpc_log missing_path line
  port=$(free_port)
  rpc_log="$TMP_ROOT/rpc-missing-brief.jsonl"
  rm -f "$rpc_log"
  start_stub "$port" "$rpc_log"

  missing_path="$TMP_ROOT/does-not-exist-$$.md"
  rm -f "$missing_path"

  local in_fifo out_fifo
  in_fifo="$TMP_ROOT/bridge-missing.in"
  out_fifo="$TMP_ROOT/bridge-missing.out"
  rm -f "$in_fifo" "$out_fifo"
  mkfifo "$in_fifo" "$out_fifo"
  exec 3<>"$in_fifo"
  exec 4<>"$out_fifo"

  env -i PATH="$PATH" \
    FM_HERMES_WS_BASE_URL="http://127.0.0.1:$port" \
    FM_HERMES_WS_TOKEN="$STUB_TOKEN" \
    python3 "$BRIDGE" --cwd /tmp/some-worktree <"$in_fifo" >"$out_fifo" 2>"$TMP_ROOT/bridge-missing.err" &
  BRIDGE_PID=$!

  line=$(read_line_timeout 4 10)
  case "$line" in
    'Hermes VPS bridge ready. session_id='*) ;;
    *) fail "expected the readiness banner, got: $line" ;;
  esac

  printf 'Read the brief at %s and follow it exactly.\n' "$missing_path" >&3
  line=$(read_line_timeout 4 10)
  case "$line" in
    '●'*) fail "the bridge echoed a bullet-prefixed line for an unreadable brief, which fm-spawn.sh's hermes_vps_delivery_is_confirmed would treat as CONFIRMED delivery: $line" ;;
    *'brief not found'*) ;;
    *) fail "expected a 'brief not found' diagnostic for a missing brief path, got: $line" ;;
  esac

  if grep -q '"method": "prompt.submit"' "$rpc_log" 2>/dev/null; then
    fail "the bridge sent a real prompt.submit RPC for a brief path that does not exist"
  fi

  printf '/exit\n' >&3
  local waited=0
  while kill -0 "$BRIDGE_PID" 2>/dev/null && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  kill -0 "$BRIDGE_PID" 2>/dev/null && fail "the bridge process did not exit after /exit"
  BRIDGE_PID=""
  exec 3>&- 4>&-
  stop_stub

  pass "missing brief: the bridge reports a diagnostic instead of echoing the delivery-confirmation bullet, and never forwards the pointer sentence as a submitted message"
}

test_bridge_closes_session_on_sighup() {
  # Regression for the SIGHUP-leaks-session finding: bin/fm-spawn.sh's
  # hermes_vps_spawn_fail (bin/fm-spawn.sh:~3440) tears the tmux window down
  # via rovo_endpoint_cleanup on any post-readiness launch failure, and
  # bin/backends/tmux.sh's `tmux kill-window` delivers SIGHUP to the bridge's
  # foreground process group. Before this fix, Python's default SIGHUP
  # disposition killed the process immediately, bypassing bridge.shutdown()
  # (and its real session.close RPC) entirely and orphaning a live VPS
  # session. This proves SIGHUP now runs the same clean-shutdown path SIGTERM
  # already used.
  local port rpc_log line
  port=$(free_port)
  rpc_log="$TMP_ROOT/rpc-sighup.jsonl"
  rm -f "$rpc_log"
  start_stub "$port" "$rpc_log"

  local in_fifo out_fifo
  in_fifo="$TMP_ROOT/bridge-sighup.in"
  out_fifo="$TMP_ROOT/bridge-sighup.out"
  rm -f "$in_fifo" "$out_fifo"
  mkfifo "$in_fifo" "$out_fifo"
  exec 3<>"$in_fifo"
  exec 4<>"$out_fifo"

  env -i PATH="$PATH" \
    FM_HERMES_WS_BASE_URL="http://127.0.0.1:$port" \
    FM_HERMES_WS_TOKEN="$STUB_TOKEN" \
    python3 "$BRIDGE" --cwd /tmp/some-worktree <"$in_fifo" >"$out_fifo" 2>"$TMP_ROOT/bridge-sighup.err" &
  BRIDGE_PID=$!

  line=$(read_line_timeout 4 10)
  case "$line" in
    'Hermes VPS bridge ready. session_id='*) ;;
    *) fail "expected the readiness banner, got: $line" ;;
  esac

  kill -HUP "$BRIDGE_PID"

  local waited=0
  while kill -0 "$BRIDGE_PID" 2>/dev/null && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  kill -0 "$BRIDGE_PID" 2>/dev/null && fail "the bridge process did not exit after SIGHUP"
  BRIDGE_PID=""
  exec 3>&- 4>&-

  if ! grep -q '"method": "session.close"' "$rpc_log" 2>/dev/null; then
    fail "the bridge never sent a real session.close RPC when killed with SIGHUP"
  fi

  stop_stub
  pass "SIGHUP: the bridge runs the same clean-shutdown path as SIGTERM, sending a real session.close RPC before exiting"
}

test_bridge_identity_functions
test_agent_process_classify_recognizes_bridge
test_busy_hermes_vps_agent_running_parses_status
test_bridge_lifecycle_over_real_socket
stop_bridge
test_bridge_missing_brief_never_reports_false_delivery
stop_bridge
test_bridge_closes_session_on_sighup
stop_bridge
