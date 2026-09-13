#!/usr/bin/env bash
# Live guard for the real, installed Hermes Agent CLI (bin/fm-test-run.sh's
# live-harness-optin family). Env-gated and self-skipping: it drives the real
# binary through a raw PTY (the same TTY contract tmux/herdr allocate) rather
# than requiring tmux, so it runs on hosts without tmux installed. It exercises
# the EXACT production launch-then-send shape - bare `hermes --cli --yolo` with
# NO positional prompt, a readiness gate on the `Welcome to Hermes Agent!`
# banner, a typed absolute brief pointer, then a delivery gate - and proves the
# harness-dependent facts bin/fm-busy-lib.sh and bin/fm-control-lib.sh encode for
# hermes: that the `msg=interrupt` busy hint renders for a real tool call, that
# Ctrl+C is NOT a safe interrupt (it exits the whole session), that Escape is a
# no-op that does NOT cancel a running tool call, that typing new text and
# pressing Enter while busy IS a safe redirect, and that /exit then exits
# cleanly while idle.
#
# This guard adds --ignore-user-config --provider copilot to the driven launch,
# UNLIKE bin/fm-spawn.sh's production launch template, which deliberately never
# forces it (see the template's own comment and docs/verification/hermes.md).
# That flag pair is this guard's own operational choice to keep it runnable
# regardless of the captain's ~/.hermes/config.yaml terminal.backend setting,
# not something the adapter bakes in for a real dispatch.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERMES_BIN=$(command -v hermes 2>/dev/null || true)
[ -x "${HERMES_BIN:-}" ] || HERMES_BIN="$HOME/.local/bin/hermes"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

fm_live_gate opt-in FM_HERMES_SIGNALS_LIVE python3

[ -x "$HERMES_BIN" ] || fail "FM_HERMES_SIGNALS_LIVE=1 but no real hermes executable is installed"

VERSION_OUT=$("$HERMES_BIN" --version 2>&1) || fail "hermes --version failed: $VERSION_OUT"
echo "BOOTSTRAP_INFO: live hermes version: $VERSION_OUT"

# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-hermes-signals.XXXXXX") || fail "could not create the isolated Hermes lab"
cleanup() { rm -rf -- "$LAB"; }
trap cleanup EXIT
mkdir -p "$LAB/workspace"
git -C "$LAB/workspace" init -q || fail "could not initialize the isolated Hermes workspace"
WORKSPACE=$(cd "$LAB/workspace" && pwd -P) || fail "could not resolve the isolated Hermes workspace"
TRANSCRIPT="$LAB/transcript.log"

# The brief the typed pointer will reference. It triggers a slow terminal
# tool call so the busy footer and the interrupt window are both long enough
# to observe.
BRIEF="$LAB/brief.md"
printf 'Run this exact terminal command and nothing else: sleep 20 && echo LIVE_GUARD_DONE\n' > "$BRIEF"
BRIEF_REAL=$(cd "$LAB" && pwd -P)/brief.md

# Session 1: launch, readiness, delivery, busy footer, Ctrl+C-exits-the-session,
# Escape-does-not-cancel, and the tool call completing normally afterward -
# proving Escape truly never cancelled it rather than merely not crashing.
python3 - "$HERMES_BIN" "$WORKSPACE" "$TRANSCRIPT" "$BRIEF_REAL" <<'PY' || fail "the PTY driver reported a failure"
import os
import pty
import select
import subprocess
import sys
import time

hermes_bin, workspace, transcript_path, brief_real = sys.argv[1:5]

pointer = "Read the brief at %s and follow it exactly." % brief_real

pid, fd = pty.fork()
if pid == 0:
    os.chdir(workspace)
    os.execvp(hermes_bin, [hermes_bin, "--cli", "--yolo", "-m", "gpt-4o",
                            "--provider", "copilot", "--ignore-user-config"])
    os._exit(127)

transcript = open(transcript_path, "wb")

def pump(timeout, want=None):
    deadline = time.time() + timeout
    buf = b""
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], 0.5)
        if fd in r:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            transcript.write(chunk)
            transcript.flush()
            buf += chunk
        if want and want in buf:
            return buf
    return buf

# 1. Readiness gate: wait for hermes's fresh-launch welcome banner.
ready = pump(60, want=b"Welcome to Hermes Agent!")
if b"Welcome to Hermes Agent!" not in ready:
    sys.exit("hermes never rendered its 'Welcome to Hermes Agent!' readiness banner")

