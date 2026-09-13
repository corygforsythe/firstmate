#!/usr/bin/env bash
# Behavior tests for the verified Hermes Agent (`hermes` CLI) crewmate/scout
# adapter.
#
# The facts pinned here are the ones a Hermes release could silently change
# and the ones a wrong guess would make dangerous:
#   1. hermes ships as a python venv script, so its live process reports comm
#      as the interpreter (python3/python3.11) and argv[0] is that same
#      interpreter path - only argv[1], the script path, carries the
#      identity. This mirrors bin/fm-gemini-lib.sh's node-bundle shape.
#   2. `--cli` is the launch flag (never --tui, which hits a Responses-API
#      wall on a GitHub Copilot integrator; never -z/--oneshot, which never
#      even attempts a turn), launched BARE with the brief pointer sent only
#      after a readiness gate.
#   3. Delivery confirmation is deliberately NOT gated on composer-emptiness
#      like rovo/kimi: hermes's busy prompt row (`⚕ ❯ msg=interrupt · ...`)
#      reads as an unrecognized composer shape ("unknown"), not "empty", for
#      the agent's entire first turn - confirmed live. Delivery is instead
#      confirmed by the leading `●` hermes prepends to an accepted, echoed
#      message, or by the context token count advancing off `--`.
#   4. hermes has no verified bin/fm-control.sh lifecycle support at all:
#      Ctrl+C exits the whole session and Escape does not cancel a running
#      tool call (both confirmed live), so it is deliberately absent from
#      every fm-control-lib.sh table rather than guessed into one.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# See tests/fm-rovo-harness.test.sh for why ambient harness markers are
# dropped: a suite run from inside Cursor, Claude, Pi, or Grok inherits those
# markers, which would otherwise outrank the fake ancestry the detection
# cases below set up.
unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS \
  ATLASSIAN_AGENT_TYPE ROVODEV_CLI GEMINI_CLI

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-hermes-harness)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

# A stateful fake tmux for hermes's launch-then-send shape (the same shape
# kimi/rovo use): `--cli` takes no positional prompt, so hermes launches BARE
# and only receives an absolute brief pointer after a readiness gate, then a
# delivery gate. This fake renders a hermes-shaped screen that advances
# through launched -> ready -> pointer-typed -> delivered as the real spawn
# drives it, so the launch command, the typed pointer, and both gates are
# exercised through their real code paths rather than asserted from static
# text.
make_hermes_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_TMUX_CALL_LOG"
state=$(cat "$FM_FAKE_HERMES_STATE" 2>/dev/null || true)
fake_screen() {
  case "$state" in
    ready)
      printf 'Welcome to Hermes Agent! Type your message or /help for commands.\n\n ⚕ gpt-4o │ ctx -- │ [░░░░░░░░░░] -- │ 5s │ ⏲ 0s\n────\n❯\n'
      ;;
    pointer-typed)
      printf ' ⚕ gpt-4o │ ctx -- │ [░░░░░░░░░░] -- │ 6s │ ⏲ 0s\n────\n❯ Read the brief and follow it\n'
      ;;
    delivered)
      # Deliberately still BUSY, not a bare idle ❯: this is the exact real
      # hermes shape while the agent is actively working the just-delivered
      # brief (confirmed live, docs/verification/hermes.md). A composer-empty
      # AND-gate like rovo/kimi's would misread this as undelivered.
      printf '● Read the brief at %s and follow it exactly.\n\n ⚕ gpt-4o │ 12.2K/128K │ [█░░░░░░░░░] 10%% │ 8s │ ⏱ 2s\n────\n⚕ ❯ msg=interrupt · /queue · /bg · /steer · Ctrl+C cancel\n' "$FM_FAKE_BRIEF_REAL"
      ;;
    *)
      printf 'shell starting\n$ \n'
      ;;
  esac
}
fake_cursor_y() {
  case "$state" in
    pointer-typed) printf '4\n' ;;
    ready|delivered) printf '4\n' ;;
    *) printf '1\n' ;;
  esac
}
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "$FM_FAKE_PANE_PATH"; exit 0 ;;
  *"#{cursor_y}"*) fake_cursor_y; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    prev=
    literal=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then literal=$arg; break; fi
      prev=$arg
    done
    if [ -n "$literal" ]; then
      case "$literal" in
        *'--cli --yolo'*)
          printf '%s\n' "$literal" >> "$FM_FAKE_LAUNCH_LOG"
          printf 'launched\n' > "$FM_FAKE_HERMES_STATE"
          ;;
        *)
          printf '%s\n' "$literal" >> "$FM_FAKE_POINTER_LOG"
          printf 'pointer-typed\n' > "$FM_FAKE_HERMES_STATE"
          ;;
      esac
      exit 0
    fi
    case " $* " in
      *' Enter '*)
        case "$state" in
          launched)
            if [ "${FM_FAKE_HERMES_READY:-yes}" = yes ]; then
              printf 'ready\n' > "$FM_FAKE_HERMES_STATE"
            fi
            ;;
          pointer-typed)
            if [ "${FM_FAKE_HERMES_DELIVERY:-yes}" = yes ]; then
              printf 'delivered\n' > "$FM_FAKE_HERMES_STATE"
            else
              printf 'ready\n' > "$FM_FAKE_HERMES_STATE"
            fi
            ;;
        esac
        ;;
    esac
    exit 0
    ;;
  capture-pane)
    start= end= prev=
    for arg in "$@"; do
      case "$prev" in
        -S) start=$arg ;;
        -E) end=$arg ;;
      esac
      case "$arg" in -S|-E) prev=$arg ;; *) prev= ;; esac
    done
    case "$start:$end" in
      *[!0-9:]*|'':*|*:'') fake_screen ;;
      *) fake_screen | awk -v start="$start" -v end="$end" \
           'NR - 1 >= start && NR - 1 <= end' ;;
    esac
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  fm_fake_exit0 "$fakebin" hermes
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_hermes_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  cat > "$home/data/$id/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise Hermes dispatch.

