#!/usr/bin/env python3
# fm-hermes-vps-bridge.py - renders a captain's remote VPS Hermes /api/ws
# session into an ordinary local pane, so a VPS-dispatched Hermes crewmate
# is visible and interactive exactly like a local pane-based crewmate,
# while every busy/interrupt/exit lifecycle question is answered by the
# real, structural /api/ws RPCs documented in docs/verification/hermes.md,
# not by anything rendered here.
#
# Usage: fm-hermes-vps-bridge.py --cwd <path>
#          [--status-file <path>] [--report-file <path>] [--inbox-dir <path>]
#   The three optional flags arm the local status/report/inbox protocol
#   below; omitting one only disables that one piece (existing callers and
#   tests that predate this protocol still work with --cwd alone).
#
# Design (harness=hermes-vps, distinct from harness=hermes's pane-based
# `hermes --cli` adapter):
#   - One persistent bin/fm-hermes-ws.py HermesWsSession per bridge process,
#     created fresh on every launch (a relaunch always creates a NEW VPS
#     session; resuming a prior one is out of scope, matching firstmate's
#     fleet-wide "resume is not deterministic" stance - bin/fm-control-lib.sh's
#     header note that `relaunch` covers the same need for every adapter
#     without a harness-private session).
#   - A single-threaded loop (select() over stdin and the WS socket) drains
#     server-pushed `event` notifications and renders them into this pane's
#     scrollback (message.delta/message.complete, tool.start/tool.complete,
#     error), and forwards each line typed into this pane to the VPS
#     session (prompt.submit while idle, session.steer while a turn is in
#     flight - the same idle/busy distinction bin/fm-busy-lib.sh's
#     hermes-vps classifier separately confirms via a live session.status
#     RPC, never from this bridge's own in-memory flag).
#   - This pane never runs the real `hermes` binary and never touches this
#     machine's terminal/file tools for the VPS session's own turns; the
#     ONE exception is the launch brief itself (see "Brief delivery"
#     below), because every other harness's "Read the brief at <path> and
#     follow it exactly." pointer assumes the AGENT can open that path
#     itself, which a remote VPS session cannot.
#   - THE KEY LIMITATION, addressed here for the status/report/inbox surface
#     only: session.create's cwd param is NOT honored on the captain's real
#     VPS deployment (live-verified, docs/verification/hermes.md), so the
#     VPS agent's own file/terminal tools reach only the VPS's OWN
#     filesystem, never this task's local git worktree. A hermes-vps
#     crewmate can converse and use tools in the VPS's own sandbox but
#     cannot read or edit this project's code; do not dispatch a ship/scout
#     task onto it that needs local repo access - see
#     .agents/skills/harness-adapters/references/harness/hermes-vps.md.
#
# Brief delivery: fm-spawn.sh's launch-then-send shape for hermes-vps types
# the SAME pointer sentence every launch-then-send harness receives -
# "Read the brief at <absolute-path> and follow it exactly." - into this
# pane. Every other harness's own process then opens that path itself. This
# bridge cannot forward that literal sentence: the remote VPS agent has no
# access to this machine's filesystem. So this bridge, which DOES run
# locally and can read that path, special-cases exactly the FIRST line it
# receives: if it matches that literal pointer shape and the path is
# readable, it reads the file itself and forwards the file's own CONTENT to
# the VPS session instead of the sentence about it. Every later line (an
# ordinary steer) is forwarded verbatim, unexamined.
#
# Status/report/inbox protocol (live-verification finding,
# data/hermes-vps-live-verify/report.md): the remote agent has NO path back
# to this Mac's filesystem at all, so it cannot append its own
# state/<id>.status, cannot write data/<id>/report.md, and cannot read or
# acknowledge state/<id>.inbox/*.msg the way every other harness's crewmate
# does directly with shell commands. Before this fix that made the failure
# mode silent: a crewmate that hit this wall had no way to even append a
# `blocked:` line about it. This bridge - which DOES run locally - now owns
# all three as a transport concern instead of a filesystem one, using
# --status-file/--report-file/--inbox-dir (all optional; omitting one only
# disables that one piece, for callers or tests that predate this protocol):
#   - Status: bin/fm-brief.sh's hermes-vps scaffold tells the remote agent to
#     emit a line of the exact shape `FIRSTMATE-STATUS: <state>[ [key=..]]: <note>`
#     in its own chat output, mirroring the literal `echo "{state}: ..." >>`
#     convention every other harness's brief already uses (fm-classify-lib.sh
#     owns the state vocabulary). This bridge scans each completed turn's
#     full accumulated text - every message.delta chunk concatenated across
#     the turn, never message.complete's own "text" field alone, which
#     live-verification proved holds only the LAST text segment when a turn
#     interleaves text with a tool call (handle_event's own comment on the
#     message.complete branch has the evidence) - for
#     that sentinel, validates the state word itself, and appends the
#     validated line to the REAL local status file. A line that carries the
#     sentinel but fails validation is never forwarded verbatim: the remote
#     agent cannot make this bridge write arbitrary bytes to the status file
#     merely by emitting them in chat, because only text matching the exact
#     state vocabulary is ever accepted (write_status_line's docstring).
#   - Report: the remote agent wraps its findings between two bare marker
#     lines, FIRSTMATE-REPORT-BEGIN and FIRSTMATE-REPORT-END, in one
#     completed turn. This bridge extracts exactly the text between them and
#     writes it to the real local report file, replacing prior content.
#   - Inbox: every loop iteration (so at least every EVENT_WAIT_TIMEOUT
#     seconds even when nothing else wakes the select() below), this bridge
#     itself lists --inbox-dir for *.msg records (fm-task-inbox-lib.sh's own
#     format: header lines, a bare "--" separator, then the message body),
#     forwards each body through the same _forward() path pane-typed input
#     uses, and moves the record to inbox-dir/handled/ ONLY after a
#     confirmed successful forward - exactly the local read-act-acknowledge
#     loop every other harness's crewmate performs on itself, performed here
#     on the remote agent's behalf because it cannot reach those paths. The
#     doorbell line fm_task_inbox_doorbell_line() types into every pane
#     (starting ": Firstmate instruction waiting:") asks the reader to list
#     and read a LOCAL path the remote agent can never reach; forwarding it
#     as chat would only confuse the model with an instruction it cannot
#     carry out, so this bridge recognizes and swallows that exact line
#     locally instead - the proactive poll above already delivers the real
#     content.
#   - Failure signal: if the protocol itself breaks locally (a malformed
#     status line, a status/report file write that fails, an unreadable or
#     unacknowledgeable inbox record), that is never silent and never
#     something the remote agent's own text can forge: write_status_line()
#     is the one function that ever appends to the real status file, and
#     every failure path calls it with a bridge-authored (not
#     remote-authored) diagnostic line, falling back to a plain pane-visible
#     stderr-equivalent print only if that write itself fails.
#
# Delivery confirmation mirrors the native hermes adapter's own convention
# (docs/verification/hermes.md "Delivery gate"): every line this bridge
# forwards is first echoed to stdout with a leading bullet - the same
# marker hermes itself prepends to an accepted, submitted message - so
# fm-spawn.sh's readiness/delivery gates can grep this pane's plain-text
# capture for that literal marker exactly like the native adapter's gate
# does, without inventing a second convention.
#
# Event payload shapes below are read directly from the real Hermes source
# (tui_gateway/server.py on the local install, the same tree
# bin/fm-hermes-ws.py's wire-protocol section was grounded against):
# message.delta carries {"text": <chunk>}; message.complete carries
# {"text": <final>, "status": "complete"|"interrupted"|"error", ...};
# tool.start carries {"tool_id", "name", "context", ...}; tool.complete
# carries {"tool_id", "name", "summary"|"result", ...}. Every other event
# type (reasoning.available, subagent.*, tool.generating, todo updates) is
# deliberately not rendered - an initial pane-rendering scope, not a
# wire-protocol gap.
import importlib.util
import os
import re
import select
import signal
import sys
import time

