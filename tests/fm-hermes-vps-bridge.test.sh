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
#   8. Status/report/inbox protocol (the fix for the live-verification
#      finding that a hermes-vps crewmate had no way back to this machine's
#      filesystem at all, not even to report its own blocked status): a
#      FIRSTMATE-STATUS line in a completed turn's real text lands in the
#      real local status file; a malformed one is rejected and replaced with
#      a bridge-authored diagnostic instead of being written verbatim; a
#      FIRSTMATE-REPORT block lands in the real local report file; a
#      pre-existing steering inbox record is delivered and acknowledged
#      (moved to handled/) without the remote agent touching either path;
#      and the doorbell line typed into every pane for a steering message is
#      recognized and swallowed locally rather than forwarded as chat text
#      the remote agent could never act on. The stub server's STUB_ECHO:
#      prefix (tests/fixtures/fm-hermes-ws-stub-server.py) is what lets these
#      tests control message.complete's own final text over the real socket.
#   9. Working indicator (the fix for a genuinely working but slow turn
#      being indistinguishable from a dead one, since the pane has no
#      composer/spinner): a bare "[working...]" line renders promptly on
#      message.start, before any delta/tool content, and nothing else
#      renders until the turn's real response lands - proven with the
#      stub's STUB_DELAY: prefix, which sleeps server-side between
#      message.start and the rest of the turn to stand in for real slow
#      latency (e.g. a sleep-based VPS command) without slowing this suite.
#  10. Sending indicator (the fix for [working...] itself printing too LATE
#      - only once the server confirms the turn, after the full round trip
#      has already begun): a bare "[sending...]" line renders the instant a
#      submitted line reaches _forward(), before the RPC call, distinct from
#      "[working...]" which still means the server has confirmed the turn is
#      running - proven on the ordinary fast path (no delay) so the two
#      really are separate renders in order, not one renamed.
#  11. Ready-for-input marker (the fix for no visible signal that the pane
#      was idle and ready to accept a line, unlike every other verified
#      harness's composer): a bare "❯" renders once whenever the bridge
#      becomes idle (readiness, and after every message.complete/error), and
#      never renders again until the next such transition - proven by
#      scanning an entire busy stretch for a stray mid-turn "❯".
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

  # A fresh session opens idle: the ready-for-input marker renders once,
  # right after the banner, before any input is sent.
  line=$(read_line_timeout 4 10)
  [ "$line" = '❯' ] || fail "expected a ready marker (❯) once the bridge opened idle, got: $line"

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

  # The ready marker renders once more right after the turn completes, since
  # the session is idle and ready for a new line again.
  line=$(read_line_timeout 4 10)
  [ "$line" = '❯' ] || fail "expected a ready marker (❯) once the turn completed, got: $line"

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

  line=$(read_line_timeout 4 10)
  [ "$line" = '❯' ] || fail "expected a ready marker (❯) once the bridge opened idle, got: $line"

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

# --- 8. status/report/inbox protocol -----------------------------------------

# Launches the bridge with the three protocol flags armed, over fifos named
# from <tag>, and waits for its readiness banner. Sets BRIDGE_PID.
# These tests assert on the real local FILES the bridge writes, not on its
# rendered pane output, so a background drain continuously empties fd 4
# (DRAIN_PID) once readiness is confirmed - the OS pipe buffer is small
# enough that a bridge rendering its usual echo/delta/turn-complete output
# with nobody reading fd 4 would otherwise block INSIDE the bridge process
# on a full pipe, silently wedging it (no stderr, no crash) before it ever
# reaches the RPC that would satisfy the file-content assertion below.
DRAIN_PID=""
stop_drain() {
  if [ -n "$DRAIN_PID" ] && kill -0 "$DRAIN_PID" 2>/dev/null; then
    kill "$DRAIN_PID" >/dev/null 2>&1 || true
    wait "$DRAIN_PID" 2>/dev/null || true
  fi
  DRAIN_PID=""
}
start_bridge_with_protocol() {  # <port> <tag> <status-file> <report-file> <inbox-dir>
  local port=$1 tag=$2 status_file=$3 report_file=$4 inbox_dir=$5 line
  local in_fifo="$TMP_ROOT/$tag.in" out_fifo="$TMP_ROOT/$tag.out"
  rm -f "$in_fifo" "$out_fifo"
  mkfifo "$in_fifo" "$out_fifo"
  exec 3<>"$in_fifo"
  exec 4<>"$out_fifo"
  env -i PATH="$PATH" \
    FM_HERMES_WS_BASE_URL="http://127.0.0.1:$port" \
    FM_HERMES_WS_TOKEN="$STUB_TOKEN" \
    python3 "$BRIDGE" --cwd /tmp/some-worktree \
      --status-file "$status_file" --report-file "$report_file" --inbox-dir "$inbox_dir" \
      <"$in_fifo" >"$out_fifo" 2>"$TMP_ROOT/$tag.err" &
  BRIDGE_PID=$!
  line=$(read_line_timeout 4 10)
  case "$line" in
    'Hermes VPS bridge ready.'*) ;;
    *) fail "expected the readiness banner, got: $line (stderr: $(cat "$TMP_ROOT/$tag.err" 2>/dev/null))" ;;
  esac
  cat <&4 > "$TMP_ROOT/$tag.rendered.log" 2>/dev/null &
  DRAIN_PID=$!
}

