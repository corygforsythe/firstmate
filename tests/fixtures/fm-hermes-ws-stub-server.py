#!/usr/bin/env python3
# tests/fixtures/fm-hermes-ws-stub-server.py - a minimal, offline stand-in
# for a Hermes Agent dashboard's /auth/password-login, /api/auth/ws-ticket,
# and /api/ws endpoints, used only by tests/fm-hermes-ws.test.sh.
#
# This is a test double, not a reimplementation of Hermes: it exists to
# prove bin/fm-hermes-ws.py's real HTTP + RFC 6455 WebSocket handling
# against a real socket, without needing Hermes installed or a live VPS.
# The JSON-RPC method set it answers (session.create, prompt.submit,
# session.status, session.history, session.steer, session.interrupt,
# session.close) and the gated-mode auth handshake (password-login ->
# cookie -> ws-ticket -> ?ticket=) mirror the real wire evidence recorded
# in docs/verification/hermes.md; server-side WS framing here is
# deliberately independent of fm-hermes-ws.py's own framing code, so a bug
# shared by both would not hide behind a passing test.
#
# Usage: fm-hermes-ws-stub-server.py <port> <username> <password> <static-token> [rpc-log-path]
#
# The optional rpc-log-path records every RPC method (and session_id, when
# present) this stub receives, one JSON object per line, flushed
# immediately. This is what lets a test prove a client actually sent an RPC
# over the wire (e.g. session.close after an error/timeout) rather than
# just observing the client's own exit code/stderr, which only proves what
# the client *reported*, not what it *did*.
import base64
import hashlib
import http.server
import json
import secrets
import struct
import sys
import threading

_WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
PORT, USERNAME, PASSWORD, STATIC_TOKEN = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
RPC_LOG = sys.argv[5] if len(sys.argv) > 5 else None

_lock = threading.Lock()
_cookies = set()
_tickets = set()
_log_lock = threading.Lock()


def _log_rpc(method, params):
    if not RPC_LOG:
        return
    line = json.dumps({'method': method, 'session_id': params.get('session_id')})
    with _log_lock:
        with open(RPC_LOG, 'a') as f:
            f.write(line + '\n')


def _send_frame(wfile, opcode, payload):
    header = bytearray([0x80 | opcode])
    length = len(payload)
    if length < 126:
        header.append(length)
    elif length < 65536:
        header.append(126)
        header += struct.pack('>H', length)
    else:
        header.append(127)
        header += struct.pack('>Q', length)
    wfile.write(bytes(header) + payload)
    wfile.flush()


def _send_text(wfile, text):
    _send_frame(wfile, 0x1, text.encode('utf-8'))


def _recv_frame(rfile):
    b0, b1 = rfile.read(1)[0], rfile.read(1)[0]
    opcode = b0 & 0x0F
    length = b1 & 0x7F
    if length == 126:
        (length,) = struct.unpack('>H', rfile.read(2))
    elif length == 127:
        (length,) = struct.unpack('>Q', rfile.read(8))
    mask = rfile.read(4)  # client frames are always masked
    payload = rfile.read(length)
    unmasked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    return opcode, unmasked