## Firstmate spec
Verify launch and delivery behavior.
EOF
  printf 'hermes\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  : > "$case_dir/launch.log"
  : > "$case_dir/pointer.log"
  : > "$case_dir/hermes.state"
  : > "$case_dir/tmux-calls.log"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_spawn_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_spawn() {
  local case_dir=$1 home=$2 proj=$3 wt=$4 fakebin=$5 id=$6
  shift 6
  HOME="$home" FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    FM_FAKE_POINTER_LOG="$case_dir/pointer.log" \
    FM_FAKE_HERMES_STATE="$case_dir/hermes.state" \
    FM_FAKE_TMUX_CALL_LOG="$case_dir/tmux-calls.log" \
    FM_FAKE_BRIEF_REAL="$(cd "$home/data/$id" && pwd -P)/launch-brief.md" \
    FM_FAKE_HERMES_READY="${FM_FAKE_HERMES_READY:-yes}" \
    FM_FAKE_HERMES_DELIVERY="${FM_FAKE_HERMES_DELIVERY:-yes}" \
    FM_HERMES_READY_POLLS=3 FM_HERMES_DELIVERY_POLLS=3 FM_HERMES_POLL_INTERVAL=0 \
    PATH="$fakebin:$BASE_PATH" \
    "$SPAWN" "$id" "$proj" --harness hermes --mode no-mistakes --yolo off "$@" 2>&1
}