# wait_for_file_content <path> <needle> <seconds> -> fails the test if <path>
# never contains <needle> within the deadline. Polling, not a fixed sleep,
# because delivery timing (inbox poll, a full round trip to the stub and
# back) is not deterministic to the millisecond.
wait_for_file_content() {
  local path=$1 needle=$2 secs=$3 tries
  tries=$((secs * 10))
  while [ "$tries" -gt 0 ]; do
    if [ -f "$path" ] && grep -qF "$needle" "$path" 2>/dev/null; then
      return 0
    fi
    sleep 0.1
    tries=$((tries - 1))
  done
  return 1
}

test_bridge_status_line_over_real_socket() {
  local port rpc_log status_file report_file inbox_dir
  port=$(free_port)
  rpc_log="$TMP_ROOT/rpc-status.jsonl"
  rm -f "$rpc_log"
  start_stub "$port" "$rpc_log"

  status_file="$TMP_ROOT/status-8a.status"
  report_file="$TMP_ROOT/status-8a-report.md"
  inbox_dir="$TMP_ROOT/status-8a.inbox"
  rm -f "$status_file"

  start_bridge_with_protocol "$port" bridge-status "$status_file" "$report_file" "$inbox_dir"

  # A real completed turn whose text carries a valid FIRSTMATE-STATUS line -
  # the stub echoes it back verbatim as message.complete's own text, exactly
  # like a real remote agent's reply would.
  printf 'STUB_ECHO:FIRSTMATE-STATUS: working: setup complete\n' >&3
  wait_for_file_content "$status_file" 'working: setup complete' 10 \
    || fail "expected the real local status file to receive 'working: setup complete', got: $(cat "$status_file" 2>/dev/null)"
  grep -q '^FIRSTMATE-STATUS:' "$status_file" 2>/dev/null \
    && fail "the sentinel prefix must never reach the real status file, only the state:note it wraps"

  printf '/exit\n' >&3
  local waited=0
  while kill -0 "$BRIDGE_PID" 2>/dev/null && [ "$waited" -lt 50 ]; do sleep 0.1; waited=$((waited + 1)); done
  BRIDGE_PID=""
  stop_drain
  exec 3>&- 4>&-
  stop_stub
  pass "status protocol: a valid FIRSTMATE-STATUS line in a completed turn's real text lands in the real local status file, sentinel stripped"
}