# 2. Type the absolute brief pointer and submit it, then wait for the busy
# footer's msg=interrupt hint, which proves both delivery and the working
# state.
os.write(fd, pointer.encode() + b"\r")
busy = pump(90, want=b"msg=interrupt")
if b"msg=interrupt" not in busy:
    sys.exit("hermes never rendered its busy footer after the typed brief pointer")

# 3. Escape mid-tool-call must NOT cancel it - confirmed by observing the
# tool call complete normally at its expected duration afterward, not just
# that the session survived. Generous budget: beyond the 20s sleep itself,
# API latency on a shared, potentially rate-limited pooled credential can add
# real delay unrelated to the finding under test (observed live: a busy
# GitHub Copilot pool can leave a single turn taking several minutes to
# produce a final response even though the 20s tool call itself completed
# quickly).
os.write(fd, b"\x1b")
still_running = pump(240, want=b"LIVE_GUARD_DONE")
if b"LIVE_GUARD_DONE" not in still_running:
    sys.exit("the sleep 20 tool call never completed after Escape within the budget - either it was cancelled (contradicting the 'Escape is a no-op' finding), the session wedged, or the account is currently rate-limited/slow enough to exceed this guard's budget")

# 4. Exit cleanly from idle.
time.sleep(1)
os.write(fd, b"/exit\r")
for _ in range(60):
    try:
        done_pid, status = os.waitpid(pid, os.WNOHANG)
    except ChildProcessError:
        done_pid = pid
        status = 0
    if done_pid == pid:
        break
    pump(1)
else:
    subprocess.run(["kill", "-9", str(pid)])
    sys.exit("hermes did not exit after /exit")

transcript.close()
PY

grep -aFq 'Welcome to Hermes Agent!' "$TRANSCRIPT" \
  || fail "real hermes never rendered its readiness banner"
pass "real hermes launches bare and renders its 'Welcome to Hermes Agent!' readiness banner"

grep -aFq 'msg=interrupt' "$TRANSCRIPT" \
  || fail "real hermes never rendered its busy footer from the typed brief pointer"
printf '%s\n' "⚕ ❯ msg=interrupt · /queue · /bg · /steer · Ctrl+C cancel" | fm_busy_hermes_tail_busy \
  || fail "fm_busy_hermes_tail_busy did not classify the real busy footer as busy"
pass "real hermes delivers the typed brief pointer and renders its busy footer"

grep -aFq 'LIVE_GUARD_DONE' "$TRANSCRIPT" \
  || fail "the sleep 20 tool call never completed after a mid-tool-call Escape - Escape may have cancelled it"
pass "real hermes's Escape does NOT cancel a running tool call - it completes normally at its expected duration"

pass "real hermes exits cleanly on /exit while idle"

# Session 2, isolated: the safe interrupt redirect - typing new text and
# pressing Enter while busy - actually redirects a running turn without
# wedging the session, and Ctrl+C genuinely exits the whole session rather
# than merely cancelling a turn.
mkdir -p "$LAB/workspace2"
git -C "$LAB/workspace2" init -q || fail "could not initialize the second isolated workspace"
WORKSPACE2=$(cd "$LAB/workspace2" && pwd -P) || fail "could not resolve the second isolated workspace"
TRANSCRIPT2="$LAB/transcript2.log"
REDIRECT_TOKEN="HERMES_REDIRECT_$$_$RANDOM"

python3 - "$HERMES_BIN" "$WORKSPACE2" "$TRANSCRIPT2" "$BRIEF_REAL" "$REDIRECT_TOKEN" <<'PY' || fail "the redirect/Ctrl+C PTY driver reported a failure"
import os
import pty
import select
import subprocess
import sys
import time

hermes_bin, workspace, transcript_path, brief_real, token = sys.argv[1:6]

pointer = "Read the brief at %s and follow it exactly." % brief_real
redirect_msg = "Reply now with exactly %s and nothing else." % token

pid, fd = pty.fork()
if pid == 0:
    os.chdir(workspace)
    os.execvp(hermes_bin, [hermes_bin, "--cli", "--yolo", "-m", "gpt-4o",
                            "--provider", "copilot", "--ignore-user-config"])
    os._exit(127)

transcript = open(transcript_path, "wb")