test_hermes_launch_then_send_is_verified() {
  local id rec out rc launch pointer brief_real meta
  id="hermes-success-z1-$$"
  rec=$(make_spawn_case success "$id")
  read_spawn_record "$rec"
  out=$(run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" \
    --model gpt-4o)
  rc=$?
  expect_code 0 "$rc" "verified hermes launch-then-send should succeed"
  assert_contains "$out" "spawned $id harness=hermes" "hermes spawn did not report success"

  launch=$(cat "$CASE_DIR/launch.log")
  assert_contains "$launch" "$FAKEBIN_DIR/hermes' --cli --yolo" \
    "hermes launch did not use the resolved binary with the bare launch-then-send shape"
  assert_not_contains "$launch" "encode launch-brief" "hermes launch carried a positional brief instead of launching bare"
  assert_contains "$launch" "-m 'gpt-4o'" "hermes launch used --model instead of its own -m flag, or omitted the requested model"
  assert_not_contains "$launch" "--model" "hermes launch must use -m, never the generic --model flag"
  assert_contains "$launch" "env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS" \
    "hermes launch did not clear foreign primary markers"
  assert_contains "$launch" "env -u CURSOR_AGENT -u CURSOR_INVOKED_AS" \
    "hermes launch did not clear cursor's markers via the shared outer wrap"
  assert_not_contains "$launch" "--ignore-user-config" \
    "hermes launch must never silently force --ignore-user-config; that tradeoff is the captain's to make"
  assert_not_contains "$launch" "turn-ended" "hermes launch embedded a turn-end path it does not own"

  brief_real="$(cd "$HOME_DIR/data/$id" && pwd -P)/launch-brief.md"
  pointer=$(cat "$CASE_DIR/pointer.log")
  [ "$pointer" = "Read the brief at $brief_real and follow it exactly." ] \
    || fail "hermes pointer was not the exact absolute-path-only instruction: $pointer"

  meta="$HOME_DIR/state/$id.meta"
  assert_grep 'model=gpt-4o' "$meta" "hermes meta lost the requested model"
  assert_not_contains "$(cat "$CASE_DIR/tmux-calls.log")" "kill-window" \
    "a successful hermes spawn must never tear down the endpoint it just delivered into"
  pass "fm-spawn: hermes launches bare, waits for readiness, and delivers its brief pointer"
}

test_hermes_effort_is_never_passed() {
  local id rec out rc launch
  id="hermes-effort-z6-$$"
  rec=$(make_spawn_case effort "$id")
  read_spawn_record "$rec"
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" --effort high)
  rc=$?
  expect_code 0 "$rc" "hermes spawn with a requested effort should still succeed"
  launch=$(cat "$CASE_DIR/launch.log")
  assert_not_contains "$launch" "--effort" "hermes exposes no effort concept and must never receive an --effort flag"
  assert_not_contains "$launch" "--thinking" "hermes exposes no effort concept and must never receive a --thinking flag"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep 'effort=high' "$meta" "hermes meta did not retain the requested effort axis even though it is never passed to the launch"
  pass "fm-spawn: hermes never receives an effort flag, but the requested axis is still recorded in task metadata"
}

test_hermes_readiness_gate_precedes_pointer() {
  local id rec out rc
  id="hermes-not-ready-z3-$$"
  rec=$(make_spawn_case not-ready "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(FM_FAKE_HERMES_READY=no run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "hermes spawn without a ready signal should fail"
  assert_contains "$out" "hermes did not show a verified ready signal" \
    "hermes readiness failure lacked a loud diagnostic"
  assert_grep 'failed: hermes did not show a verified ready signal' "$HOME_DIR/state/$id.status" \
    "hermes readiness failure did not leave a supervisor-visible failure"
  [ ! -s "$CASE_DIR/pointer.log" ] || fail "hermes pointer was sent before an observable ready signal"
  grep -q "kill-window.*fm-$id" "$CASE_DIR/tmux-calls.log" \
    || fail "a failed hermes readiness gate must tear down the exact endpoint it created instead of leaking an orphaned --yolo process"
  pass "fm-spawn: hermes never sends the brief pointer before an observable ready signal, and tears down the created endpoint on failure"
}

test_hermes_unconfirmed_delivery_fails_loudly() {
  local id rec out rc pointer
  id="hermes-drop-z7-$$"
  rec=$(make_spawn_case drop "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(FM_FAKE_HERMES_DELIVERY=no run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "an unconfirmed hermes delivery should fail"
  pointer=$(cat "$CASE_DIR/pointer.log")
  [ -n "$pointer" ] || fail "hermes never typed the pointer before the delivery gate"
  assert_contains "$out" "hermes brief pointer delivery was not confirmed" \
    "unconfirmed hermes delivery lacked a loud diagnostic"
  assert_grep 'failed: hermes brief pointer delivery was not confirmed' "$HOME_DIR/state/$id.status" \
    "unconfirmed hermes delivery did not leave a supervisor-visible failure"
  grep -q "kill-window.*fm-$id" "$CASE_DIR/tmux-calls.log" \
    || fail "an unconfirmed hermes delivery must tear down the exact endpoint it created instead of leaking an orphaned --yolo process"
  pass "fm-spawn: hermes treats a silent pointer drop as a failed spawn, and tears down the created endpoint"
}

test_hermes_delivery_does_not_require_composer_empty() {
  # The regression this pins: hermes's busy prompt row is not a composer
  # shape the shared classifier reads as "empty" (confirmed live - see
  # docs/verification/hermes.md), so gating delivery on composer-emptiness
  # like rovo/kimi do would time this gate out for the agent's entire first
  # turn on any real brief. Drive the SAME rendered screen
  # test_hermes_launch_then_send_is_verified's "delivered" fake state
  # produces through both the real composer classifier and a real spawn, to
  # prove the divergence behaviorally: the composer reads non-empty at
  # exactly the moment delivery must already be confirmed.
  local id rec composer_state out rc
  id="hermes-busy-delivery-z8-$$"
  rec=$(make_spawn_case busy-delivery "$id")
  read_spawn_record "$rec"
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-backend.sh"
  printf 'delivered\n' > "$CASE_DIR/hermes.state"
  composer_state=$(TMUX="fake,1,0" FM_FAKE_PANE_PATH="$WT_DIR" \
    FM_FAKE_HERMES_STATE="$CASE_DIR/hermes.state" FM_FAKE_TMUX_CALL_LOG="$CASE_DIR/tmux-calls.log" \
    PATH="$FAKEBIN_DIR:$BASE_PATH" fm_backend_composer_state tmux "fake:0" 2>/dev/null)
  [ "$composer_state" != empty ] \
    || fail "test setup is vacuous: hermes's real busy-delivery screen must not read composer-empty, or this regression cannot be exercised"

  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" --model gpt-4o)
  rc=$?
  expect_code 0 "$rc" "a hermes spawn whose delivery screen is still busy (composer_state=$composer_state) must still confirm delivery"
  assert_contains "$out" "spawned $id harness=hermes" "hermes spawn did not report success despite a non-empty composer at delivery"
  pass "fm-spawn: hermes's delivery gate confirms delivery while the composer reads non-empty"
}

test_hermes_missing_binary_refuses_before_pane_creation() {
  local id rec out rc
  id="hermes-missing-z4-$$"
  rec=$(make_spawn_case missing "$id")
  read_spawn_record "$rec"
  rm "$FAKEBIN_DIR/hermes"
  rc=0
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "missing hermes executable should refuse the spawn"
  assert_contains "$out" "searched PATH for 'hermes'" "missing hermes diagnostic omitted PATH search"
  [ -s "$CASE_DIR/launch.log" ] && fail "missing hermes executable created a launch command" || true
  pass "fm-spawn: missing hermes executable refuses before pane creation"
}

test_hermes_secondmate_is_refused() {
  local id rec out rc
  id="hermes-secondmate-z5-$$"
  rec=$(make_spawn_case secondmate-refuse "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(HOME="$HOME_DIR" FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 PATH="$FAKEBIN_DIR:$BASE_PATH" \
    "$SPAWN" "$id" --secondmate hermes 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a hermes secondmate spawn should be refused"
  assert_contains "$out" "hermes is a verified crewmate/scout adapter only" \
    "hermes secondmate refusal lacked its concrete reason"
  pass "fm-spawn: hermes cannot be launched as a secondmate"
}

test_hermes_process_identity_reads_the_script_argument() {
  # shellcheck source=bin/fm-hermes-lib.sh
  . "$ROOT/bin/fm-hermes-lib.sh"
  fm_hermes_args_are_hermes '/Users/u/.hermes/hermes-agent/venv/bin/python3 /Users/u/.hermes/hermes-agent/venv/bin/hermes --cli -m gpt-4o --provider copilot' \
    || fail "the live-measured launcher shape must be recognized as hermes"
  fm_hermes_args_are_hermes 'python3.11 /Users/u/.hermes/hermes-agent/venv/bin/hermes --cli' \
    || fail "a bare python3.NN interpreter name must still resolve the hermes script argument"
  fm_hermes_args_are_hermes 'hermes --cli' \
    || fail "a natively-named hermes command must be recognized"
  fm_hermes_args_are_hermes '/opt/venv/hermes-agent/bin/some-entrypoint' \
    || fail "any hermes-agent install-tree component must be recognized even off a differently-named entrypoint"

  # Divergence: the negatives are what keep the positives from being vacuous.
  ! fm_hermes_args_are_hermes '/usr/bin/python3' \
    || fail "a bare python interpreter must not be claimed as hermes"
  ! fm_hermes_args_are_hermes 'python3 /home/u/app/server.py' \
    || fail "an unrelated python script must not be claimed as hermes"
  ! fm_hermes_args_are_hermes 'python3 /home/u/app/server.py --model hermes' \
    || fail "a later flag value naming hermes must not claim the identity"
  ! fm_hermes_args_are_hermes 'tail -f /var/log/hermes.log' \
    || fail "an unrelated command reading a hermes-named file must not match"
  ! fm_hermes_args_are_hermes 'python3 /home/u/hermes/other.py' \
    || fail "a hermes directory component alone must not claim the identity"
  pass "fm-hermes-lib.sh: identity comes from the script argument, never a bare interpreter"
}

test_hermes_ancestry_detects_python_interpreter_shape() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/anc-interp")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' 'python3'; exit 0 ;;
  *"args="*) printf '%s\n' '/Users/u/.hermes/hermes-agent/venv/bin/python3 /Users/u/.hermes/hermes-agent/venv/bin/hermes --cli -m gpt-4o'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI -u ATLASSIAN_AGENT_TYPE -u ROVODEV_CLI \
    PATH="$fakebin:$BASE_PATH" FM_CONFIG_OVERRIDE="$TMP_ROOT/anc-interp/config" "$ROOT/bin/fm-harness.sh")
  [ "$out" = hermes ] \
    || fail "a live python-interpreter hermes process must be detected by ancestry, got '$out'"
  pass "fm-harness.sh: ancestry detects hermes through the python-interpreter argv[1] shape"
}

test_hermes_ancestry_rejects_unrelated_mentions() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/anc-negatives")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' "${FAKE_PS_COMM:?}"; exit 0 ;;
  *"args="*) printf '%s\n' "${FAKE_PS_ARGS:?}"; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"

  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI -u ATLASSIAN_AGENT_TYPE -u ROVODEV_CLI \
    FAKE_PS_COMM=python3 FAKE_PS_ARGS='python3 server.py --model hermes' \
    PATH="$fakebin:$BASE_PATH" FM_CONFIG_OVERRIDE="$TMP_ROOT/anc-negatives/config" "$ROOT/bin/fm-harness.sh")
  [ "$out" != hermes ] \
    || fail "a later python argument naming hermes must not detect hermes, got '$out'"
  pass "fm-harness.sh: ancestry rejects unrelated hermes mentions"
}