test_bridge_recovers_status_line_split_by_tool_call() {
  # Regression for the live-verification finding (data/hv-protocol-verify/
  # report.md): a turn that emits text, then a tool call, then more text
  # fires exactly ONE message.start/message.complete pair for the WHOLE
  # turn on the real server, and message.complete's own "text" field holds
  # ONLY the last segment - an opening FIRSTMATE-STATUS line before the
  # agent reaches for a tool would be silently dropped if the bridge
  # trusted that field alone. The bridge must instead use the turn's full
  # accumulated delta text, which carries both segments.
  local port rpc_log status_file report_file inbox_dir
  port=$(free_port)
  rpc_log="$TMP_ROOT/rpc-split.jsonl"
  rm -f "$rpc_log"
  start_stub "$port" "$rpc_log"

  status_file="$TMP_ROOT/status-8e.status"
  report_file="$TMP_ROOT/status-8e-report.md"
  inbox_dir="$TMP_ROOT/status-8e.inbox"
  rm -f "$status_file"

  start_bridge_with_protocol "$port" bridge-split "$status_file" "$report_file" "$inbox_dir"

  printf 'STUB_SPLIT_ECHO:FIRSTMATE-STATUS: working: before the tool call|||FIRSTMATE-STATUS: done: after the tool call\n' >&3
  wait_for_file_content "$status_file" 'done: after the tool call' 10 \
    || fail "expected the second (message.complete-carried) segment to land, got: $(cat "$status_file" 2>/dev/null)"
  wait_for_file_content "$status_file" 'working: before the tool call' 2 \
    || fail "expected the FIRST segment (message.delta-only, absent from message.complete's own text) to also land - got: $(cat "$status_file" 2>/dev/null)"

  printf '/exit\n' >&3
  local waited=0
  while kill -0 "$BRIDGE_PID" 2>/dev/null && [ "$waited" -lt 50 ]; do sleep 0.1; waited=$((waited + 1)); done
  BRIDGE_PID=""
  stop_drain
  exec 3>&- 4>&-
  stop_stub
  pass "status protocol: a FIRSTMATE-STATUS line in an EARLIER text segment, before a tool call, still lands even though message.complete's own text field drops it"
}

test_bridge_rejects_malformed_status_line() {
  local port rpc_log status_file report_file inbox_dir
  port=$(free_port)
  rpc_log="$TMP_ROOT/rpc-malformed.jsonl"
  rm -f "$rpc_log"
  start_stub "$port" "$rpc_log"

  status_file="$TMP_ROOT/status-8b.status"
  report_file="$TMP_ROOT/status-8b-report.md"
  inbox_dir="$TMP_ROOT/status-8b.inbox"
  rm -f "$status_file"

  start_bridge_with_protocol "$port" bridge-malformed "$status_file" "$report_file" "$inbox_dir"

  # "not-a-real-state" is not in the state vocabulary: the remote agent must
  # never be able to make the bridge write arbitrary text to the status file
  # merely by emitting a line that LOOKS like the sentinel shape.
  printf 'STUB_ECHO:FIRSTMATE-STATUS: not-a-real-state: oops\n' >&3
  wait_for_file_content "$status_file" 'malformed status line' 10 \
    || fail "expected a bridge-authored malformed-status diagnostic, got: $(cat "$status_file" 2>/dev/null)"
  grep -qE '^not-a-real-state:' "$status_file" 2>/dev/null \
    && fail "the invalid state line must never be written verbatim as though it were a real status update"
  grep -q '^blocked:' "$status_file" 2>/dev/null \
    || fail "the malformed-status diagnostic must itself be a valid blocked: line so firstmate is woken, got: $(cat "$status_file" 2>/dev/null)"

  printf '/exit\n' >&3
  local waited=0
  while kill -0 "$BRIDGE_PID" 2>/dev/null && [ "$waited" -lt 50 ]; do sleep 0.1; waited=$((waited + 1)); done
  BRIDGE_PID=""
  stop_drain
  exec 3>&- 4>&-
  stop_stub
  pass "status protocol: a malformed FIRSTMATE-STATUS line is rejected and replaced with a bridge-authored blocked: diagnostic, never written verbatim"
}