_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
_WS_MODULE_PATH = os.path.join(_SCRIPT_DIR, 'fm-hermes-ws.py')


def _load_ws_module():
    spec = importlib.util.spec_from_file_location('fm_hermes_ws', _WS_MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


_ws = _load_ws_module()
HermesWsSession = _ws.HermesWsSession
HermesWsError = _ws.HermesWsError

READY_PREFIX = 'Hermes VPS bridge ready.'
BRIEF_POINTER_PREFIX = 'Read the brief at '
BRIEF_POINTER_SUFFIX = ' and follow it exactly.'
BULLET = '●'
EVENT_WAIT_TIMEOUT = 30.0
RECONNECT_ATTEMPTS = 5
RECONNECT_BACKOFF = 2.0

# The doorbell line fm_task_inbox_doorbell_line() (bin/fm-task-inbox-lib.sh)
# types into every pane for a steering message - that file is the one owner
# of the exact wording. Only the stable, self-describing prefix is matched
# here, the same "recognize a known local convention, don't restate it"
# pattern BRIEF_POINTER_PREFIX/SUFFIX above already use for fm-spawn.sh's
# launch-then-send pointer sentence.
DOORBELL_PREFIX = ': Firstmate instruction waiting:'

# Status/report protocol (see the module docstring's "Status/report/inbox
# protocol" section). fm-classify-lib.sh is the one owner of the state
# vocabulary; FM_CLASSIFY_PAUSED_VERB is read the same way every shell
# producer of a status line already does, so a captain override of the
# paused verb is honored here too.
STATUS_SENTINEL = 'FIRSTMATE-STATUS: '
REPORT_BEGIN_MARKER = 'FIRSTMATE-REPORT-BEGIN'
REPORT_END_MARKER = 'FIRSTMATE-REPORT-END'
_PAUSED_VERB = os.environ.get('FM_CLASSIFY_PAUSED_VERB') or 'paused'
VALID_STATUS_STATES = frozenset(
    {'working', 'needs-decision', 'blocked', _PAUSED_VERB, 'done', 'failed', 'resolved'}
)
# "<state>[ [key=<slug>]]: <note>", the same shape every other harness's
# brief already renders as `echo "{state}: {note}" >> status-file`.
_STATUS_LINE_RE = re.compile(r'^([A-Za-z][A-Za-z-]*)(\s*\[key=[^\]\s]+\])?:\s*(\S.*)$')

INBOX_POLL_INTERVAL = EVENT_WAIT_TIMEOUT


def _parse_args(argv):
    cwd = None
    status_file = None
    report_file = None
    inbox_dir = None
    i = 1
    while i < len(argv):
        if argv[i] == '--cwd' and i + 1 < len(argv):
            cwd = argv[i + 1]
            i += 2
            continue
        if argv[i] == '--status-file' and i + 1 < len(argv):
            status_file = argv[i + 1]
            i += 2
            continue
        if argv[i] == '--report-file' and i + 1 < len(argv):
            report_file = argv[i + 1]
            i += 2
            continue
        if argv[i] == '--inbox-dir' and i + 1 < len(argv):
            inbox_dir = argv[i + 1]
            i += 2
            continue
        i += 1
    if not cwd:
        print('fm-hermes-vps-bridge: --cwd is required', file=sys.stderr)
        sys.exit(2)
    return cwd, status_file, report_file, inbox_dir


def _echo(line):
    print(f'{BULLET} {line}', flush=True)


def _inbox_record_body(raw):
    """Body of one fm-task-inbox-lib.sh record: header lines, a bare "--"
    separator line, then the message text verbatim. Returns None when no
    separator is present (a malformed or foreign file), matching
    fm_task_inbox_body's own contract without sourcing shell from Python."""
    lines = raw.split('\n')
    for idx, ln in enumerate(lines):
        if ln == '--':
            return '\n'.join(lines[idx + 1:])
    return None


class Bridge:
    def __init__(self, cwd, status_file=None, report_file=None, inbox_dir=None):
        self.cwd = cwd
        self.status_file = status_file
        self.report_file = report_file
        self.inbox_dir = inbox_dir
        self.session = HermesWsSession()
        self.session_id = None
        self.busy = False
        self.brief_delivered = False
        self._shutdown = False
        self._stdin_fd = sys.stdin.fileno()
        self._stdin_buf = b''
        self._turn_text_buf = ''
        self._last_inbox_poll = 0.0

    def start(self):
        created = self.session.rpc('session.create', {'cwd': self.cwd})
        self.session_id = created.get('session_id')
        if not self.session_id:
            raise HermesWsError(f'session.create returned no session_id: {created}')
        print(f'{READY_PREFIX} session_id={self.session_id}', flush=True)

    def _forward(self, text):
        """Submit or steer <text> depending on the last-observed turn state.
        A real RPC failure is printed into the pane rather than swallowed -
        a captain steering a wedged session needs to see that, not silence.
        Returns True once the RPC is confirmed sent, False otherwise, so a
        caller with its own delivery-then-acknowledge contract (the inbox
        poll below) never acknowledges a delivery that never happened."""
        try:
            method = 'session.steer' if self.busy else 'prompt.submit'
            self.session.rpc(method, {'session_id': self.session_id, 'text': text})
            return True
        except HermesWsError as exc:
            # One reconnect-and-retry: the connection may have dropped (see
            # reconnect()'s docstring) between the last event and this input.
            if not self.reconnect():
                print(f'[fm-hermes-vps-bridge] delivery failed: {exc}', flush=True)
                return False
            try:
                self.session.rpc(method, {'session_id': self.session_id, 'text': text})
                return True
            except HermesWsError as exc2:
                print(f'[fm-hermes-vps-bridge] delivery failed: {exc2}', flush=True)
                return False

    def write_status_line(self, line):
        """The ONE function that ever appends to the real local status file.
        Used both for a remote status line already validated by
        _apply_remote_status_line, and for every bridge-authored diagnostic
        below - so a protocol failure always has a path to become
        Firstmate-visible through the same channel a healthy status update
        would use. Best-effort: a write failure here falls back to a plain
        pane-visible print rather than raising, because there is nothing
        further local to retry against and the pane itself remains a valid,
        Firstmate-readable failure signal."""
        if not self.status_file:
            return
        try:
            with open(self.status_file, 'a', encoding='utf-8') as fh:
                fh.write(line.rstrip('\n') + '\n')
        except OSError as exc:
            print(f'[fm-hermes-vps-bridge] status write failed ({line.strip()!r}): {exc}', flush=True)

    def _apply_remote_status_line(self, candidate):
        """<candidate> is the text after STATUS_SENTINEL in one completed
        turn's final text. Never appended verbatim: only a line whose state
        word is in VALID_STATUS_STATES is accepted, so the remote agent can
        never make this bridge write arbitrary bytes to the status file by
        emitting them in chat - it can only ever select from the same
        vocabulary every other harness's brief already uses."""
        match = _STATUS_LINE_RE.match(candidate)
        state = match.group(1) if match else None
        if not match or state not in VALID_STATUS_STATES:
            self.write_status_line(
                'blocked: hermes-vps bridge rejected a malformed status line from the remote '
                f'session (state must be one of {", ".join(sorted(VALID_STATUS_STATES))}): '
                f'{candidate.strip()[:200]!r}'
            )
            return
        self.write_status_line(candidate)

    def _write_report(self, content):
        if not self.report_file:
            return
        if not content.strip():
            self.write_status_line(
                'blocked: hermes-vps bridge received an empty FIRSTMATE-REPORT block from the '
                'remote session; report not written'
            )
            return
        try:
            report_dir = os.path.dirname(self.report_file)
            if report_dir:
                os.makedirs(report_dir, exist_ok=True)
            with open(self.report_file, 'w', encoding='utf-8') as fh:
                fh.write(content if content.endswith('\n') else content + '\n')
        except OSError as exc:
            print(f'[fm-hermes-vps-bridge] report write failed: {exc}', flush=True)
            self.write_status_line(f'blocked: hermes-vps bridge could not write the report locally: {exc}')

    def _process_turn_text(self, text):
        """Called with one turn's FULL accumulated text (every message.delta
        chunk concatenated since the last message.start, never a bare
        partial delta and never message.complete's own possibly-truncated
        "text" field alone - see handle_event's message.complete comment).
        A marker split across streamed chunks is never misread because this
        only ever sees the assembled whole. Extracts at most one
        FIRSTMATE-REPORT block and every FIRSTMATE-STATUS line; the
        rendered pane output is untouched, these markers are also visible
        there like any other turn text."""
        lines = text.splitlines()
        begin_idx = end_idx = None
        for idx, raw in enumerate(lines):
            stripped = raw.strip()
            if begin_idx is None and stripped == REPORT_BEGIN_MARKER:
                begin_idx = idx
            elif begin_idx is not None and end_idx is None and stripped == REPORT_END_MARKER:
                end_idx = idx
                break
        if begin_idx is not None and end_idx is not None:
            self._write_report('\n'.join(lines[begin_idx + 1:end_idx]))
        for raw in lines:
            stripped = raw.strip()
            if stripped.startswith(STATUS_SENTINEL):
                self._apply_remote_status_line(stripped[len(STATUS_SENTINEL):])

    def _inbox_handled_dir(self):
        return os.path.join(self.inbox_dir, 'handled')

    def poll_inbox(self):
        """Read-act-acknowledge the steering inbox on the remote agent's
        behalf, since it cannot reach --inbox-dir itself (module docstring's
        "Status/report/inbox protocol"). A record is moved to handled/ ONLY
        after _forward() confirms delivery, so a dropped connection leaves it
        in place for the next poll instead of silently losing the steer -
        the same durable retry the inbox contract already gives every other
        harness (fm-task-inbox-lib.sh)."""
        if not self.inbox_dir:
            return
        try:
            names = os.listdir(self.inbox_dir)
        except OSError:
            return
        records = []
        for name in names:
            if not name.endswith('.msg'):
                continue
            stem = name[:-4]
            if not stem.isdigit():
                continue
            records.append((int(stem), name))
        for _, name in sorted(records):
            path = os.path.join(self.inbox_dir, name)
            try:
                with open(path, 'r', encoding='utf-8') as fh:
                    raw = fh.read()
            except OSError as exc:
                self.write_status_line(
                    f'blocked: hermes-vps bridge could not read steering inbox record {name}: {exc}'
                )
                continue
            body = _inbox_record_body(raw)
            if body is None:
                self.write_status_line(
                    f'blocked: hermes-vps bridge found a malformed steering inbox record {name} '
                    '(no "--" body separator)'
                )
                continue
            if not self._forward(body):
                continue  # left in place; retried on the next poll
            handled_dir = self._inbox_handled_dir()
            try:
                os.makedirs(handled_dir, exist_ok=True)
                os.rename(path, os.path.join(handled_dir, name))
            except OSError as exc:
                self.write_status_line(
                    f'blocked: hermes-vps bridge delivered steering message {name} but could not '
                    f'acknowledge it (move to handled/ failed): {exc}'
                )

    def handle_input_line(self, line):
        if line.startswith(DOORBELL_PREFIX):
            # This tells the reader to list and read a LOCAL path the remote
            # agent can never reach; poll_inbox() above already delivers the
            # real content proactively, so forwarding this would only hand
            # the model an instruction it cannot carry out.
            return
        if (not self.brief_delivered and line.startswith(BRIEF_POINTER_PREFIX)
                and line.endswith(BRIEF_POINTER_SUFFIX)):
            path = line[len(BRIEF_POINTER_PREFIX):-len(BRIEF_POINTER_SUFFIX)]
            if os.path.isfile(path):
                self.brief_delivered = True
                _echo(line)
                try:
                    with open(path, 'r', encoding='utf-8') as fh:
                        content = fh.read()
                except OSError as exc:
                    print(f'[fm-hermes-vps-bridge] could not read brief at {path}: {exc}', flush=True)
                    return
                self._forward(content)
                return
            print(f'[fm-hermes-vps-bridge] brief not found at {path}', flush=True)
            return
        if line == '/exit':
            self.shutdown()
            return
        if line == '/interrupt':
            # A real RPC, not a submitted chat message - bin/fm-control-lib.sh's
            # fm_control_interrupt_via_text names this exact line as
            # hermes-vps's interrupt delivery, reusing the ordinary
            # text-submit pane mechanic every other harness's exit command
            # already rides, rather than a named terminal key (this
            # transport has no pane composer for one to act on).
            try:
                self.session.rpc('session.interrupt', {'session_id': self.session_id})
            except HermesWsError:
                if not self.reconnect():
                    print('[fm-hermes-vps-bridge] interrupt failed: connection lost', flush=True)
                    return
                try:
                    self.session.rpc('session.interrupt', {'session_id': self.session_id})
                except HermesWsError as exc2:
                    print(f'[fm-hermes-vps-bridge] interrupt failed: {exc2}', flush=True)
                    return
            print('[interrupted]', flush=True)
            return
        _echo(line)
        self._forward(line)

    def handle_event(self, envelope):
        payload = envelope.get('params') or {}
        etype = payload.get('type')
        data = payload.get('payload') or {}
        if etype == 'message.start':
            self.busy = True
            self._turn_text_buf = ''
        elif etype == 'message.delta':
            text = data.get('text', '')
            if text:
                sys.stdout.write(text)
                sys.stdout.flush()
                self._turn_text_buf += text
        elif etype == 'message.complete':
            self.busy = False
            status = data.get('status', 'complete')
            print(f'\n[turn {status}]', flush=True)
            # message.complete's own "text" field is NOT reliably the turn's
            # full cumulative text: live-verified against the real VPS
            # (data/hv-protocol-verify/report.md), a turn that emits text,
            # then a tool call, then more text fires exactly ONE
            # message.start/message.complete pair for the whole turn, and
            # that field holds only the LAST text segment - the FIRST
            # segment (e.g. an opening FIRSTMATE-STATUS line before the
            # agent reaches for a tool) is silently absent from it, even
            # though it streamed correctly through message.delta above and
            # rendered in the pane. The accumulated delta buffer is the
            # complete, authoritative record of everything this turn
            # actually said; message.complete's own field is used only as a
            # fallback for the degenerate case of a complete with no
            # preceding deltas at all.
            text = self._turn_text_buf or (data.get('text') or '')
            if text:
                self._process_turn_text(text)
        elif etype == 'tool.start':
            name = data.get('name', '?')
            context = data.get('context', '')
            print(f'\n[tool start] {name} {context}'.rstrip(), flush=True)
        elif etype == 'tool.complete':
            name = data.get('name', '?')
            summary = data.get('summary') or ''
            print(f'[tool complete] {name} {summary}'.rstrip(), flush=True)
        elif etype == 'error':
            self.busy = False
            message = data.get('message', envelope)
            print(f'\n[error] {message}', flush=True)

    def shutdown(self):
        if self._shutdown:
            return
        self._shutdown = True
        try:
            self.session.rpc('session.close', {'session_id': self.session_id}, timeout=10)
        except Exception:
            pass
        try:
            self.session.close()
        except Exception:
            pass

    def reconnect(self):
        """Re-establish the WS connection after the server drops it.
        Live-verified: the real VPS gateway closes the connection right
        after a successful session.interrupt (and, presumably, on other
        transient network hiccups), even though the session itself survives
        and a brand-new connection can freely issue RPCs against its
        existing session_id (also live-verified: session.status/steer/
        interrupt/close all work from a connection that never created the
        session - see docs/verification/hermes.md). Losing the bridge over
        a dropped connection would silently kill an otherwise-healthy
        crewmate task, so this replaces self.session rather than exiting."""
        for _attempt in range(RECONNECT_ATTEMPTS):
            try:
                new_session = HermesWsSession()
            except HermesWsError:
                time.sleep(RECONNECT_BACKOFF)
                continue
            try:
                self.session.close()
            except Exception:
                pass
            self.session = new_session
            print('[reconnected]', flush=True)
            return True
        return False

    def run(self):
        while not self._shutdown:
            now = time.monotonic()
            if self.inbox_dir and now - self._last_inbox_poll >= INBOX_POLL_INTERVAL:
                self._last_inbox_poll = now
                self.poll_inbox()
            raw_sock = self.session._sock._sock  # same-process bridge; not crossing a public API boundary
            try:
                readable, _, _ = select.select([self._stdin_fd, raw_sock], [], [], EVENT_WAIT_TIMEOUT)
            except (OSError, ValueError):
                if self.reconnect():
                    continue
                break
            if raw_sock in readable:
                try:
                    envelope = self.session.next_event(EVENT_WAIT_TIMEOUT)
                except HermesWsError as exc:
                    # select() reporting the socket readable proves activity
                    # (a TCP-level signal such as a keepalive probe, not
                    # necessarily an application frame), so a bare read
                    # timeout here is not proof the connection died - only a
                    # real protocol/close error is. Treating every timeout as
                    # fatal would tear down a long-idle-but-healthy session
                    # (nobody typing, no VPS activity) on nothing more than a
                    # spurious wakeup.
                    if 'timed out' in str(exc):
                        continue
                    print(f'[fm-hermes-vps-bridge] connection lost: {exc}', flush=True)
                    if self.reconnect():
                        continue
                    break
                self.handle_event(envelope)
                # Drain any further events already sitting in this client's
                # own read buffer: the server can (and does, e.g. every
                # prompt.submit reply immediately followed by
                # message.start/delta/complete) send several push frames
                # back-to-back inside one TCP segment. select() alone would
                # miss them here - it only reports fresh bytes at the OS
                # socket, not messages HermesWsSession already parsed out of
                # its own internal buffer, so without this a same-segment
                # message.complete could sit unread until unrelated new
                # traffic happened to arrive.
                while True:
                    try:
                        envelope = self.session.next_event(0.05)
                    except HermesWsError:
                        break
                    self.handle_event(envelope)
            if self._stdin_fd in readable:
                # Raw os.read(), not sys.stdin.readline(): a buffered
                # TextIOWrapper can pull MULTIPLE newline-terminated lines
                # into its own internal buffer from a single underlying
                # read() whenever more than one line is already queued on
                # the pipe (exactly what a steering doorbell immediately
                # followed by real content produces) - readline() would then
                # return the first line while stranding the second INSIDE
                # that buffer, invisible to select(), which only observes
                # the OS-level fd. select() would report "not readable" on
                # the next iteration even though a second line is sitting
                # ready, and the bridge would wedge for up to
                # EVENT_WAIT_TIMEOUT seconds. Reading raw bytes ourselves and
                # splitting on '\n' keeps everything select() can see.
                chunk = os.read(self._stdin_fd, 65536)
                if chunk == b'':
                    self.shutdown()
                    break
                self._stdin_buf += chunk
                while b'\n' in self._stdin_buf:
                    raw_line, self._stdin_buf = self._stdin_buf.split(b'\n', 1)
                    self.handle_input_line(raw_line.decode('utf-8', errors='replace').rstrip('\r'))


def main(argv):
    cwd, status_file, report_file, inbox_dir = _parse_args(argv)
    bridge = Bridge(cwd, status_file=status_file, report_file=report_file, inbox_dir=inbox_dir)

    def _on_term(_signum, _frame):
        bridge.shutdown()
        sys.exit(0)

    signal.signal(signal.SIGTERM, _on_term)
    signal.signal(signal.SIGINT, _on_term)
    signal.signal(signal.SIGHUP, _on_term)
    try:
        bridge.start()
    except HermesWsError as exc:
        print(f'fm-hermes-vps-bridge: {exc}', file=sys.stderr)
        return 1
    try:
        bridge.run()
    finally:
        bridge.shutdown()
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