test_hermes_agent_process_classify_reads_python_shape() {
  # shellcheck source=bin/fm-agent-process-lib.sh
  . "$ROOT/bin/fm-agent-process-lib.sh"
  local out
  out=$(fm_agent_process_classify python3 '' \
    '/Users/u/.hermes/hermes-agent/venv/bin/python3 /Users/u/.hermes/hermes-agent/venv/bin/hermes --cli -m gpt-4o')
  [ "$out" = agent ] \
    || fail "tmux liveness classification must read a live hermes pane as agent, got '$out'"
  out=$(fm_agent_process_classify python3 '' 'python3 /home/u/app/server.py')
  [ "$out" != agent ] \
    || fail "an unrelated python process must not classify as agent through the hermes rule"
  pass "fm-agent-process-lib.sh: tmux/herdr liveness classification reaches hermes's python-interpreter shape"
}

test_hermes_control_lib_is_deliberately_unsupported() {
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-control-lib.sh"
  # hermes is deliberately absent from every fm-control-lib.sh table: Ctrl+C
  # exits the whole session and Escape does not cancel a running tool call
  # (both confirmed live), so no key-based interrupt exists for it, and the
  # only verified-safe redirect - typing new text and submitting it - is not
  # a mechanic the key-based control plane supports today. Wiring hermes into
  # fm_control_harness_supported without a real interrupt mechanic would let
  # do_exit's busy-agent path attempt to deliver a nonexistent interrupt key.
  if fm_control_harness_supported hermes; then
    fail "hermes must NOT be a supported control-plane harness until a real interrupt mechanic is wired"
  fi
  if fm_control_harness_family hermes-anything 2>/dev/null; then
    fail "hermes must not resolve to a control-plane harness family"
  fi
  pass "fm-control-lib.sh: hermes is deliberately absent, not guessed, from the control-plane tables"
}