test_bridge_report_and_inbox_over_real_socket() {
  local port rpc_log status_file report_file inbox_dir handled_dir
  port=$(free_port)
  rpc_log="$TMP_ROOT/rpc-report.jsonl"
  rm -f "$rpc_log"
  start_stub "$port" "$rpc_log"

  status_file="$TMP_ROOT/status-8c.status"
  report_file="$TMP_ROOT/status-8c-report.md"
  inbox_dir="$TMP_ROOT/status-8c.inbox"
  handled_dir="$inbox_dir/handled"
  rm -rf "$status_file" "$report_file" "$inbox_dir"
  mkdir -p "$handled_dir"

  # A steering inbox record in bin/fm-task-inbox-lib.sh's own format: header
  # lines, a bare "--" separator, then the body verbatim - the remote agent
  # cannot read this path itself, so the bridge must poll, deliver, and
  # acknowledge it unassisted. The body carries a STUB_ECHO: turn that
  # itself contains a multi-line FIRSTMATE-REPORT block plus a status line,
  # proving embedded newlines in one forwarded record survive intact (the
  # thing a line-oriented typed-pane input could never carry in one message).
  printf 'schema=fm-task-inbox.v1\nat=2026-01-01T00:00:00Z\n--\nSTUB_ECHO:FIRSTMATE-REPORT-BEGIN\nfindings: it works\nline two\nFIRSTMATE-REPORT-END\nFIRSTMATE-STATUS: done: wrote the report' \
    > "$inbox_dir/001.msg"

  start_bridge_with_protocol "$port" bridge-report "$status_file" "$report_file" "$inbox_dir"

  wait_for_file_content "$report_file" 'findings: it works' 10 \
    || fail "expected the real local report file to receive the FIRSTMATE-REPORT block's content, got: $(cat "$report_file" 2>/dev/null)"
  grep -qF 'line two' "$report_file" 2>/dev/null \
    || fail "expected the report's second line to survive, got: $(cat "$report_file" 2>/dev/null)"
  grep -qE '^(FIRSTMATE-REPORT-(BEGIN|END)|STUB_ECHO:)' "$report_file" 2>/dev/null \
    && fail "the report markers/echo prefix must never leak into the real report file"

  wait_for_file_content "$status_file" 'done: wrote the report' 10 \
    || fail "expected the real local status file to receive 'done: wrote the report', got: $(cat "$status_file" 2>/dev/null)"

  local tries=100
  while [ ! -f "$handled_dir/001.msg" ] && [ "$tries" -gt 0 ]; do sleep 0.1; tries=$((tries - 1)); done
  [ -f "$handled_dir/001.msg" ] \
    || fail "expected the delivered inbox record to be moved to handled/ as its acknowledgement"
  [ -f "$inbox_dir/001.msg" ] \
    && fail "the delivered inbox record must be moved out of the inbox root, not merely copied"
  if ! grep -q '"method": "prompt.submit"' "$rpc_log" 2>/dev/null; then
    fail "the bridge never sent a real prompt.submit RPC to deliver the inbox record's body"
  fi

  printf '/exit\n' >&3
  local waited=0
  while kill -0 "$BRIDGE_PID" 2>/dev/null && [ "$waited" -lt 50 ]; do sleep 0.1; waited=$((waited + 1)); done
  BRIDGE_PID=""
  stop_drain
  exec 3>&- 4>&-
  stop_stub
  pass "report + inbox protocol: the bridge polls, delivers, and acknowledges a steering record unassisted, and a FIRSTMATE-REPORT block lands in the real local report file"
}

