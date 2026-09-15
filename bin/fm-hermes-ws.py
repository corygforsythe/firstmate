#!/usr/bin/env python3
# fm-hermes-ws.py - JSON-RPC-over-WebSocket client for a Hermes Agent
# dashboard/serve gateway's /api/ws session API.
#
# Standalone dispatch primitive only: no fm-spawn.sh/fm-control.sh/
# fm-crew-state.sh/fm-busy-lib.sh wiring. See docs/verification/hermes.md
# ("VPS /api/ws gated-mode auth" and the section documenting this client)
# for the source evidence this was built from and what remains
# live-unverified.
#
# Subcommands (each opens one WS connection, runs its RPC, closes):
#   create <cwd>                     -> {"session_id": ...}
#   submit <session_id> <text|->     -> the prompt.submit RPC result
#   status <session_id>              -> the session.status RPC result
#   history <session_id>             -> the session.history RPC result
#   steer <session_id> <text|->      -> the session.steer RPC result
#   interrupt <session_id>           -> the session.interrupt RPC result
#   close <session_id>               -> the session.close RPC result
#   dispatch <cwd> <text|-> [secs]   -> create + submit + wait for
#                                        message.complete/error (default
#                                        300s budget), then session.history;
#                                        prints the final history JSON.
#                                        session.close is sent on every exit
#                                        path (success, a turn error, or a
#                                        timeout), best-effort, so a failed
#                                        turn never leaks the server-side
#                                        session. Smoke-test/live-verify
#                                        convenience, not a fleet primitive.
# "-" for a text argument reads it from stdin, matching fm-mail.py's
# send <to> <subject> <body|-> convention.
#
# All configuration and credentials arrive through the environment, never
# through argv, so a secret never appears in argv, a status line, or a
# process listing (the same contract as FM_MAIL_USER/FM_MAIL_PASS in
# fm-mail.py):
#   FM_HERMES_WS_BASE_URL   Required. e.g. http://your-vps-host:9119
#   FM_HERMES_WS_TOKEN      Loopback/--insecure static session token
#                            (?token=). Mutually exclusive with USER/PASS.
#   FM_HERMES_WS_USER       Gated-mode username (POST /auth/password-login).
#   FM_HERMES_WS_PASS       Gated-mode password.
#   FM_HERMES_WS_PROVIDER   Gated-mode provider name. Default "basic" - the
#                            only provider the captain's VPS registers
#                            (confirmed live: GET /api/auth/providers).
#   FM_HERMES_WS_ORIGIN     Origin header override. Default derived from
#                            FM_HERMES_WS_BASE_URL. hermes_cli/web_server.py's
#                            CORS middleware allow_origin_regex only matches
#                            localhost/127.0.0.1 origins on the loopback dev
#                            path; whether the gated remote path enforces the
#                            same regex on the WS upgrade specifically is
#                            unconfirmed - override this if a real gated
#                            connect is rejected on Origin.
#   FM_HERMES_WS_TIMEOUT    Seconds for the initial connect/handshake, each
#                            RPC round trip, and each HTTP auth call.
#                            Default 20.
#
# Wire protocol (grounded in the real Hermes Agent source, not the vendor's
# published docs - none exist for this endpoint): tui_gateway/ws.py's
# handle_ws reuses tui_gateway.server.dispatch verbatim, so /api/ws speaks
# the identical JSON-RPC 2.0 shape as Hermes's own stdio gateway
# (tui_gateway/entry.py), one JSON object per WebSocket text frame (or
# newline-delimited within one frame - a real Hermes client,
# evals/liveness/ws_orphan_reconnect.py, splits received frame text on
# newlines defensively; this client does too). A request is
# {"jsonrpc":"2.0","id":<str>,"method":<str>,"params":{...}}; a response is
# matched by "id" and carries "result" or "error"; a push notification has
# no "id" and always uses method "event", with the real event name in
# params.type (confirmed: tui_gateway/ws.py sends
# {"method":"event","params":{"type":"gateway.ready",...}} immediately after
# accept). scripts/iso-certify.py's WSClient - a real first-party Hermes
# client for this exact endpoint - is this script's direct structural model:
# drain the gateway.ready event first, then id-matched request/response,
# and treat a submitted turn as done only on a "message.complete" event
# (or failed on "error", with the message at params.payload.message) -
# never on an earlier event, which can arrive mid-turn.
import base64
import hashlib
import http.client
import json
import os
import secrets
import socket
import ssl
import struct
import sys
import time
from urllib.parse import urlsplit, urlencode

_WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
_OPCODE_CONT = 0x0
_OPCODE_TEXT = 0x1
_OPCODE_CLOSE = 0x8
_OPCODE_PING = 0x9
_OPCODE_PONG = 0xA


class HermesWsError(Exception):
    """A config, auth, protocol, or RPC-level failure. The message is safe to
    print: no code path here ever interpolates a credential into it.
    `code` is the server's own JSON-RPC error code (e.g. 4009 "session
    busy") when this came from an id-matched RPC error reply, None for
    every other failure (connection, protocol, timeout) - a caller that
    needs to react to one specific server-declared condition should check
    `code` rather than pattern-matching the message text."""

    def __init__(self, message, code=None):
        super().__init__(message)
        self.code = code


def _env_timeout():
    raw = os.environ.get('FM_HERMES_WS_TIMEOUT', '20')
    try:
        value = float(raw)
    except (TypeError, ValueError):
        value = 20.0
    return value if value > 0 else 20.0


TIMEOUT = _env_timeout()


def _base_url():
    url = os.environ.get('FM_HERMES_WS_BASE_URL', '')
    if not url:
        raise HermesWsError('FM_HERMES_WS_BASE_URL is required')
    return url.rstrip('/')


def _origin(parts):
    override = os.environ.get('FM_HERMES_WS_ORIGIN', '')
    if override:
        return override
    return f"{parts.scheme}://{parts.netloc}"


def _read_text_arg(raw):
    """A CLI text argument, or stdin's full content when raw is exactly "-"."""
    if raw == '-':
        return sys.stdin.read()
    return raw


# --- Gated-mode auth: POST /auth/password-login -> cookies -> POST
# --- /api/auth/ws-ticket -> a 30s single-use ticket (ws_tickets.py's
# --- TTL_SECONDS). Loopback/--insecure mode skips this entirely and uses a
# --- static FM_HERMES_WS_TOKEN instead.

def _http_connection(parts):
    if parts.scheme == 'https':
        return http.client.HTTPSConnection(parts.hostname, parts.port or 443, timeout=TIMEOUT)
    return http.client.HTTPConnection(parts.hostname, parts.port or 80, timeout=TIMEOUT)


def _cookie_header(set_cookie_headers):
    """Fold every Set-Cookie response header's name=value pair (attributes
    like Path/HttpOnly/Max-Age/SameSite/Secure dropped) into one Cookie
    request header."""
    pairs = []
    for raw in set_cookie_headers:
        first = raw.split(';', 1)[0].strip()
        if '=' in first:
            pairs.append(first)
    return '; '.join(pairs)


def _password_login(parts):
    """Returns the Cookie header value for the session cookies
    /auth/password-login sets on success."""
    user = os.environ.get('FM_HERMES_WS_USER', '')
    password = os.environ.get('FM_HERMES_WS_PASS', '')
    provider = os.environ.get('FM_HERMES_WS_PROVIDER', 'basic')
    if not user or not password:
        raise HermesWsError(
            'FM_HERMES_WS_USER and FM_HERMES_WS_PASS are required in gated mode '
            '(no FM_HERMES_WS_TOKEN set)')
    body = json.dumps({'provider': provider, 'username': user, 'password': password, 'next': ''})
    conn = _http_connection(parts)
    try:
        conn.request('POST', '/auth/password-login', body=body,
                      headers={'Content-Type': 'application/json'})
        resp = conn.getresponse()
        payload = resp.read()
        if resp.status != 200:
            raise HermesWsError(f'/auth/password-login: HTTP {resp.status}')
        cookie_header = _cookie_header(resp.msg.get_all('Set-Cookie') or [])
        if not cookie_header:
            raise HermesWsError('/auth/password-login: no session cookies in the response')
        try:
            ok = json.loads(payload.decode('utf-8')).get('ok')
        except (ValueError, UnicodeDecodeError):
            ok = None
        if ok is not True:
            raise HermesWsError('/auth/password-login: response did not confirm ok:true')
        return cookie_header
    finally:
        conn.close()


def _mint_ticket(parts, cookie_header):
    conn = _http_connection(parts)
    try:
        conn.request('POST', '/api/auth/ws-ticket', body=b'', headers={'Cookie': cookie_header})
        resp = conn.getresponse()
        payload = resp.read()
        if resp.status != 200:
            raise HermesWsError(f'/api/auth/ws-ticket: HTTP {resp.status}')
        data = json.loads(payload.decode('utf-8'))
        ticket = data.get('ticket')
        if not ticket:
            raise HermesWsError('/api/auth/ws-ticket: response had no ticket')
        return ticket
    finally:
        conn.close()