def pump(timeout, want=None):
    deadline = time.time() + timeout
    buf = b""
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], 0.5)
        if fd in r:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            transcript.write(chunk)
            transcript.flush()
            buf += chunk
        if want and want in buf:
            return buf
    return buf

ready = pump(60, want=b"Welcome to Hermes Agent!")
if b"Welcome to Hermes Agent!" not in ready:
    sys.exit("hermes (redirect session) never rendered its readiness banner")

os.write(fd, pointer.encode() + b"\r")
busy = pump(90, want=b"msg=interrupt")
if b"msg=interrupt" not in busy:
    sys.exit("hermes (redirect session) never rendered its busy footer")

# The safe redirect: type new text and press Enter while busy.
os.write(fd, redirect_msg.encode() + b"\r")
redirected = pump(15, want=b"nterrupt")
if b"Interrupted" not in redirected and b"interrupting" not in redirected:
    sys.exit("hermes (redirect session) did not acknowledge the text+Enter redirect")
reply = pump(30, want=token.encode())
if token.encode() not in reply:
    sys.exit("hermes (redirect session) never replied to the redirected message")

os.write(fd, b"/exit\r")
for _ in range(60):
    try:
        done_pid, status = os.waitpid(pid, os.WNOHANG)
    except ChildProcessError:
        done_pid = pid
        status = 0
    if done_pid == pid:
        break
    pump(1)
else:
    subprocess.run(["kill", "-9", str(pid)])
    sys.exit("hermes (redirect session) did not exit after /exit")

transcript.close()
PY

grep -aiFq 'interrupt' "$TRANSCRIPT2" \
  || fail "real hermes did not acknowledge the safe text+Enter redirect while busy"
grep -aFq "$REDIRECT_TOKEN" "$TRANSCRIPT2" \
  || fail "real hermes never replied to the message sent through the safe redirect"
pass "real hermes's safe interrupt is typing new text and pressing Enter while busy, and the session survives it"

# Session 3, isolated: Ctrl+C genuinely exits the whole session, confirmed
# separately from the redirect so the two mechanics are never conflated.
mkdir -p "$LAB/workspace3"
git -C "$LAB/workspace3" init -q || fail "could not initialize the third isolated workspace"
WORKSPACE3=$(cd "$LAB/workspace3" && pwd -P) || fail "could not resolve the third isolated workspace"
TRANSCRIPT3="$LAB/transcript3.log"

python3 - "$HERMES_BIN" "$WORKSPACE3" "$TRANSCRIPT3" "$BRIEF_REAL" <<'PY' || fail "the Ctrl+C PTY driver reported a failure"
import os
import pty
import select
import subprocess
import sys
import time

hermes_bin, workspace, transcript_path, brief_real = sys.argv[1:5]

pointer = "Read the brief at %s and follow it exactly." % brief_real

pid, fd = pty.fork()
if pid == 0:
    os.chdir(workspace)
    os.execvp(hermes_bin, [hermes_bin, "--cli", "--yolo", "-m", "gpt-4o",
                            "--provider", "copilot", "--ignore-user-config"])
    os._exit(127)

transcript = open(transcript_path, "wb")

def pump(timeout, want=None):
    deadline = time.time() + timeout
    buf = b""
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], 0.5)
        if fd in r:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            transcript.write(chunk)
            transcript.flush()
            buf += chunk
        if want and want in buf:
            return buf
    return buf

ready = pump(60, want=b"Welcome to Hermes Agent!")
if b"Welcome to Hermes Agent!" not in ready:
    sys.exit("hermes (ctrl-c session) never rendered its readiness banner")

os.write(fd, pointer.encode() + b"\r")
busy = pump(90, want=b"msg=interrupt")
if b"msg=interrupt" not in busy:
    sys.exit("hermes (ctrl-c session) never rendered its busy footer")

os.write(fd, b"\x03")
for _ in range(30):
    try:
        done_pid, status = os.waitpid(pid, os.WNOHANG)
    except ChildProcessError:
        done_pid = pid
        status = 0
    if done_pid == pid:
        break
    pump(1)
else:
    sys.exit("hermes did not exit the whole session after Ctrl+C - this contradicts the live finding and would change the interrupt-safety conclusion")

transcript.close()
PY

pass "real hermes's Ctrl+C exits the whole session rather than cancelling only the running turn"