test_bridge_preserves_inbox_order_on_forward_failure() {
  # Regression for poll_inbox()'s FIFO order guarantee: a record whose
  # forward permanently fails (both the initial attempt and the
  # reconnect-retry) must stop the sweep, not let a later, deliverable
  # record jump ahead of it. TRIGGER_RPC_ERROR (tests/fixtures/
  # fm-hermes-ws-stub-server.py) makes the stub fail the RPC itself,
  # synchronously - unlike TRIGGER_ERROR, which only fails later, mid-turn,
  # as an async event _forward() never waits for.
  local port rpc_log status_file report_file inbox_dir handled_dir submit_count
  port=$(free_port)
  rpc_log="$TMP_ROOT/rpc-order.jsonl"
  rm -f "$rpc_log"
  start_stub "$port" "$rpc_log"

  status_file="$TMP_ROOT/status-8g.status"
  report_file="$TMP_ROOT/status-8g-report.md"
  inbox_dir="$TMP_ROOT/status-8g.inbox"
  handled_dir="$inbox_dir/handled"
  rm -rf "$status_file" "$report_file" "$inbox_dir"
  mkdir -p "$handled_dir"

  printf 'schema=fm-task-inbox.v1\nat=2026-01-01T00:00:00Z\n--\nTRIGGER_RPC_ERROR' \
    > "$inbox_dir/001.msg"
  printf 'schema=fm-task-inbox.v1\nat=2026-01-01T00:00:01Z\n--\nSTUB_ECHO:should never be delivered' \
    > "$inbox_dir/002.msg"

  start_bridge_with_protocol "$port" bridge-order "$status_file" "$report_file" "$inbox_dir"

  # Wait for both of 001's forward attempts (initial + reconnect-retry) to
  # reach the stub before asserting the sweep stopped there.
  local tries=100
  while :; do
    submit_count=$(grep -c '"method": "prompt.submit"' "$rpc_log" 2>/dev/null || true)
    [ -n "$submit_count" ] || submit_count=0
    [ "$submit_count" -ge 2 ] && break
    tries=$((tries - 1))
    [ "$tries" -gt 0 ] || fail "expected both of 001's forward attempts (initial + reconnect-retry) to reach the stub, got: $(cat "$rpc_log" 2>/dev/null)"
    sleep 0.1
  done

  # Give a regressed continue-past-failure path time to also process 002.
  sleep 1

  [ -f "$inbox_dir/001.msg" ] \
    || fail "001 must stay in the inbox root after its forward permanently fails, not be dropped"
  [ -f "$handled_dir/001.msg" ] \
    && fail "001's forward failed, so it must never be acknowledged into handled/"
  [ -f "$inbox_dir/002.msg" ] \
    || fail "a later record must not be delivered while an earlier one is still stalled - 002 was removed from the inbox root"
  [ -f "$handled_dir/002.msg" ] \
    && fail "002 must not jump ahead of a still-pending 001 and be delivered/acknowledged out of order"
  submit_count=$(grep -c '"method": "prompt.submit"' "$rpc_log" 2>/dev/null || true)
  [ -n "$submit_count" ] || submit_count=0
  [ "$submit_count" -eq 2 ] \
    || fail "002 must never be forwarded to the remote session while 001 is still pending, got $submit_count prompt.submit calls: $(cat "$rpc_log" 2>/dev/null)"

  printf '/exit\n' >&3
  local waited=0
  while kill -0 "$BRIDGE_PID" 2>/dev/null && [ "$waited" -lt 50 ]; do sleep 0.1; waited=$((waited + 1)); done
  BRIDGE_PID=""
  stop_drain
  exec 3>&- 4>&-
  stop_stub
  pass "report + inbox protocol: a failed forward blocks the sweep so a later record cannot jump ahead of a still-pending one"
}

test_bridge_suppresses_inbox_doorbell_line() {
  local port rpc_log status_file report_file inbox_dir
  port=$(free_port)
  rpc_log="$TMP_ROOT/rpc-doorbell.jsonl"
  rm -f "$rpc_log"
  start_stub "$port" "$rpc_log"

  status_file="$TMP_ROOT/status-8d.status"
  report_file="$TMP_ROOT/status-8d-report.md"
  inbox_dir="$TMP_ROOT/status-8d.inbox"
  rm -f "$status_file"

  start_bridge_with_protocol "$port" bridge-doorbell "$status_file" "$report_file" "$inbox_dir"

  # The exact self-describing doorbell shape fm_task_inbox_doorbell_line()
  # (bin/fm-task-inbox-lib.sh) types into every pane for a steering message -
  # it names a LOCAL path the remote agent can never reach, so the bridge
  # must swallow it locally rather than forward it as chat text.
  printf ": Firstmate instruction waiting: list '/Users/someone/firstmate/state/x.inbox'/*.msg and, in numeric order, read and act on each, then mv each handled file to '/Users/someone/firstmate/state/x.inbox'/handled/.\n" >&3

  # Prove the bridge is still alive and responsive with an ordinary line
  # afterward, and that ONLY that ordinary line reached the model.
  printf 'STUB_ECHO:FIRSTMATE-STATUS: working: still alive\n' >&3
  wait_for_file_content "$status_file" 'working: still alive' 10 \
    || fail "expected the bridge to remain responsive after the doorbell line, got: $(cat "$status_file" 2>/dev/null)"

  local submit_count
  submit_count=$(grep -c '"method": "prompt.submit"' "$rpc_log" 2>/dev/null || true)
  [ "$submit_count" = 1 ] \
    || fail "expected exactly one prompt.submit RPC (the ordinary line only, never the doorbell), got: $submit_count"

  printf '/exit\n' >&3
  local waited=0
  while kill -0 "$BRIDGE_PID" 2>/dev/null && [ "$waited" -lt 50 ]; do sleep 0.1; waited=$((waited + 1)); done
  BRIDGE_PID=""
  stop_drain
  exec 3>&- 4>&-
  stop_stub
  pass "the inbox doorbell line is recognized and swallowed locally, never forwarded as chat text the remote agent cannot act on"
}