def _ws_auth_param(parts):
    """Returns the (name, value) query-param pair to append to the /api/ws
    URL: a static token in loopback/--insecure mode, or a freshly minted
    30s single-use ticket in gated mode. Mint a new one per connection -
    consume_ticket() is single-use server-side."""
    token = os.environ.get('FM_HERMES_WS_TOKEN', '')
    if token:
        return ('token', token)
    cookie_header = _password_login(parts)
    ticket = _mint_ticket(parts, cookie_header)
    return ('ticket', ticket)


# --- Minimal RFC 6455 client: handshake + text-frame send/recv. Stdlib
# --- only, deliberately: this repo's other python helpers (fm-mail.py)
# --- take the same no-third-party-dependency stance, and the reference
# --- Hermes client script (scripts/iso-certify.py) needs `pip install
# --- websockets`, a dependency this repo has no reason to take on for one
# --- client.

class _WSSocket:
    def __init__(self, parts, origin, timeout):
        use_tls = parts.scheme in ('https', 'wss')
        host = parts.hostname
        port = parts.port or (443 if use_tls else 80)
        try:
            raw = socket.create_connection((host, port), timeout=timeout)
            if use_tls:
                ctx = ssl.create_default_context()
                raw = ctx.wrap_socket(raw, server_hostname=host)
            raw.settimeout(timeout)
        except OSError as exc:
            raise HermesWsError(f'connection error while connecting: {exc}') from exc
        self._sock = raw
        self._buf = b''
        key = base64.b64encode(secrets.token_bytes(16)).decode('ascii')
        path = parts.path or '/'
        if parts.query:
            path = f'{path}?{parts.query}'
        request_lines = [
            f'GET {path} HTTP/1.1',
            f'Host: {host}:{port}',
            'Upgrade: websocket',
            'Connection: Upgrade',
            f'Sec-WebSocket-Key: {key}',
            'Sec-WebSocket-Version: 13',
            f'Origin: {origin}',
            '', '',
        ]
        self._send('\r\n'.join(request_lines).encode('ascii'))
        status_line, headers = self._read_http_response_head()
        if ' 101 ' not in f' {status_line} ':
            raise HermesWsError(f'WebSocket upgrade refused: {status_line.strip()}')
        expected = base64.b64encode(hashlib.sha1((key + _WS_GUID).encode('ascii')).digest()).decode('ascii')
        accept = headers.get('sec-websocket-accept', '')
        if accept != expected:
            raise HermesWsError('WebSocket upgrade response failed the Sec-WebSocket-Accept check')

    def _send(self, data):
        """Every raw socket write funnels through here so a dead or reset
        connection (BrokenPipeError, ConnectionResetError, a bare
        socket.timeout, an ssl.SSLError - none of which are HermesWsError)
        can never escape as an unwrapped exception. Uncaught, one of those
        would propagate straight through rpc() -> Bridge._forward() (which
        only catches HermesWsError) and out of Bridge.run()'s main loop,
        which has no handler around handle_input_line() either - crashing
        the whole bridge process with a bare traceback and, critically, no
        write_status_line() call, silently ending the crewmate exactly the
        way this bridge exists to prevent (module docstring's "Status/
        report/inbox protocol")."""
        try:
            self._sock.sendall(data)
        except OSError as exc:
            raise HermesWsError(f'connection error while sending: {exc}') from exc

    def _recv(self, nbytes):
        try:
            return self._sock.recv(nbytes)
        except OSError as exc:
            raise HermesWsError(f'connection error while receiving: {exc}') from exc

    def _recv_exact(self, n):
        while len(self._buf) < n:
            chunk = self._recv(max(4096, n - len(self._buf)))
            if not chunk:
                raise HermesWsError('connection closed before the expected bytes arrived')
            self._buf += chunk
        data, self._buf = self._buf[:n], self._buf[n:]
        return data

    def _read_http_response_head(self):
        head = b''
        while b'\r\n\r\n' not in head:
            chunk = self._recv(4096)
            if not chunk:
                raise HermesWsError('connection closed during the HTTP upgrade handshake')
            head += chunk
        head, rest = head.split(b'\r\n\r\n', 1)
        self._buf = rest + self._buf
        lines = head.decode('iso-8859-1').split('\r\n')
        status_line = lines[0]
        headers = {}
        for line in lines[1:]:
            if ':' in line:
                name, value = line.split(':', 1)
                headers[name.strip().lower()] = value.strip()
        return status_line, headers

    def send_text(self, text):
        payload = text.encode('utf-8')
        length = len(payload)
        header = bytearray()
        header.append(0x80 | _OPCODE_TEXT)
        if length < 126:
            header.append(0x80 | length)
        elif length < 65536:
            header.append(0x80 | 126)
            header += struct.pack('>H', length)
        else:
            header.append(0x80 | 127)
            header += struct.pack('>Q', length)
        mask = secrets.token_bytes(4)
        header += mask
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self._send(bytes(header) + masked)

    def _recv_frame(self):
        b0, b1 = self._recv_exact(2)
        fin = bool(b0 & 0x80)
        opcode = b0 & 0x0F
        masked = bool(b1 & 0x80)
        length = b1 & 0x7F
        if length == 126:
            (length,) = struct.unpack('>H', self._recv_exact(2))
        elif length == 127:
            (length,) = struct.unpack('>Q', self._recv_exact(8))
        mask = self._recv_exact(4) if masked else None
        payload = self._recv_exact(length) if length else b''
        if mask:
            payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        return fin, opcode, payload

    def recv_text(self, deadline):
        """Blocks for one complete (possibly fragmented) text message, up to
        `deadline` (monotonic seconds). Answers a ping inline and skips
        pongs; raises on a close frame."""
        assembled = b''
        assembling_text = False
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise HermesWsError('timed out waiting for a WebSocket message')
            try:
                self._sock.settimeout(remaining)
            except OSError as exc:
                raise HermesWsError(f'connection error while setting timeout: {exc}') from exc
            fin, opcode, payload = self._recv_frame()
            if opcode == _OPCODE_PING:
                self._send_control(_OPCODE_PONG, payload)
                continue
            if opcode == _OPCODE_PONG:
                continue
            if opcode == _OPCODE_CLOSE:
                raise HermesWsError('the gateway closed the WebSocket connection')
            if opcode == _OPCODE_TEXT:
                assembled = payload
                assembling_text = True
            elif opcode == _OPCODE_CONT and assembling_text:
                assembled += payload
            else:
                continue
            if fin:
                return assembled.decode('utf-8', errors='replace')

    def _send_control(self, opcode, payload):
        mask = secrets.token_bytes(4)
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        header = bytes([0x80 | opcode, 0x80 | len(payload)]) + mask
        self._send(header + masked)

    def close(self):
        try:
            self._send_control(_OPCODE_CLOSE, b'')
        except HermesWsError:
            pass
        try:
            self._sock.close()
        except OSError:
            pass


