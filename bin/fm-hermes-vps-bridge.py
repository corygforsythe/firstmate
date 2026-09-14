#!/usr/bin/env python3
# fm-hermes-vps-bridge.py - renders a captain's remote VPS Hermes /api/ws
# session into an ordinary local pane, so a VPS-dispatched Hermes crewmate
# is visible and interactive exactly like a local pane-based crewmate,
# while every busy/interrupt/exit lifecycle question is answered by the
# real, structural /api/ws RPCs documented in docs/verification/hermes.md,
# not by anything rendered here.
#
# Usage: fm-hermes-vps-bridge.py --cwd <path>
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
#   - THE KEY LIMITATION, not solved here: session.create's cwd param is
#     NOT honored on the captain's real VPS deployment (live-verified,
#     docs/verification/hermes.md), so the VPS agent's own file/terminal
#     tools reach only the VPS's OWN filesystem, never this task's local
#     git worktree. A hermes-vps crewmate can converse and use tools in the
#     VPS's own sandbox but cannot read or edit this project's code; do not
#     dispatch a ship/scout task onto it that needs local repo access -
#     see .agents/skills/harness-adapters/references/harness/hermes-vps.md.
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


def _parse_args(argv):
    cwd = None
    i = 1
    while i < len(argv):
        if argv[i] == '--cwd' and i + 1 < len(argv):
            cwd = argv[i + 1]
            i += 2
            continue
        i += 1
    if not cwd:
        print('fm-hermes-vps-bridge: --cwd is required', file=sys.stderr)
        sys.exit(2)
    return cwd


def _echo(line):
    print(f'{BULLET} {line}', flush=True)


class Bridge:
    def __init__(self, cwd):
        self.cwd = cwd
        self.session = HermesWsSession()
        self.session_id = None
        self.busy = False
        self.brief_delivered = False
        self._shutdown = False

    def start(self):
        created = self.session.rpc('session.create', {'cwd': self.cwd})
        self.session_id = created.get('session_id')
        if not self.session_id:
            raise HermesWsError(f'session.create returned no session_id: {created}')
        print(f'{READY_PREFIX} session_id={self.session_id}', flush=True)

    def _forward(self, text):
        """Submit or steer <text> depending on the last-observed turn state.
        A real RPC failure is printed into the pane rather than swallowed -
        a captain steering a wedged session needs to see that, not silence."""
        try:
            method = 'session.steer' if self.busy else 'prompt.submit'
            self.session.rpc(method, {'session_id': self.session_id, 'text': text})
        except HermesWsError as exc:
            # One reconnect-and-retry: the connection may have dropped (see
            # reconnect()'s docstring) between the last event and this input.
            if not self.reconnect():
                print(f'[fm-hermes-vps-bridge] delivery failed: {exc}', flush=True)
                return
            try:
                self.session.rpc(method, {'session_id': self.session_id, 'text': text})
            except HermesWsError as exc2:
                print(f'[fm-hermes-vps-bridge] delivery failed: {exc2}', flush=True)

    def handle_input_line(self, line):
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
        elif etype == 'message.delta':
            text = data.get('text', '')
            if text:
                sys.stdout.write(text)
                sys.stdout.flush()
        elif etype == 'message.complete':
            self.busy = False
            status = data.get('status', 'complete')
            print(f'\n[turn {status}]', flush=True)
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
            raw_sock = self.session._sock._sock  # same-process bridge; not crossing a public API boundary
            try:
                readable, _, _ = select.select([sys.stdin, raw_sock], [], [], EVENT_WAIT_TIMEOUT)
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
            if sys.stdin in readable:
                line = sys.stdin.readline()
                if line == '':
                    self.shutdown()
                    break
                self.handle_input_line(line.rstrip('\n'))


def main(argv):
    cwd = _parse_args(argv)
    bridge = Bridge(cwd)

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