# --- 9. working indicator on a slow turn -------------------------------------

test_bridge_renders_working_indicator_before_slow_response() {
  # Captain-reported gap: the pane is a scrolling event-rendered log with no
  # composer/spinner (references/harness/hermes-vps.md's "Composer" row), so
  # a genuinely working but slow turn - real VPS latency, or e.g. a
  # sleep-based command - rendered NOTHING at all until it eventually
  # completed, indistinguishable from a dead session. STUB_DELAY stands in
  # for that real latency without slowing this suite down for real: it
  # sleeps server-side AFTER message.start (already sent unconditionally by
  # the stub) and BEFORE any further event.
  #
  # Reads directly off the bridge's own stdout fifo (like
  # test_bridge_lifecycle_over_real_socket), never a background `cat`
  # redirected into a file: cat's stdout is block-buffered once redirected
  # to a regular file, so a few-byte "[working...]" line can sit in that
  # buffer unflushed for an arbitrary time - exactly the kind of
  # test-only timing illusion this test exists to rule out for real.
  local port rpc_log line
  port=$(free_port)
  rpc_log="$TMP_ROOT/rpc-working.jsonl"
  rm -f "$rpc_log"
  start_stub "$port" "$rpc_log"

  local in_fifo="$TMP_ROOT/bridge-working.in" out_fifo="$TMP_ROOT/bridge-working.out"
  rm -f "$in_fifo" "$out_fifo"
  mkfifo "$in_fifo" "$out_fifo"
  exec 3<>"$in_fifo"
  exec 4<>"$out_fifo"
  env -i PATH="$PATH" \
    FM_HERMES_WS_BASE_URL="http://127.0.0.1:$port" \
    FM_HERMES_WS_TOKEN="$STUB_TOKEN" \
    python3 "$BRIDGE" --cwd /tmp/some-worktree \
      <"$in_fifo" >"$out_fifo" 2>"$TMP_ROOT/bridge-working.err" &
  BRIDGE_PID=$!
  line=$(read_line_timeout 4 10)
  case "$line" in
    'Hermes VPS bridge ready.'*) ;;
    *) fail "expected the readiness banner, got: $line (stderr: $(cat "$TMP_ROOT/bridge-working.err" 2>/dev/null))" ;;
  esac

  line=$(read_line_timeout 4 10)
  [ "$line" = '❯' ] || fail "expected a ready marker (❯) once the bridge opened idle, got: $line"

  printf 'STUB_DELAY:4:slow reply landed\n' >&3
  line=$(read_line_timeout 4 10)
  case "$line" in
    "● STUB_DELAY:4:slow reply landed") ;;
    *) fail "expected the delivery-confirmation bullet for the submitted line, got: $line" ;;
  esac

  # The local "sending" signal renders the instant the line is handed to
  # _forward(), before any RPC round trip - so it must appear here even
  # though the server is about to sit on this turn for 4s.
  line=$(read_line_timeout 4 10)
  [ "$line" = '[sending...]' ] \
    || fail "expected a [sending...] indicator immediately on local submit, before any server confirmation, got: $line"

  line=$(read_line_timeout 4 10)
  [ "$line" = '[working...]' ] \
    || fail "expected a [working...] indicator to render promptly on message.start, got: $line"
  local t_indicator
  t_indicator=$(date +%s)

  # A bounded "nothing arrives within N seconds" race is inherently
  # flaky under real scheduling jitter (a loaded machine can stall the
  # reader briefly with no bearing on whether the SERVER actually
  # delayed). Measuring elapsed wall time between the indicator and the
  # delayed content instead proves the same fact without racing against
  # it: a slow reader only INCREASES the measured gap, it can never
  # shrink it, so this assertion cannot spuriously fail under load the
  # way a tight timeout-races-content check can.
  line=$(read_line_timeout 4 15)
  [ "$line" = 'slow reply landed' ] \
    || fail "expected the delayed content once the stub's delay elapsed, got: $line"
  local t_content elapsed
  t_content=$(date +%s)
  elapsed=$((t_content - t_indicator))
  [ "$elapsed" -ge 2 ] \
    || fail "expected at least 2s between [working...] and the delayed content (stub delay is 4s), only $elapsed s elapsed - the indicator likely rendered late instead of promptly on message.start"

  line=$(read_line_timeout 4 10)
  [ "$line" = '[turn complete]' ] \
    || fail "expected a [turn complete] marker once the delayed response landed, got: $line"

  printf '/exit\n' >&3
  local waited=0
  while kill -0 "$BRIDGE_PID" 2>/dev/null && [ "$waited" -lt 50 ]; do sleep 0.1; waited=$((waited + 1)); done
  BRIDGE_PID=""
  exec 3>&- 4>&-
  stop_stub
  pass "working indicator: [working...] renders immediately on message.start and nothing else renders until the delayed response lands"
}

