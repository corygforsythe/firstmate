#!/usr/bin/env bash
# Opt-in live guard for the launch-brief stub (bin/fm-spawn.sh header,
# __LAUNCHPROMPT__): every positional-launch harness receives only a short typed
# stub naming its brief file on its argv, and must read that file on its first
# turn. For each INSTALLED positional-launch harness this drives the real
# fm-spawn through a scout in an isolated FM_HOME on a private tmux server,
# requires the worker to act on a token that exists only inside the brief file,
# and requires the live agent processes' argv to carry the brief path but none
# of the brief's prose. It spends model tokens, so it stays opt-in:
#   FM_LAUNCH_BRIEF_STUB_LIVE=1 bash tests/fm-launch-brief-stub-live-e2e.test.sh
# FM_LAUNCH_BRIEF_STUB_HARNESSES narrows the harness list (space-separated).
# Absent harnesses are reported, and a run that checked none fails.
# Only this guard's own private tmux server and scout records are touched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_LAUNCH_BRIEF_STUB_LIVE tmux git python3

# Positional-launch harnesses and the executable each resolves. kimi, rovo,
# hermes, and hermes-vps launch bare and receive a typed pointer after a
# readiness gate instead, so they never carried the brief on argv.
harness_bin() {
  case "$1" in
    cursor) printf '%s' cursor-agent ;;
    *) printf '%s' "$1" ;;
  esac
}
HARNESSES=${FM_LAUNCH_BRIEF_STUB_HARNESSES:-claude codex opencode grok gemini cursor muse agy pi omp}
WAIT_SECS=${FM_LAUNCH_BRIEF_STUB_WAIT:-240}

LAB=$(fm_test_tmproot fm-launch-brief-stub-live) || fail "could not create the isolated lab"
# tmux socket paths are length-limited, so the private server lives under /tmp.
TMUX_LAB=$(mktemp -d /tmp/fmlbs.XXXXXX) || fail "could not create the private tmux dir"
SPAWNED=''

cleanup() {
  local id
  for id in $SPAWNED; do
    mkdir -p "$LAB/home/data/$id"
    [ -s "$LAB/home/data/$id/report.md" ] || printf 'live guard cleanup\n' > "$LAB/home/data/$id/report.md"
    FM_HOME="$LAB/home" "$ROOT/bin/fm-captain-hold.sh" complete "$id" --none >/dev/null 2>&1 || true
    TMUX_TMPDIR="$TMUX_LAB" FM_HOME="$LAB/home" "$ROOT/bin/fm-teardown.sh" "$id" >/dev/null 2>&1 || true
  done
  TMUX_TMPDIR="$TMUX_LAB" tmux kill-server >/dev/null 2>&1 || true
  rm -rf -- "$TMUX_LAB"
}
trap cleanup EXIT

unset TMUX TMUX_PANE
export TMUX_TMPDIR="$TMUX_LAB"
# The worktree pool lives in the lab too, so nothing outlives the guard.
export TREEHOUSE_ROOT="$LAB/treehouse"
mkdir -p "$LAB/home/config" "$LAB/home/data" "$LAB/home/state" "$LAB/home/projects/probe"
printf 'tmux\n' > "$LAB/home/config/backend"
git -C "$LAB/home/projects/probe" init -q -b main || fail "could not initialize the probe repository"
git -C "$LAB/home/projects/probe" config user.email 'launch-stub-test@example.invalid'
git -C "$LAB/home/projects/probe" config user.name 'launch stub test'
printf 'launch stub probe\n' > "$LAB/home/projects/probe/README.md"
git -C "$LAB/home/projects/probe" add README.md
git -C "$LAB/home/projects/probe" commit -qm 'fixture: initialize launch stub probe'

# descendants <pid>: the pid and every descendant, one per line.
descendants() {
  ps -A -o pid=,ppid= | awk -v root="$1" '
    { parent[$1] = $2 }
    END {
      keep[root] = 1; changed = 1
      while (changed) { changed = 0; for (p in parent) if (!keep[p] && keep[parent[p]]) { keep[p] = 1; changed = 1 } }
      for (p in keep) if (keep[p] == 1) print p
    }'
}

checked=0
for harness in $HARNESSES; do
  bin=$(harness_bin "$harness")
  if ! command -v "$bin" >/dev/null 2>&1; then
    printf 'absent: %s (%s not on PATH); not checked\n' "$harness" "$bin"
    continue
  fi
  version=$("$bin" --version 2>/dev/null | head -n 1)
  id="fm-test-launch-stub-$harness-$$"
  token="STUB$RANDOM$RANDOM"
  status="$LAB/home/state/$id.status"
  FM_HOME="$LAB/home" "$ROOT/bin/fm-brief.sh" "$id" probe --scout >/dev/null \
    || fail "could not scaffold the $harness probe brief"
  python3 - "$LAB/home/data/$id/brief.md" "$status" "$token" <<'PY'
from pathlib import Path
import sys

brief, status, token = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
text = brief.read_text()
text = text.replace("{TASK}", f"""Launch stub probe.
Append exactly `done: token {token}` to `{status}` and stop.
Shell-shaped sentinel prose you do not need to run: `pwd -P` and `no-mistakes axi run`.
Do not change project files or make a commit.""")
text = text.replace("{FIRSTMATE_SPEC}", "Nothing beyond the captain's intent.")
brief.write_text(text)
PY

  model_args=()
  [ "$harness" != claude ] || model_args=(--model haiku)
  FM_SPAWN_NO_GUARD=1 FM_HOME="$LAB/home" "$ROOT/bin/fm-spawn.sh" "$id" "$LAB/home/projects/probe" --scout --harness "$harness" \
    "${model_args[@]+"${model_args[@]}"}" \
    || fail "could not launch the real $harness $version probe"
  SPAWNED="$SPAWNED $id"
  target=$(sed -n 's/^window=//p' "$LAB/home/state/$id.meta" | head -n 1)
  [ -n "$target" ] || fail "the $harness probe recorded no endpoint"

  pane_pid=$(tmux display-message -p -t "$target" '#{pane_pid}') || fail "could not read the $harness pane pid"
  seen_path=0
  for _ in $(seq 1 "$WAIT_SECS"); do
    capture=$(tmux capture-pane -p -t "$target" -S -200 2>/dev/null || true)
    case "$capture" in
      *'Yes, I trust this folder'*) tmux send-keys -t "$target" Enter ;;
    esac
    while read -r pid; do
      args=$(ps -o args= -p "$pid" 2>/dev/null) || continue
      case "$args" in
        *'pwd -P'* | *'no-mistakes axi run'*) fail "$harness $version process $pid carries brief prose on its argv: $args" ;;
        *"$LAB/home/data/$id/launch-brief.md"*) seen_path=1 ;;
      esac
    done < <(descendants "$pane_pid")
    grep -q "^done: token $token\$" "$status" 2>/dev/null && break
    sleep 1
  done
  grep -q "^done: token $token\$" "$status" 2>/dev/null \
    || fail "$harness $version did not act on the token that exists only in its brief file within ${WAIT_SECS}s"
  [ "$seen_path" -eq 1 ] || fail "no live $harness $version process carried the brief file path on its argv"
  pass "$harness $version reads its brief file on turn one from a stub-only argv"
  checked=$((checked + 1))
done

[ "$checked" -gt 0 ] || fail "no positional-launch harness is installed, so nothing was checked"