class HermesWsSession:
    """One /api/ws connection: drains gateway.ready on connect, then does
    id-matched JSON-RPC request/response. Any notification observed while
    waiting for an RPC reply (an `event`) is queued and replayed to the
    next `wait_event`/`rpc` caller in arrival order, never dropped."""

    def __init__(self):
        base = _base_url()
        parts = urlsplit(base)
        auth_name, auth_value = _ws_auth_param(parts)
        ws_scheme = 'wss' if parts.scheme == 'https' else 'ws'
        query = urlencode({auth_name: auth_value})
        ws_url = urlsplit(f'{ws_scheme}://{parts.netloc}/api/ws?{query}')
        self._sock = _WSSocket(ws_url, _origin(parts), TIMEOUT)
        self._next_id = 0
        self._pending = []
        self._deadline0 = time.monotonic() + TIMEOUT
        self._drain_ready()

    def _drain_ready(self):
        while True:
            msg = self._raw_recv(self._deadline0)
            if msg.get('method') == 'event' and (msg.get('params') or {}).get('type') == 'gateway.ready':
                return
            self._pending.append(msg)

    def _raw_recv(self, deadline):
        text = self._sock.recv_text(deadline)
        try:
            return json.loads(text)
        except json.JSONDecodeError as exc:
            raise HermesWsError(f'non-JSON WebSocket message: {text[:200]!r}') from exc

    def next_event(self, timeout):
        """Blocks up to `timeout` seconds for the next `event` notification
        (queued ones first), returning its full envelope."""
        deadline = time.monotonic() + timeout
        while True:
            if self._pending:
                msg = self._pending.pop(0)
            else:
                msg = self._raw_recv(deadline)
            if msg.get('method') == 'event':
                return msg
            # A stray id-tagged reply nobody is waiting on; drop it.

    def rpc(self, method, params, timeout=None):
        rid = str(self._next_id)
        self._next_id += 1
        self._sock.send_text(json.dumps({'jsonrpc': '2.0', 'id': rid, 'method': method, 'params': params}))
        deadline = time.monotonic() + (timeout if timeout is not None else TIMEOUT)
        while True:
            if self._pending and self._pending[0].get('id') == rid:
                msg = self._pending.pop(0)
            else:
                msg = self._raw_recv(deadline)
                if msg.get('id') != rid:
                    self._pending.append(msg)
                    continue
            if 'error' in msg and msg['error'] is not None:
                err = msg['error']
                code = err.get('code') if isinstance(err, dict) else None
                raise HermesWsError(f'{method}: {err}', code=code)
            return msg.get('result')

    def close(self):
        self._sock.close()