# --- 10. sending indicator on local submit -----------------------------------

test_bridge_renders_sending_indicator_before_working_on_ordinary_submit() {
  # Captain-reported gap: [working...] only ever rendered once the SERVER
  # confirmed the turn (message.start), i.e. after the full round trip to
  # the VPS had already begun - a captain pressing Enter got no feedback at
  # all until that round trip completed. _forward() now prints a bare
  # "[sending...]" line the instant it is about to issue the RPC, before the
  # RPC call, distinct from "[working...]" (server-confirmed). This pins the
  # ORDER on the ordinary fast path (no STUB_DELAY): echo, then
  # "[sending...]", then "[working...]" once message.start actually arrives
  # - proving the two are genuinely separate signals, not one renamed.
  local port rpc_log line
  port=$(free_port)
  rpc_log="$TMP_ROOT/rpc-sending.jsonl"
  rm -f "$rpc_log"
  start_stub "$port" "$rpc_log"

  local in_fifo="$TMP_ROOT/bridge-sending.in" out_fifo="$TMP_ROOT/bridge-sending.out"
  rm -f "$in_fifo" "$out_fifo"
  mkfifo "$in_fifo" "$out_fifo"
  exec 3<>"$in_fifo"
  exec 4<>"$out_fifo"
  env -i PATH="$PATH" \
    FM_HERMES_WS_BASE_URL="http://127.0.0.1:$port" \
    FM_HERMES_WS_TOKEN="$STUB_TOKEN" \
    python3 "$BRIDGE" --cwd /tmp/some-worktree \
      <"$in_fifo" >"$out_fifo" 2>"$TMP_ROOT/bridge-sending.err" &
  BRIDGE_PID=$!

  line=$(read_line_timeout 4 10)
  case "$line" in
    'Hermes VPS bridge ready.'*) ;;
    *) fail "expected the readiness banner, got: $line (stderr: $(cat "$TMP_ROOT/bridge-sending.err" 2>/dev/null))" ;;
  esac
  line=$(read_line_timeout 4 10)
  [ "$line" = '❯' ] || fail "expected a ready marker (❯) once the bridge opened idle, got: $line"

  printf 'hello captain\n' >&3
  line=$(read_line_timeout 4 10)
  [ "$line" = '● hello captain' ] || fail "expected the delivery-confirmation bullet for the submitted line, got: $line"

  line=$(read_line_timeout 4 10)
  [ "$line" = '[sending...]' ] \
    || fail "expected [sending...] immediately after the submitted line is echoed, before any server confirmation, got: $line"

  line=$(read_line_timeout 4 10)
  [ "$line" = '[working...]' ] \
    || fail "expected [working...] once message.start actually confirms the turn is running, got: $line"

  if ! grep -q '"method": "prompt.submit"' "$rpc_log" 2>/dev/null; then
    fail "the bridge never sent a real prompt.submit RPC for the submitted line"
  fi

  printf '/exit\n' >&3
  local waited=0
  while kill -0 "$BRIDGE_PID" 2>/dev/null && [ "$waited" -lt 50 ]; do sleep 0.1; waited=$((waited + 1)); done
  BRIDGE_PID=""
  exec 3>&- 4>&-
  stop_stub
  pass "sending indicator: [sending...] renders on local submit before [working...] confirms the server round trip is in flight"
}