def _rpc_result(req_id, result):
    return json.dumps({'jsonrpc': '2.0', 'id': req_id, 'result': result})


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, fmt, *args):
        pass

    def _json_body(self):
        length = int(self.headers.get('Content-Length', '0') or '0')
        raw = self.rfile.read(length) if length else b''
        return json.loads(raw.decode('utf-8')) if raw else {}

    def do_POST(self):
        if self.path == '/auth/password-login':
            body = self._json_body()
            if body.get('provider') == 'basic' and body.get('username') == USERNAME \
                    and body.get('password') == PASSWORD:
                cookie = secrets.token_urlsafe(16)
                with _lock:
                    _cookies.add(cookie)
                payload = json.dumps({'ok': True, 'next': '/'}).encode('utf-8')
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(payload)))
                self.send_header('Set-Cookie', f'hermes_session_at={cookie}; Path=/; HttpOnly')
                self.end_headers()
                self.wfile.write(payload)
            else:
                payload = json.dumps({'detail': 'Invalid credentials'}).encode('utf-8')
                self.send_response(401)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
            return
        if self.path == '/api/auth/ws-ticket':
            cookie_header = self.headers.get('Cookie', '')
            cookie = ''
            for part in cookie_header.split(';'):
                part = part.strip()
                if part.startswith('hermes_session_at='):
                    cookie = part.split('=', 1)[1]
            with _lock:
                ok = cookie in _cookies
            if ok:
                ticket = secrets.token_urlsafe(16)
                with _lock:
                    _tickets.add(ticket)
                payload = json.dumps({'ticket': ticket, 'ttl_seconds': 30}).encode('utf-8')
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
            else:
                self.send_response(401)
                self.send_header('Content-Length', '0')
                self.end_headers()
            return
        self.send_response(404)
        self.send_header('Content-Length', '0')
        self.end_headers()

    def do_GET(self):
        if self.path.startswith('/api/ws'):
            self._handle_ws()
            return
        self.send_response(404)
        self.send_header('Content-Length', '0')
        self.end_headers()

    def _authorized(self):
        query = self.path.split('?', 1)[1] if '?' in self.path else ''
        params = dict(p.split('=', 1) for p in query.split('&') if '=' in p)
        if params.get('token') == STATIC_TOKEN:
            return True
        ticket = params.get('ticket')
        if ticket:
            with _lock:
                if ticket in _tickets:
                    _tickets.discard(ticket)  # single-use
                    return True
        return False

    def _handle_ws(self):
        if not self._authorized():
            self.send_response(403)
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        key = self.headers.get('Sec-WebSocket-Key', '')
        accept = base64.b64encode(hashlib.sha1((key + _WS_GUID).encode('ascii')).digest()).decode('ascii')
        self.send_response(101, 'Switching Protocols')
        self.send_header('Upgrade', 'websocket')
        self.send_header('Connection', 'Upgrade')
        self.send_header('Sec-WebSocket-Accept', accept)
        self.end_headers()
        _send_text(self.wfile, json.dumps({
            'jsonrpc': '2.0', 'method': 'event',
            'params': {'type': 'gateway.ready', 'payload': {}}}))
        while True:
            try:
                opcode, payload = _recv_frame(self.rfile)
            except Exception:
                return
            if opcode == 0x8:
                _send_frame(self.wfile, 0x8, b'')
                return
            if opcode != 0x1:
                continue
            req = json.loads(payload.decode('utf-8'))
            method, req_id, params = req.get('method'), req.get('id'), req.get('params') or {}
            _log_rpc(method, params)
            if method == 'session.create':
                _send_text(self.wfile, _rpc_result(
                    req_id, {'session_id': 'test-session-1', 'info': {'cwd': params.get('cwd')}}))
            elif method == 'prompt.submit':
                _send_text(self.wfile, _rpc_result(req_id, {'status': 'streaming'}))
                text = params.get('text', '')
                _send_text(self.wfile, json.dumps(
                    {'jsonrpc': '2.0', 'method': 'event', 'params': {'type': 'message.start'}}))
                _send_text(self.wfile, json.dumps(
                    {'jsonrpc': '2.0', 'method': 'event',
                     'params': {'type': 'message.delta', 'text': 'stub'}}))
                if 'TRIGGER_ERROR' in text:
                    _send_text(self.wfile, json.dumps(
                        {'jsonrpc': '2.0', 'method': 'event',
                         'params': {'type': 'error', 'payload': {'message': 'stub turn error'}}}))
                elif 'TRIGGER_HANG' in text:
                    pass  # never send message.complete/error: the client must time out
                else:
                    _send_text(self.wfile, json.dumps(
                        {'jsonrpc': '2.0', 'method': 'event',
                         'params': {'type': 'message.complete', 'text': 'stub reply'}}))
            elif method == 'session.status':
                _send_text(self.wfile, _rpc_result(req_id, {'agent_running': False}))
            elif method == 'session.history':
                _send_text(self.wfile, _rpc_result(
                    req_id, {'count': 1, 'messages': [{'role': 'assistant', 'text': 'stub reply'}]}))
            elif method == 'session.steer':
                _send_text(self.wfile, _rpc_result(req_id, {'steered': True}))
            elif method == 'session.interrupt':
                _send_text(self.wfile, _rpc_result(req_id, {'interrupted': True}))
            elif method == 'session.close':
                _send_text(self.wfile, _rpc_result(req_id, {'closed': True}))
            else:
                _send_text(self.wfile, json.dumps(
                    {'jsonrpc': '2.0', 'id': req_id,
                     'error': {'code': -32601, 'message': f'unknown method {method}'}}))


if __name__ == '__main__':
    server = http.server.ThreadingHTTPServer(('127.0.0.1', int(PORT)), Handler)
    server.serve_forever()