test_hermes_busy_regex_isolated() {
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-busy-lib.sh"
  printf 'Initializing agent...\n\n ⚕ gpt-4o │ 12.2K/128K │ [█░░░░░░░░░] 10%% │ 34s │ ⏱ 6s\n────\n⚕ ❯ msg=interrupt · /queue · /bg · /steer · Ctrl+C cancel\n' \
    | fm_busy_hermes_tail_busy \
    || fail "hermes's real busy footer was not recognized as busy"
  printf ' ⚕ gpt-4o │ 12.2K/128K │ [█░░░░░░░░░] 10%% │ 45s │ ⏲ 18s\n────\n❯\n' \
    | fm_busy_hermes_tail_busy \
    && fail "an idle hermes composer footer was misread as busy"
  printf 'Rovo is thinking\n' | fm_busy_hermes_tail_busy \
    && fail "rovo's busy line leaked into hermes's harness-scoped matcher"
  printf 'msg=interrupt\n' | fm_busy_rovo_tail_busy \
    && fail "hermes's busy token leaked into rovo's harness-scoped matcher"

  local out
  out=$(fm_busy_classify tmux fake:0 hermes taskid /nonexistent-state '⚕ ❯ msg=interrupt · /queue · /bg · /steer · Ctrl+C cancel')
  [ "$out" = "busy hermes-regex" ] || fail "fm_busy_classify did not read a real hermes busy tail as busy hermes-regex, got '$out'"
  out=$(fm_busy_classify tmux fake:0 hermes taskid /nonexistent-state '❯')
  [ "$out" = "unknown hermes-regex" ] || fail "fm_busy_classify misread a marker-absent hermes tail as definitive idle instead of unknown, got '$out'"
  pass "busy detection: hermes's rendered busy footer classifies through its own isolated fallback"
}