def _print_result(result):
    print(json.dumps(result))


def cmd_create(args):
    if len(args) != 1:
        raise HermesWsError('usage: create <cwd>')
    session = HermesWsSession()
    try:
        _print_result(session.rpc('session.create', {'cwd': args[0]}))
    finally:
        session.close()


def cmd_submit(args):
    if len(args) != 2:
        raise HermesWsError('usage: submit <session_id> <text|->')
    session_id, text = args[0], _read_text_arg(args[1])
    session = HermesWsSession()
    try:
        _print_result(session.rpc('prompt.submit', {'session_id': session_id, 'text': text}))
    finally:
        session.close()


def _simple_session_call(method):
    def handler(args):
        if len(args) != 1:
            raise HermesWsError(f'usage: {method.split(".", 1)[1]} <session_id>')
        session = HermesWsSession()
        try:
            _print_result(session.rpc(method, {'session_id': args[0]}))
        finally:
            session.close()
    return handler


def cmd_steer(args):
    if len(args) != 2:
        raise HermesWsError('usage: steer <session_id> <text|->')
    session_id, text = args[0], _read_text_arg(args[1])
    session = HermesWsSession()
    try:
        _print_result(session.rpc('session.steer', {'session_id': session_id, 'text': text}))
    finally:
        session.close()


def cmd_dispatch(args):
    if len(args) not in (2, 3):
        raise HermesWsError('usage: dispatch <cwd> <text|-> [timeout_seconds]')
    cwd, text = args[0], _read_text_arg(args[1])
    budget = float(args[2]) if len(args) == 3 else 300.0
    session = HermesWsSession()
    try:
        created = session.rpc('session.create', {'cwd': cwd})
        session_id = created.get('session_id')
        if not session_id:
            raise HermesWsError(f'session.create returned no session_id: {created}')
        try:
            session.rpc('prompt.submit', {'session_id': session_id, 'text': text})
            deadline = time.monotonic() + budget
            started = False
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise HermesWsError('dispatch timed out waiting for message.complete/error')
                envelope = session.next_event(remaining)
                ptype = (envelope.get('params') or {}).get('type')
                if ptype == 'message.start':
                    started = True
                    continue
                if not started:
                    continue
                if ptype == 'error':
                    payload = (envelope.get('params') or {}).get('payload') or {}
                    raise HermesWsError(f'turn failed: {payload.get("message", envelope)}')
                if ptype == 'message.complete':
                    break
            history = session.rpc('session.history', {'session_id': session_id})
            _print_result(history)
        finally:
            try:
                session.rpc('session.close', {'session_id': session_id})
            except Exception:
                pass
    finally:
        session.close()


_COMMANDS = {
    'create': cmd_create,
    'submit': cmd_submit,
    'status': _simple_session_call('session.status'),
    'history': _simple_session_call('session.history'),
    'steer': cmd_steer,
    'interrupt': _simple_session_call('session.interrupt'),
    'close': _simple_session_call('session.close'),
    'dispatch': cmd_dispatch,
}


def main(argv):
    if len(argv) < 2 or argv[1] not in _COMMANDS:
        names = ', '.join(sorted(_COMMANDS))
        print(f'usage: fm-hermes-ws.py <{names}> [args...]', file=sys.stderr)
        return 2
    try:
        _COMMANDS[argv[1]](argv[2:])
    except HermesWsError as exc:
        print(f'fm-hermes-ws.py: {exc}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