# --- 11. ready-for-input marker ----------------------------------------------

test_bridge_renders_ready_marker_when_idle_and_absent_while_busy() {
  # Captain-reported gap: the pane had no visible signal that it was idle and
  # ready to accept a line, unlike every other verified harness's composer.
  # A bare "❯" now renders once whenever the bridge becomes idle (readiness,
  # and after every message.complete/error resets busy to False), and - since
  # this is an append-only scrollback with no way to erase a prior line - the
  # regression this pins is that NO new "❯" appears anywhere between a
  # submission and the turn completing: the busy stretch's own lines
  # (bullet, [sending...], [working...], streamed content, [turn complete])
  # are exactly what's on screen, with the marker only reappearing once more
  # after the turn is done.
  local port rpc_log line
  port=$(free_port)
  rpc_log="$TMP_ROOT/rpc-ready.jsonl"
  rm -f "$rpc_log"
  start_stub "$port" "$rpc_log"

  local in_fifo="$TMP_ROOT/bridge-ready.in" out_fifo="$TMP_ROOT/bridge-ready.out"
  rm -f "$in_fifo" "$out_fifo"
  mkfifo "$in_fifo" "$out_fifo"
  exec 3<>"$in_fifo"
  exec 4<>"$out_fifo"
  env -i PATH="$PATH" \
    FM_HERMES_WS_BASE_URL="http://127.0.0.1:$port" \
    FM_HERMES_WS_TOKEN="$STUB_TOKEN" \
    python3 "$BRIDGE" --cwd /tmp/some-worktree \
      <"$in_fifo" >"$out_fifo" 2>"$TMP_ROOT/bridge-ready.err" &
  BRIDGE_PID=$!

  line=$(read_line_timeout 4 10)
  case "$line" in
    'Hermes VPS bridge ready.'*) ;;
    *) fail "expected the readiness banner, got: $line (stderr: $(cat "$TMP_ROOT/bridge-ready.err" 2>/dev/null))" ;;
  esac
  line=$(read_line_timeout 4 10)
  [ "$line" = '❯' ] || fail "expected a ready marker (❯) once the bridge opened idle, got: $line"

  printf 'hello captain\n' >&3

  # Every line from here through [turn complete] is the busy stretch: none
  # of them may be a bare "❯", or the marker would be lying about being
  # ready for input while a submission is still in flight.
  local saw_turn_complete=0 tries=0
  while [ "$tries" -lt 20 ]; do
    if IFS= read -r -t 2 -u 4 line; then
      [ "$line" = '❯' ] && fail "a ready marker (❯) rendered mid-turn, while a submission was in flight: line was '$line'"
      [ "$line" = '[turn complete]' ] && { saw_turn_complete=1; break; }
    fi
    tries=$((tries + 1))
  done
  [ "$saw_turn_complete" = 1 ] || fail "never saw [turn complete] while scanning for a stray mid-turn ready marker"

  # The marker reappears exactly once more, right after the turn completes.
  line=$(read_line_timeout 4 10)
  [ "$line" = '❯' ] || fail "expected a ready marker (❯) once the turn completed, got: $line"

  printf '/exit\n' >&3
  local waited=0
  while kill -0 "$BRIDGE_PID" 2>/dev/null && [ "$waited" -lt 50 ]; do sleep 0.1; waited=$((waited + 1)); done
  BRIDGE_PID=""
  exec 3>&- 4>&-
  stop_stub
  pass "ready marker: ❯ renders when idle and never mid-turn, reappearing once the turn completes"
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
test_bridge_status_line_over_real_socket
stop_bridge
test_bridge_recovers_status_line_split_by_tool_call
stop_bridge
test_bridge_rejects_malformed_status_line
stop_bridge
test_bridge_report_and_inbox_over_real_socket
stop_bridge
test_bridge_preserves_inbox_order_on_forward_failure
stop_bridge
test_bridge_suppresses_inbox_doorbell_line
stop_bridge
test_bridge_renders_working_indicator_before_slow_response
stop_bridge
test_bridge_renders_sending_indicator_before_working_on_ordinary_submit
stop_bridge
test_bridge_renders_ready_marker_when_idle_and_absent_while_busy
stop_bridge