test_hermes_busy_marker_scrolled_out_of_tail_is_unknown() {
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-busy-lib.sh"
  local tail40 out i
  tail40='⚕ ❯ msg=interrupt · /queue · /bg · /steer · Ctrl+C cancel'
  for i in $(seq 1 20); do
    tail40="$tail40
tool output line $i"
  done
  out=$(fm_busy_classify tmux fake:0 hermes taskid /nonexistent-state "$tail40")
  [ "$out" = "unknown hermes-regex" ] \
    || fail "an active hermes turn whose busy marker scrolled out of the tail must classify unknown, not idle; got '$out'"
  pass "busy detection: a hermes busy marker scrolled out of the tail classifies unknown, never idle"
}

test_hermes_launch_then_send_is_verified
test_hermes_effort_is_never_passed
test_hermes_readiness_gate_precedes_pointer
test_hermes_unconfirmed_delivery_fails_loudly
test_hermes_delivery_does_not_require_composer_empty
test_hermes_missing_binary_refuses_before_pane_creation
test_hermes_secondmate_is_refused
test_hermes_process_identity_reads_the_script_argument
test_hermes_ancestry_detects_python_interpreter_shape
test_hermes_ancestry_rejects_unrelated_mentions
test_hermes_agent_process_classify_reads_python_shape
test_hermes_control_lib_is_deliberately_unsupported
test_hermes_busy_regex_isolated
test_hermes_busy_marker_scrolled_out_of_tail_is_unknown
