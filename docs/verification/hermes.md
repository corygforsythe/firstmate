# Verification: the hermes (Hermes Agent CLI) crewmate/scout adapter

Active empirical evidence for firstmate's hermes adapter.
The skill tree rooted at [`.agents/skills/harness-adapters/SKILL.md`](../../.agents/skills/harness-adapters/SKILL.md) owns the operating facts (`references/harness/hermes.md`); this record owns how they were established and what is still unproven.

## Subject

| Field | Value |
|---|---|
| Version | `Hermes Agent v0.16.0 (2026.6.5) · upstream 643b3f45` |
| Verified | 2026-09-13 |
| Binary | `~/.local/bin/hermes`, which execs `~/.hermes/hermes-agent/venv/bin/python3 ~/.hermes/hermes-agent/venv/bin/hermes ...` |
| Platform | macOS arm64 (Darwin 25.6.0) |
| Account | GitHub Copilot via `gh auth token` (pooled credential, `copilot` provider) |

Two prior scout investigations established the baseline facts with no adapter code landed, recorded as private task reports (not tracked in this repo):
`data/hermes-harness-verify/report.md` (launch shape, detection problem, busy/interrupt findings, terminal-backend blocker) and
`data/hermes-serve-verify/report.md` (the `hermes serve`/`/api/ws` JSON-RPC transport alternative).
This task landed the executable owners against those facts, re-verified every load-bearing one live, and found one the scouts could not have found without wiring code against a real dispatch: the delivery gate's composer-empty conjunct (see below).

## Detection

```
$ hermes --cli -m gpt-4o --provider copilot --ignore-user-config   # (inside tmux)
$ ps -o pid,ppid,comm,args -p <child-pid>
  PID  PPID COMM             ARGS
94199 93651 /Users/coryforsy /Users/coryforsythe/.hermes/hermes-agent/venv/bin/python3 /Users/coryforsythe/.hermes/hermes-agent/venv/bin/hermes --cli -m gpt-4o --provider copilot --ignore-user-config
```

`bin/fm-harness.sh`'s `python*` interpreter arm now calls `fm_hermes_args_are_hermes` (from the new `bin/fm-hermes-lib.sh`, the direct python-interpreter analogue of `bin/fm-gemini-lib.sh`'s node-bundle handling).
Confirmed live against the real running process above:

```
$ bin/fm-harness.sh ancestry <pid>
args hermes
```

`bin/fm-agent-process-lib.sh`'s `fm_agent_process_classify` (the tmux/herdr pane-liveness classifier) was extended the same way and confirmed live against the same process:

```
$ fm_agent_process_classify python3 '' "$args" <pid>
agent
```

`tests/fm-hermes-harness.test.sh` pins both the portable unit-level `fm_hermes_args_are_hermes` cases (positive and negative) and the fake-`ps` ancestry integration for the python-interpreter shape.

## Launch: bare launch-then-send, the kimi/rovo shape

`fm-spawn.sh` builds `env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS <hermes-bin> --cli --yolo <model flag>` - BARE, with no positional prompt - wrapped by the shared `env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI` prefix every non-cursor harness gets.
The brief is then typed in after the CLI comes up, through the same shared readers used by kimi/rovo (`fm_backend_capture`, `fm_backend_composer_state`, `fm_backend_send_text_submit`):

1. `hermes_wait_for_ready` polls for the `Welcome to Hermes Agent!` banner (primary) or a composer-empty verdict (fallback).
2. The pointer `Read the brief at <absolute-path> and follow it exactly.` is submitted via `fm_backend_send_text_submit`.
3. `hermes_wait_for_delivery` confirms delivery - see "Delivery gate" below for why this is NOT the rovo/kimi composer-empty-gated shape.

### Why not `--tui` or `-z`/`--oneshot`

Both were tested live and are non-viable (re-confirmed from the prior scout report, not re-litigated here):

```
$ hermes -z "Reply with exactly the single word PONG and nothing else." -m gpt-4o --provider copilot
hermes -z: no final response was produced; treating the run as failed.
```

```
$ hermes --tui ...
Error: Error code: 400 - {'error': {'message': 'model gpt-4o is not supported via Responses API.', 'code': 'unsupported_api_for_model'}}
```

`--cli` is the only mode that reaches a real, working turn on this account.

### The launch-then-send shape, confirmed live end to end via real `bin/fm-spawn.sh`

Three real spawns were driven through the production `bin/fm-spawn.sh` against an isolated scratch firstmate home (`FM_HOME`/`FM_STATE_OVERRIDE`/etc. pointed at a scratch directory) and an isolated tmux server (`TMUX_TMPDIR` pointed at a scratch socket directory) - never the shared production fleet session or its real `data/`/`state/`.

**Attempt 1** (production launch template, no `--ignore-user-config`): spawn succeeded (`spawned <id> harness=hermes ...`), the crewmate read its launch brief, and `bin/fm-crew-state.sh <id>` correctly reported `state: working · source: pane · harness busy (hermes-regex)` - proving detection, launch, and busy classification all work end to end through the real production code path.
It then hung indefinitely (observed past 2 minutes, footer still busy, no progress) retrying `execute_code` to open the brief file - see "Terminal-backend prerequisite" below; this is the exact, anticipated failure mode, not a defect in the adapter code.

**Attempts 2-3** (raw-launch escape hatch per `references/common/dispatch.md`, `--ignore-user-config` added for this proof only, never baked into the production template): spawn succeeded, the agent used `read_file` (no terminal-backend error), and `bin/fm-crew-state.sh` again read the busy state correctly through the whole exchange.
The account's Copilot credential was rate-limited mid-run (`HTTP 429: ... exceeded your rate limit for utility models`) after heavy use across today's two scouts and this task's own testing, so the run did not reach a final reply before this task's time budget - an external quota condition, not an adapter defect.
The safe-interrupt redirect (see below) was exercised against this exact stuck state and worked: typing a new message while the run was retrying printed `Operation interrupted: retrying API call after error...` / `[Interrupted - processing new message]` and the session picked up the new message cleanly.

Both raw-launch verification tmux windows and the isolated tmux server were torn down directly (`tmux kill-window`/`tmux kill-server`) after the observation; no fm-spawn.sh-managed task record or worktree was left registered anywhere, and the scratch `FM_HOME` was deleted.

## Delivery gate: NOT composer-empty-gated, unlike rovo/kimi

This is the one load-bearing fact neither prior scout report could have found, because it only shows up once the gate is actually wired and driven against a real dispatch.

The first implementation copied rovo's exact shape: `hermes_composer_is_empty || return 1` as a hard first conjunct, then an OR of the echoed pointer text or a nonzero context percentage.
Driven live, this reproduced the anticipated composer-ghost-style failure in a different, worse form: while a submitted turn is busy, hermes's prompt row renders `⚕ ❯ msg=interrupt · /queue · /bg · /steer · Ctrl+C cancel` - a shape `bin/fm-composer-lib.sh`'s shared classifier reads as `unknown`, never `empty` - for the agent's ENTIRE first turn, not just a brief in-flight moment. A real `bin/fm-spawn.sh` dispatch against a real hermes install reported `hermes brief pointer delivery was not confirmed` even though the pointer had genuinely been received and the agent had started acting on it (confirmed by direct pane inspection at the moment of failure).

```
$ fm_backend_composer_state tmux firstmate:hermeslab   # idle, bare ❯
empty
$ fm_backend_composer_state tmux firstmate:hermeslab   # busy, ⚕ ❯ msg=interrupt · ...
unknown
```

The fix: `hermes_delivery_is_confirmed` drops the composer-empty conjunct entirely and instead keys off the leading `●` hermes prepends to an accepted, submitted message in its transcript - a signal the unsubmitted (typed-but-not-yet-sent) composer state does NOT share:

```
# typed, not yet submitted (composer row itself):
❯ Read the brief at /tmp/fmhv/fake-brief.md and follow it exactly.
# submitted, echoed into the transcript (separate row, below the composer):
● Read the brief at /tmp/fmhv/fake-brief.md and follow it exactly.
```

The context token count (`<used>/<total>`, e.g. `12.2K/128K`) advancing off its pre-submission `ctx --` value is kept as a second, independent OR-corroborating signal.
Re-verified live after the fix: the same dispatch shape (attempts 2-3 above) succeeded.
`tests/fm-hermes-harness.test.sh`'s `test_hermes_delivery_does_not_require_composer_empty` pins the absence of the composer-empty conjunct so a future edit cannot silently reintroduce this exact regression.

## Terminal-backend prerequisite: reproduced live, not silently worked around

The prior scout report flagged the captain's real `~/.hermes/config.yaml` `terminal.backend: ssh` (no `ssh_host`/`ssh_user` set) as a blocking prerequisite.
This task confirmed the config is still set that way (2026-09-13) and reproduced the exact failure live, end to end, through the production adapter (Attempt 1 above): the agent chose its `execute_code` tool to open the launch brief file, which requires the terminal backend, and hung retrying against the broken SSH backend indefinitely.

```
🐍 exec      # Open the launch brief to read it  0.0s [[TOOL_ERROR] Tool execution failed: ValueErro...]
```

`--ignore-user-config` reliably routes around it (confirmed live: the identical dispatch shape then used `read_file` with no error at all), but it also discards the account's configured `model.provider: copilot` default - confirmed live the hard way, by omitting `--provider` on the first retry and getting a DIFFERENT failure (`--ignore-user-config` fell through to a `bedrock` provider default, and `gpt-4o` is not a valid bedrock model id):

```
📝 Error: An error occurred (ValidationException) when calling the ConverseStream operation: The provided model identifier is invalid.
```

Adding `--provider copilot` alongside `--ignore-user-config` resolved that too.

**This is a real open question for the captain, not something the adapter should decide silently**: `bin/fm-spawn.sh`'s hermes launch template deliberately does NOT force `--ignore-user-config` (see its own comment).
Before a real crewmate is dispatched against this account, the captain needs to either fix `terminal.backend` to `local` in `~/.hermes/config.yaml`, or explicitly accept a per-dispatch `--ignore-user-config --provider copilot` override (which discards every other real setting in that file, not just the terminal backend).

## Interrupt: no safe key exists - reproduced live twice, independently

This is the single most safety-relevant finding, and it is why hermes carries NO entry in any `bin/fm-control-lib.sh` table.

**Ctrl+C** (despite the busy footer's own `Ctrl+C cancel` text) exits the whole session:

```
$ (busy on a real `sleep 30` terminal-tool call, footer showing "Ctrl+C cancel")
$ tmux send-keys C-c
$ tmux capture-pane -p | tail -3
Initializing agent...
Goodbye! ⚕
$ tmux list-panes -F "#{pane_current_command}"
zsh
```

**Escape** - the key every OTHER verified adapter interrupts with - is a no-op that does NOT cancel a running tool call, confirmed live twice independently (once in an isolated raw lab pane, once against a real `bin/fm-spawn.sh`-dispatched task):

```
$ (busy on a real `sleep 30` terminal-tool call)
$ tmux send-keys Escape
$ tmux capture-pane -p | tail -6
Initializing agent...
 ⚕ gpt-4o │ ctx -- │ [░░░░░░░░░░] -- │ 16s │ ⏲ 0s
⚕ ❯ msg=interrupt · /queue · /bg · /steer · Ctrl+C cancel
$ # ... 20s later, still running, tool call completes normally at its full duration:
    ┊ 💻 $         sleep 30 && echo DONE_SLEEP_TEST  30.5s
```

The only verified-safe redirect is typing new text and pressing Enter while busy, confirmed live twice (once mid-tool-call, once against a genuinely stuck API-retry loop on the real dispatched task):

```
$ tmux send-keys -l "STOP"; tmux send-keys Enter
$ tmux capture-pane -p | tail -6
⚡ New message detected, interrupting...
⚡ Sending after interrupt: 'STOP'
● STOP
```

```
# against a real fm-spawn.sh dispatch stuck retrying an API error:
$ tmux send-keys -l 'Reply now with exactly PONG_HERMES_VERIFY and nothing else.'; tmux send-keys Enter
$ tmux capture-pane -p | tail -6
 ─  ⚕ Hermes  ─────
     Operation interrupted: retrying API call after error (retry 1/3).
     [Interrupted - processing new message]
```

Both sessions survived and processed the interrupt-and-redirect cleanly; neither wedged.
This is a message-submission mechanic, not a key, so `bin/fm-control-lib.sh`'s `fm_control_interrupt_key`/`send_interrupt_keys` contract - which only knows how to deliver a named key the recorded number of times - has no shape for it.
`do_exit` in `bin/fm-control.sh` unconditionally interrupts a busy agent before exiting, so wiring hermes into `fm_control_harness_supported` without a real text-submission interrupt mechanic would let that path attempt to deliver a key that either does nothing (Escape) or destroys the session (Ctrl+C).
`hermes` is deliberately absent from `fm_control_harness_supported`, `fm_control_interrupt_key`, `fm_control_exit_command`, and every other table in `bin/fm-control-lib.sh` as a result: `bin/fm-control.sh <id> interrupt|exit|relaunch` refuses a hermes task with the existing, honest `has no verified control mechanics` message rather than guessing.
`bin/fm-teardown.sh` is unaffected - it kills the endpoint's process tree directly (`fm_backend_kill`), never through `fm-control.sh`'s verb table, so ordinary teardown works normally for a hermes task.

**Exit**: `/exit` cleanly returns to the shell prompt while idle (confirmed live, twice: `Goodbye! ⚕` printed, pane's foreground process becomes `zsh`).
Typing `/exit` while BUSY does NOT reliably exit: on the real dispatched task, it was submitted while the agent was mid-retry and appears to have been swallowed into the busy-redirect input path rather than executed as a command (the pane state was unchanged afterward).
Only send `/exit` to a verifiably idle hermes pane.

## Busy state: the `msg=interrupt` footer fallback

Live, submitting a real terminal-tool call rendered the busy line and footer:

```
⚕ ❯ msg=interrupt · /queue · /bg · /steer · Ctrl+C cancel
```

vs. idle's bare `❯` with no trailing hint line.
`fm_busy_hermes_tail_busy` (`bin/fm-busy-lib.sh`) matches the `msg=interrupt` token; `fm_busy_classify` was confirmed live-and-portably to read it as `busy hermes-regex`, and an idle footer with no hint line as `unknown hermes-regex` (best-effort, like rovo - absence of the marker in a captured tail is "can't tell," never definitive idle, since a long turn can scroll it out of the capture window).
This was also confirmed through the real production path: `bin/fm-crew-state.sh <id>` against a live `bin/fm-spawn.sh`-dispatched task reported `state: working · source: pane · harness busy (hermes-regex)` while the agent was genuinely working.

## Worktree confinement: none, confirmed live via the real dispatch

No grant mechanism exists or is needed (the opposite of rovo) - the live dispatch's crewmate read its brief and would have appended its status line with zero extra flags, exactly as the prior scout report's isolated `hermes chat -q` tests found.

## Effort and model

No effort/reasoning-level concept exists anywhere in the CLI; `bin/fm-spawn.sh`'s `effort_flag_for_harness` has no `hermes` case, so a requested effort is recorded in task metadata but never reaches the launch command (the kimi record-and-omit contract) - confirmed by `tests/fm-hermes-harness.test.sh`'s `test_hermes_effort_is_never_passed`.
`-m <model>` is hermes's own flag name (not the generic `--model` every other adapter uses); `bin/fm-spawn.sh`'s `model_flag_for_harness` carries a dedicated `hermes)` case for it.
The account's configured default model (`gpt-5.3-codex`) is unavailable for this Copilot integrator; `gpt-4o` and `gpt-4.1` were confirmed working verbatim throughout this task's live testing.
`claude-sonnet-5`, present in the account's own returned model catalog, still failed with a client-side `model_not_supported` error when passed as a bare `-m claude-sonnet-5` - not re-solved here per this task's design-decision scope (only resolve if it blocks live verification; it did not, since `gpt-4o` worked), recorded as a known gap.

## quota-axi provider mapping: not established

Matching rovo: no `hermes` entry exists in `bin/fm-quota-choose.sh`'s `provider_for_harness`, and none should be invented - this account alone was observed routing to multiple distinct model families (OpenAI and Claude ids) through one pooled GitHub Copilot credential, so `hermes` stays absent from that mapping and fails closed (`unknown harness: hermes`) rather than being silently misjudged.

## Transport decision: tmux/`--cli`, not `/api/ws`

Per this task's brief, the `/api/ws` JSON-RPC transport (see `data/hermes-serve-verify/report.md` above) was NOT pursued: it requires either resolving the captain's VPS ticket-auth flow (out of scope, a real design decision) or deciding whether Firstmate should launch its own scratch `hermes serve` process per crewmate versus dispatching against the captain's existing persistent instance (also a real design decision, not one this task should presuppose).
The tmux/`--cli` adapter landed here works today with zero additional Hermes-side setup beyond the terminal-backend prerequisite above, matches every other verified harness's launch-then-send shape, and is the one the brief designated as the initial adapter.
A `hermes serve`/`/api/ws` adapter remains a materially promising, larger follow-up ship task, not built speculatively here.

## Refreshing this record

Run the portable suite after any hermes upgrade, because the rendered busy/footer text, the delivery bullet glyph, and the process/argv shape are all vendor-controlled surfaces:

```
bin/fm-test-run.sh tests/fm-hermes-harness.test.sh
```

`tests/fm-hermes-signals-live-e2e.test.sh` (`FM_HERMES_SIGNALS_LIVE=1`, opt-in, drives the real binary over a raw PTY) exists as the required live-harness-optin companion, structured like `tests/fm-rovo-signals-live-e2e.test.sh`.
It was written and syntax-verified in this task, and its readiness-banner and busy-footer assertions were confirmed passing live, but its full run was NOT confirmed clean end to end today: the account's pooled GitHub Copilot credential was heavily used across this task's own testing and both prior scouts, and a single turn was observed taking several minutes to produce a final response even after its 20-second tool call had long since completed - consistent with the rate-limiting this task independently hit and documented above (`HTTP 429: ... exceeded your rate limit`), not a defect in the guard's logic.
Re-run it once the account's rate limit has cleared, and treat a clean pass as confirming this record; a failure that reproduces the exact symptom above (the tool call completing but the turn's final response taking minutes) is the account's shared quota, not this adapter.

## VPS `/api/ws` gated-mode auth: the ticket-mint flow, resolved by source but not yet live-dispatched

`data/hermes-serve-verify/report.md` (2026-09-13) found that the captain's real VPS (`http://<your-vps-host>:9119`, Hermes Agent v0.21.2) puts `/api/ws` in gated mode (`_ws_auth_reason()` in `hermes_cli/web_server.py`) and left the ticket-minting flow uninventoried.
This section resolves the flow itself, by reading the actual v0.21.2 upstream source (via the local install's already-fetched-but-not-checked-out git history at `~/.hermes/hermes-agent`, commit `ee4452991d17534aa561f31ee55596d082aa94e7`, since the local checkout is v0.16.0 and predates it) and confirming the two public, unauthenticated probe endpoints live against the real VPS.
No write or state-changing call was made against the VPS; both requests below are plain `GET`s.

```
$ curl -sS http://<your-vps-host>:9119/api/status
{"version":"0.21.2", ..., "auth_required":true,"auth_providers":["basic"],"auth_flows":["cookie","native_pkce"], ...}
$ curl -sS http://<your-vps-host>:9119/api/auth/providers
{"providers":[{"name":"basic","display_name":"Username & Password","supports_password":true}]}
```

The resolved flow (`hermes_cli/dashboard_auth/routes.py`, `hermes_cli/dashboard_auth/ws_tickets.py`, `web/src/lib/api.ts` at the commit above), all plain HTTP/JSON, no browser required:

1. `POST /auth/password-login` with JSON body `{"provider": "basic", "username": "<...>", "password": "<...>", "next": ""}`.
   On success this sets `hermes_session_at` (access) and a refresh cookie and returns `{"ok": true, "next": "/"}`; on failure it is deliberately generic (401 bad credentials, 404 unknown provider, 429 rate-limited after 10 attempts/60s per client IP - `hermes_cli/dashboard_auth/routes.py`'s `_PW_RATE_MAX_ATTEMPTS`/`_PW_RATE_WINDOW_SEC`).
2. `POST /api/auth/ws-ticket` with those cookies attached (`credentials: include`, no body) mints a single-use, 30-second-TTL ticket: `{"ticket": "<...>", "ttl_seconds": 30}` (`ws_tickets.py`'s `mint_ticket`, in-memory, `secrets.token_urlsafe(32)`).
3. Connect `/api/ws?ticket=<ticket>` within that 30-second window; `consume_ticket` pops it from the in-memory store on first use, so a reused or expired ticket is rejected and a fresh one must be minted per connection attempt.

This is a real, scriptable, non-browser credential exchange - no PKCE round trip, no `native_pkce` flow needed, since the VPS's only registered provider (`basic`) supports direct password login.
**What remains unresolved is not the mechanism but the credential**: exercising step 1 needs the captain's actual VPS login username and password for the `basic` provider, which is not present in any file this task can read (checked `data/captain.md`, `data/learnings.md`, `.env`, and `~/.hermes/config.yaml`) and must not be guessed or fabricated.
Until that credential is supplied, this flow is verified by source and by the two public read-only endpoints above, but NOT yet exercised end to end against the real VPS - see `state/hermes-vps-gateway.status` for the open decision this blocks.

## `bin/fm-hermes-ws.py`/`.sh`: a standalone JSON-RPC-over-WebSocket dispatch client, offline-verified

Per the captain's decision on `state/hermes-vps-gateway.status`, this landed first as a standalone dispatch primitive, deliberately NOT wired into `bin/fm-spawn.sh`, `bin/fm-control.sh`, `bin/fm-crew-state.sh`, or `bin/fm-busy-lib.sh` at the time, since those are entirely pane/text-capture-shaped (`fm_backend_capture`, `fm_backend_composer_state`, `fm_backend_send_key`, ...) and a `/api/ws` session has no pane at all.
The fleet-dispatch follow-up landed once this primitive was proven live: see "hermes-vps: fleet-dispatch wiring" below for `harness=hermes-vps`, the bridge that gives a `/api/ws` session an ordinary pane, and its own live evidence.
This client and wrapper remain the standalone dispatch primitive underneath that harness, and stay usable directly for ad hoc probing exactly as documented here.

The client (`bin/fm-hermes-ws.py`, stdlib-only Python - no third-party dependency, matching `bin/fm-mail.py`'s existing no-dependency stance rather than the real Hermes reference client's `pip install websockets`) implements, from scratch: the RFC 6455 client handshake and masked text-frame framing, the gated-mode `password-login -> cookie -> ws-ticket -> ?ticket=` flow above (loopback/`--insecure` mode uses a static `?token=` instead, via `FM_HERMES_WS_TOKEN`), and id-matched JSON-RPC request/response over the connection, draining the server's `gateway.ready` notification on connect.
`bin/fm-hermes-ws.sh` is a thin wrapper resolving `FM_HERMES_WS_*` configuration from the environment, filling gaps from `$FM_HOME/.env` (env wins), matching `fm-mail.sh`'s convention - the captain's VPS login credentials belong in `$FM_HOME/.env` as `FM_HERMES_WS_USER`/`FM_HERMES_WS_PASS`, the same already-gitignored, already-documented file that holds mail-plane credentials, never in a task brief, status line, or report.
It exposes every primitive the captain's spec named: `create`, `submit`, `status`, `history`, `steer`, `interrupt`, `close`, plus a `dispatch` convenience (create + submit + wait for `message.complete`/`error` + `history`) for smoke-testing and live verification.
`dispatch` always sends the server a `session.close` RPC before returning, on every exit path (success, a turn's `error` event, or a client-side timeout) - not just the success path - so a failed or timed-out dispatch never leaks the server-side session; the `session.close` RPC itself is best-effort (its own failure is swallowed, since the turn's own outcome is what the caller needs reported).

### Wire-protocol grounding

The real Hermes source (v0.21.2, commit `ee4452991d17534aa561f31ee55596d082aa94e7` at `~/.hermes/hermes-agent`, the same git history used for the auth-ticket flow above) was read directly rather than inferred from the earlier scout report's paraphrased transcript:

- `tui_gateway/ws.py`'s `handle_ws` reuses `tui_gateway.server.dispatch` verbatim and reads exactly one JSON-RPC message per `ws.receive_text()` call (confirmed by reading the function body, not just its docstring), so one WebSocket text frame carries one JSON-RPC message on this transport.
- `handle_ws` sends `{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready",...}}` immediately after accepting the connection - a client must drain this before its first request-scoped read, which `HermesWsSession.__init__` does.
- `scripts/iso-certify.py`'s `WSClient` - a real first-party Hermes client for this exact endpoint, not a test double - is `HermesWsSession`'s direct structural model: drain `gateway.ready`, then id-matched request/response, and its `drive_heavy_turn` treats a submitted turn as done only on a `message.complete` event (or failed on `error`, with the message at `params.payload.message`) after a `message.start`, never on an earlier or unrelated event - `cmd_dispatch` mirrors that exact predicate.

### Offline verification (no Hermes install, no VPS)

`tests/fixtures/fm-hermes-ws-stub-server.py` is a from-scratch, independently-written HTTP + WebSocket double for `/auth/password-login`, `/api/auth/ws-ticket`, and `/api/ws` (its own framing code was written independently of the client's, so a shared bug would not hide behind a passing test).
`tests/fm-hermes-ws.test.sh` drives every subcommand through `bin/fm-hermes-ws.sh` against it over a real loopback socket:

```
$ bash tests/fm-hermes-ws.test.sh
ok - token mode: every RPC primitive round-trips over a real WebSocket
ok - gated mode: password-login -> cookie -> ws-ticket -> /api/ws?ticket= round-trips for real
ok - gated mode: bad credentials fail closed with no ticket minted and no leaked secret
ok - dispatch: waits past message.start/message.delta and completes only on message.complete
ok - dispatch: a turn's error event fails the call and surfaces its message
ok - dispatch: a turn error still sends session.close to the server, not just a local socket close
ok - dispatch: a timed-out turn still sends session.close to the server, not just a local socket close
ok - config: a missing FM_HERMES_WS_BASE_URL fails closed by name, no guessed connection
ok - config: fm-hermes-ws.sh fills missing env from $FM_HOME/.env, env still wins over it
```

Run 2026-09-14 (macOS arm64, Python 3.13.12).
This proves the HTTP auth calls, the RFC 6455 handshake and framing, JSON-RPC id matching, event-notification handling, and the `dispatch` completion predicate all work correctly against a real socket speaking the documented wire protocol.
The last two `dispatch` cases pin the fix on this section's own claim above: the stub's optional RPC log (`tests/fixtures/fm-hermes-ws-stub-server.py`) proves a real `session.close` RPC reaches the server on both the turn-error and client-timeout exit paths, not just success - a wire-level check, since the client's own exit code proves nothing about what it actually sent.

### Live verification against the real VPS

Run 2026-09-14, `FM_HERMES_WS_BASE_URL=http://<your-vps-host>:9119`, credentials from `$FM_HOME/.env`, Hermes Agent v0.21.2 (`gateway_mode: multiplex`, model `claude-opus-5 (anthropic)`).
`bin/fm-hermes-ws.py` defaults `Origin` to the base URL's own origin; the real gated connect succeeded on that default with no override needed, so `FM_HERMES_WS_ORIGIN` stays available but unexercised.

Every primitive round-tripped for real:

```
$ bin/fm-hermes-ws.sh dispatch /tmp/fm-hermes-ws-live-verify \
    "Use your terminal tool to run: pwd && cat marker.txt. Then reply with exactly the terminal output and nothing else." 120
{"count": 4, "messages": [
  {"role": "user", "text": "Use your terminal tool to run: pwd && cat marker.txt. ..."},
  {"role": "tool", "name": "terminal", "args": {"command": "pwd && cat marker.txt"}},
  {"role": "assistant", "text": "/\ncat: marker.txt: No such file or directory"}]}
# real tool call, real streamed completion, session created/submitted/read/closed
# over one dispatch call, end to end, in ~4s.

$ bin/fm-hermes-ws.sh status "$SID"
{"output": "Hermes TUI Status\n\n...\nAgent Running: No"}
# and, mid-turn, on a real `sleep 20` submit:
{"output": "...\nTitle: Run sleep 20 then echo DONE_SLEEP\n...\nAgent Running: Yes"}

$ bin/fm-hermes-ws.sh steer "$SID" "Actually, stop and just reply with the word ACK."
{"status": "queued", "text": "Actually, stop and just reply with the word ACK."}

$ bin/fm-hermes-ws.sh interrupt "$SID"
{"status": "interrupted"}

$ bin/fm-hermes-ws.sh close "$SID"
{"closed": true}
```

`session.status`'s literal `Agent Running: Yes`/`Agent Running: No` line and `session.steer`/`session.interrupt`'s real, structural (non-key) responses are exactly what `data/hermes-serve-verify/report.md` predicted from a local scratch instance - confirmed here against the captain's real deployment instead.
This is the safety-relevant fact this whole transport exists to deliver: unlike the pane-based `hermes --cli` adapter (`../../../.agents/skills/harness-adapters/references/harness/hermes.md`'s "Interrupt: no safe key exists" - Ctrl+C kills the whole session, Escape is a no-op), `session.interrupt` here is a real RPC method with a real, distinct, non-destructive result.

**One real, live-verified finding that changes a claim in the earlier scout report**: `session.create`'s `cwd` param was NOT honored on this VPS deployment.
`session.create({"cwd": "/tmp/fm-hermes-ws-live-verify"})` returned `"info": {"cwd": "/", ...}`, and the dispatched turn's own `terminal` tool call confirmed it (`pwd` printed `/`, and `cat marker.txt` - a file that genuinely exists at the requested cwd - failed `No such file or directory`).
`data/hermes-serve-verify/report.md`'s local scratch-instance test found solid `cwd` pinning for the `terminal` tool specifically; this VPS, on a materially newer version (v0.21.2 vs. that test's v0.16.0) and in `multiplex` gateway mode, does not reproduce that on the same tool.
Not re-diagnosed further here (out of this task's scope), but load-bearing for any future fleet-dispatch wiring: **do not assume `cwd` pins a crewmate's working directory on this transport** without re-confirming it on the specific deployment/version in use; a follow-up wiring task needs its own answer for worktree confinement here; the file-tool "no confinement at all" finding for the pane-based adapter (same skill reference doc) is a separate, already-documented fact and is not contradicted by this.

Re-run `bash tests/fm-hermes-ws.test.sh` after any change to the client or the stub; re-run a live `dispatch` after any Hermes upgrade on either the client's assumptions or the VPS's version, since the wire protocol, `cwd` handling, and the rendered `session.status` text are all vendor-controlled surfaces.

## hermes-vps: fleet-dispatch wiring, live-verified end to end

Verified 2026-09-14 against the same real VPS (Hermes Agent v0.21.2, `gateway_mode: multiplex`).
This section is the evidence record for `harness=hermes-vps`; `../../.agents/skills/harness-adapters/references/harness/hermes-vps.md` owns the operating facts.

### Design decision: a harness, not a backend

The prior task's brief left open whether the VPS transport should be a new `--backend` value or a harness variant.
This task chose **a new harness** (`hermes-vps`), selected exactly like any other adapter (`bin/fm-spawn.sh --harness hermes-vps`), running on whichever ordinary session-provider backend the task already uses (tmux, verified below; herdr, verified live in this task's required isolated lab session - see "Herdr pane visibility").
Reasoning: firstmate's `--backend` axis (tmux/herdr/zellij/orca/cmux) answers "which session-provider hosts this task's local pane," and a VPS-bridged Hermes session still needs an ordinary LOCAL pane to be visible in a Herdr workspace exactly as this task's brief required - only the pane's own foreground *process* differs (a bridge script instead of a real agent CLI), which is precisely what the harness axis already exists to select.
Treating it as a backend would have meant reimplementing every pane primitive (`fm_backend_capture`, `_send_key`, `_send_text_submit`, ...) for a target that is not a pane at all, when the actual local presentation IS an ordinary pane.

### The bridge: `bin/fm-hermes-vps-bridge.py`/`.sh`

A new local process, tracked in this repo, that a normal `hermes-vps` task pane runs instead of the real `hermes` binary.
It opens one `bin/fm-hermes-ws.py` `HermesWsSession`, creates a session, and single-threads a `select()` loop over stdin and the WS socket for the rest of the task's life: server-pushed events (`message.delta`/`message.complete`/`tool.start`/`tool.complete`/`error`, read directly from the installed Hermes source's `tui_gateway/server.py` `_emit()` payload shapes) render into the pane; typed lines forward to the session (`prompt.submit` while idle, `session.steer` while busy).
`bin/fm-hermes-ws-env-lib.sh` factors the `FM_HERMES_WS_*`/`.env` resolution out of `bin/fm-hermes-ws.sh` so the bridge shares it verbatim rather than duplicating it - re-run `bash tests/fm-hermes-ws.test.sh` after touching that shared file, since it is the same credential path the standalone client depends on.

Two real, load-bearing bugs were found and fixed only by driving the bridge against the real VPS (a stub server could not have caught either, since both depend on genuine network timing):

1. **Same-segment event starvation.** The server answers `prompt.submit` with its RPC result immediately followed by `message.start`/`message.delta`/`message.complete` in rapid succession, often arriving in the client's read buffer together. `select()` on the raw socket only reports fresh OS-level bytes, not messages `HermesWsSession` already parsed into its own internal buffer, so relying on `select()` alone left later events in that burst unread until unrelated later traffic happened to arrive. Fixed by draining every already-buffered event in a tight non-blocking loop after each `select()`-triggered read.
2. **The gateway drops the connection after a successful interrupt.** Live-reproduced twice, independently, with and without an in-flight tool call: `session.interrupt` returns its own successful RPC result, the turn correctly reports `message.complete` with `status: "interrupted"`, and then the server closes the WebSocket outright (`the gateway closed the WebSocket connection`). The session itself survives - a fresh connection can immediately query `session.status`/`session.steer`/etc. against the same `session_id` - so this is a connection-lifecycle quirk, not a session-lifecycle one. The bridge now reconnects transparently (`Bridge.reconnect()`, bounded retries) on any dropped connection, including this one, rather than exiting and silently killing an otherwise-healthy crewmate task. Confirmed live: interrupt a long text generation, watch the connection drop and the bridge print `[reconnected]`, then submit a fresh prompt on the SAME session and get a normal reply, then `/exit` and confirm the session closes cleanly.

### Brief delivery: content, not a pointer

`../../.agents/skills/harness-adapters/references/harness/hermes-vps.md`'s "Brief delivery" section owns the mechanism, including the missing-brief-path invariant added after review.
Live-verified: `bin/fm-spawn.sh hvfinal <project> --scout --harness hermes-vps` against a real VPS session correctly delivered a brief whose `## Captain's intent` instructed `pwd && echo HERMES_VPS_LIVE_VERIFY_MARKER`; the VPS agent ran it via its own `terminal` tool and replied with `/` and `HERMES_VPS_LIVE_VERIFY_MARKER` exactly.
The missing-brief-path fix described there is pinned by a portable regression in `tests/fm-hermes-vps-bridge.test.sh` (`test_bridge_missing_brief_never_reports_false_delivery`) rather than by further live-VPS evidence, since it is a local-process behavior that does not depend on the real gateway.

### Fleet wiring landed

- `bin/fm-spawn.sh`: `hermes-vps` launch template (`env -u ... bin/fm-hermes-vps-bridge.sh --cwd <worktree>`), its own readiness/delivery gates (`hermes_vps_wait_for_ready`/`_wait_for_delivery`, keyed on the bridge's own printed markers rather than vendor UI text), and `hermes_vps_record_session_id` folding the VPS `session_id` into `state/<id>.meta` as `hermes_vps_session_id=` once delivery is confirmed - the field a captain or firstmate reads to tell at a glance that a task is VPS-bridged rather than pane-based `hermes`. Record-and-omit for model/effort, matching bare hermes (no such RPC param exists).
- `bin/fm-busy-lib.sh`: `fm_busy_hermes_vps_agent_running` pulls `session.status`'s literal `Agent Running: Yes`/`Agent Running: No` line over a fresh RPC each time it is asked - live-verified busy during a real `sleep 60` tool call and idle once it completed.
- `bin/fm-control-lib.sh`/`bin/fm-control.sh`: `hermes-vps` is control-plane supported (unlike bare hermes). `fm_control_interrupt_via_text` names the literal line `/interrupt`, delivered through the ordinary text-submit pane mechanic (this transport has no composer for a named key to act on); the bridge recognizes it locally and calls the real `session.interrupt` RPC. `/exit` reuses the existing text-submit exit path unchanged - the bridge recognizes it locally too, closes the VPS session, and exits.
- `bin/fm-agent-process-lib.sh`/`bin/fm-hermes-lib.sh`: `fm_hermes_vps_bridge_path_is_bridge`/`_args_are_bridge`/`_pid_is_bridge` give the bridge's python-interpreter-argv[1] shape its own structural identity (distinct from bare hermes's), wired into `fm_agent_process_classify`.
- `bin/backends/tmux.sh`: `fm_backend_tmux_agent_state` needed a NEW pid/args-based check for the bridge, mirroring the existing Gemini one - its foreground-comm/argv0 loops alone never carry a python-interpreter-shaped identity. **This exposed a pre-existing, separate gap for bare hermes**: `fm_backend_tmux_agent_state` has no hermes pid/args check either, so a bare-hermes pane would also read `ambiguous` there today - untested and inert only because bare hermes is deliberately absent from `fm_control_harness_supported` and never reaches this function through `fm-control.sh`. Flagged here rather than silently fixed, since it is a bare-hermes gap outside this task's scope.

### Live fleet-dispatch runs (dated evidence)

Driven through the real, unmodified `bin/fm-spawn.sh`/`bin/fm-control.sh`/`bin/fm-crew-state.sh` against an isolated scratch firstmate home and an isolated tmux server (never the shared production fleet or its real `data/`/`state/`), with `FM_HERMES_WS_*` credentials read from the real running firstmate home's `.env` exactly as `bin/fm-hermes-ws.py` documents - never copied into the scratch home or any other file.

```
$ bin/fm-spawn.sh hvfinal <project> --scout --harness hermes-vps
spawned hvfinal harness=hermes-vps kind=scout window=firstmate:fm-hvfinal worktree=.../2/firstmate
# state/hvfinal.meta: harness=hermes-vps, hermes_vps_session_id=eae406ed
# pane: readiness banner -> brief delivered -> real terminal tool call -> "/" and
# HERMES_VPS_LIVE_VERIFY_MARKER -> [turn complete]

$ bin/fm-crew-state.sh hvlast    # mid sleep-60 tool call
state: working · source: pane · harness busy (hermes-vps-status)

$ bin/fm-control.sh hvlast interrupt
interrupt-delivered hvlast harness=hermes-vps backend=tmux verified=agent-alive cancel=unconfirmed
# pane: /interrupt -> [interrupted] -> [tool complete] terminal -> [turn interrupted]

$ bin/fm-control.sh hvlast exit
stopped hvlast harness=hermes-vps backend=tmux endpoint=firstmate:fm-hvlast worktree=.../2/firstmate
# pane foreground command back to zsh; bridge process gone

$ bin/fm-hermes-ws.sh status 14556083   # the exited task's own VPS session
fm-hermes-ws.py: session.status: {'code': 4001, 'message': 'session not found'}
# confirmed: no leaked server-side session after fm-control.sh exit
```

Every VPS session this task created (via the bridge directly, via `fm-spawn.sh`, and via ad hoc `fm-hermes-ws.sh` probes) was independently confirmed closed or already-gone by the end of the task - `session.close`/`session.interrupt`/`session.status` against a stale id consistently answered `session not found` rather than ever leaving a live orphan.
That guarantee did not originally extend to a post-readiness spawn failure, since `hermes_vps_spawn_fail`'s pane teardown delivers SIGHUP rather than SIGTERM/SIGINT and the bridge did not yet trap it; the bridge now traps SIGHUP identically (`../../.agents/skills/harness-adapters/references/harness/hermes-vps.md`'s "Exit command" row owns the current fact), pinned by `tests/fm-hermes-vps-bridge.test.sh`'s `test_bridge_closes_session_on_sighup`.

### Herdr pane visibility

Confirmed live, inside this task's required isolated Herdr lab session (`bin/fm-herdr-lab.sh`), that a `--backend herdr --harness hermes-vps` spawn places the bridge in an ordinary Herdr-managed pane, indistinguishable in the workspace from any other crewmate pane: the same readiness banner, brief delivery, streamed conversation, and `fm-control.sh interrupt`/`exit` behavior as the tmux run above, since `bin/backends/herdr.sh`'s own agent-process classifier already calls the shared `fm_agent_process_classify` (no herdr-specific gap, unlike tmux's - see above).

### Known limitation: no local file or repo access

**`session.create`'s `cwd` param is still not honored** on this VPS (same finding as above, re-confirmed here): the VPS agent's own tools reach only the VPS's own filesystem.
Live-verified concretely during this task's own dispatch gate test: given a brief referencing macOS paths under `/private/tmp/...` and `/Users/coryforsythe/...`, the VPS agent (a real Linux host, `6.8.0-139-generic`, home `/home/coryforsythe`) correctly reported those paths do not exist there and that `/` is not writable, and wrote its own report to the only location it could reach.
**A `hermes-vps` crewmate cannot read or edit a task's local git worktree, run `git`, or drive the no-mistakes pipeline** - it is proven useful for VPS-local work and for this fleet-visibility wiring itself, not yet as a substitute for a real local crewmate on project work.
Before the fix below, that same unreachability extended to the crewmate's OWN status/report/steering paths, which is a materially worse gap: a broken dispatch produced no signal in Firstmate at all, not even a `blocked:` line - see the next section.

## hermes-vps: local status/report/steering protocol, live-verified end to end

Verified 2026-09-14, same real VPS as above, following a live-verification finding (`data/hermes-vps-live-verify/report.md`) that a `hermes-vps` crewmate had no path back to this Mac's filesystem at all: it could not append `state/<id>.status`, write `data/<id>/report.md`, or read `state/<id>.inbox/`, and could not even report `blocked:` about hitting exactly that wall.
A second, earlier crewmate had hit the identical wall roughly 11 hours prior (a leftover `~/hvcheck-report.md` on the VPS) and it went unfixed and unescalated - the failure mode silenced its own alarm.

### Design: a transport concern, not a filesystem one

The bridge (`bin/fm-hermes-vps-bridge.py`) runs locally and always has real access to this machine's filesystem, so it now owns all three pieces on the remote agent's behalf instead of asking the remote agent to perform filesystem operations it structurally cannot:

- **Status**: the remote agent emits a line of the exact shape `FIRSTMATE-STATUS: <state>[ [key=..]]: <note>` in the plain text of its own chat reply - the same state vocabulary (`fm-classify-lib.sh`) every other harness's brief already uses via a literal `echo ... >>`. The bridge scans each completed turn's text for that sentinel, validates the state word itself against the fixed vocabulary, and appends only the validated `<state>: <note>` line to the real local status file. A line that carries the sentinel but fails validation is never written verbatim: the remote agent cannot make the bridge write arbitrary text merely by emitting it in chat.
- **Report**: the remote agent wraps its findings between two bare marker lines, `FIRSTMATE-REPORT-BEGIN` and `FIRSTMATE-REPORT-END`, in one reply. The bridge writes exactly the text between them to the real local report file.
- **Steering inbox**: the bridge itself polls `state/<id>.inbox/*.msg` (`fm-task-inbox-lib.sh`'s own record format) once per loop iteration, delivers each body through the same `_forward()` path pane-typed input uses, and moves the record to `handled/` only after a confirmed delivery - the same local read-act-acknowledge loop every other harness's crewmate performs on itself, performed here on the remote agent's behalf. The doorbell line every other harness's pane receives for a steering message (`fm_task_inbox_doorbell_line`, `": Firstmate instruction waiting: ..."`) names a local path the remote agent can never reach, so the bridge recognizes and swallows that exact line locally instead of forwarding an instruction the model cannot act on.
- **Failure signal**: every protocol failure path (a malformed status line, a local write that fails, an unreadable inbox record) calls the bridge's own `write_status_line()` with a bridge-authored diagnostic - never text the remote agent supplied - falling back to a plain pane-visible print only if that write itself fails. `bin/fm-brief.sh --harness hermes-vps` scaffolds the worker-side half of this contract (status/inbox/report sections and, for scout, the report-completion instructions), and routes the captain-hold-lifecycle completion gate to firstmate itself rather than the worker, since the worker cannot read that skill file or run `bin/fm-captain-hold.sh` either.

### Two real bugs, found only by driving real turns through the real VPS

Neither is reachable from a stub that never streams genuinely fragmented, multi-segment turns:

1. **`select()`/buffered `readline()` mismatch on stdin.** A single underlying `read()` inside Python's `TextIOWrapper` can pull MULTIPLE newline-terminated lines from the pipe into its own internal buffer whenever more than one line is already queued (exactly what a steering doorbell immediately followed by real content produces, or two rapid steers). `readline()` then returns the first line while stranding the second INSIDE that buffer, invisible to `select()`, which only observes the OS-level fd - the bridge would wedge for up to `EVENT_WAIT_TIMEOUT` (30s) waiting on a `select()` that will never again see the already-buffered second line. Fixed by reading stdin with raw `os.read()` and splitting on `\n` ourselves, so nothing is ever buffered anywhere `select()` cannot see. Reproduced by sending two lines back-to-back with nothing read in between; pinned by `tests/fm-hermes-vps-bridge.test.sh`'s `test_bridge_suppresses_inbox_doorbell_line` (which depends on exactly this fix to pass reliably) and the general status/report tests.
2. **`message.complete`'s own `text` field is not the turn's full cumulative text.** Live-reproduced against the real VPS (`data/hv-protocol-verify/report.md`): a turn that emits text, then a tool call, then more text fires exactly ONE `message.start`/`message.complete` pair for the WHOLE turn, and `message.complete`'s `text` field holds ONLY the last text segment - an opening `FIRSTMATE-STATUS: working: ...` line emitted before the agent reached for a tool was silently absent from it, even though it streamed correctly through `message.delta` and rendered in the pane. Confirmed directly: a scripted turn instructed to say `FIRSTMATE-STATUS: working: test1`, run a shell command, then say `FIRSTMATE-STATUS: done: test1 complete` produced exactly one `message.complete` event whose `text` was `'FIRSTMATE-STATUS: done: test1 complete'` - the `working:` segment never appeared in the completion payload at all, only in its own earlier delta. Fixed by accumulating every `message.delta` chunk into a per-turn buffer (reset on `message.start`) and scanning that accumulated buffer instead of `message.complete`'s own field. Pinned by `tests/fm-hermes-vps-bridge.test.sh`'s `test_bridge_recovers_status_line_split_by_tool_call`, which uses a dedicated `STUB_SPLIT_ECHO:` stub trigger to reproduce the exact split.

### Live fleet-dispatch run (dated evidence)

Driven through the real, unmodified `bin/fm-spawn.sh` against the real production firstmate home and the real VPS (a genuine end-to-end proof, not a scratch home, since the whole point was proving the real fleet's status/report files receive real content):

```
$ tasks-axi add hv-protocol-verify "Live-verify hermes-vps bridge status/report/inbox protocol" --kind scout --repo firstmate --start
$ bin/fm-brief.sh hv-protocol-verify firstmate --scout --harness hermes-vps
$ bin/fm-spawn.sh hv-protocol-verify <project> --scout --harness hermes-vps --backend tmux
spawned hv-protocol-verify harness=hermes-vps kind=scout window=firstmate:fm-hv-protocol-verify worktree=.../3/firstmate
```

The brief instructed the crewmate to exercise every protocol element in order: an opening `working:` status, real sandbox identity commands, a deliberate `blocked:` status (proving the exact signal that was silent before this fix), an immediate `working:` recovery, a `FIRSTMATE-REPORT` block, and a closing `done:` status.
Real local file contents after the run:

```
$ cat state/hv-protocol-verify.status
blocked: deliberate test of the blocked: signal path - this is not a real blocker, ignore and continue
working: resuming after deliberate blocked test
done: protocol verified from the crewmate side - all status states and the report block emitted from a Linux sandbox with zero reach to the captain's Mac; inbound steering leg untested and 3 open questions raised
```

The report landed at `data/hv-protocol-verify/report.md` with real sandbox evidence (`hostname` = `ubuntu`, `uname -a` = a Linux 6.8 x86_64 kernel, confirmation that `/Users` does not exist there) and, notably, its own `## Open questions for the captain` section - proof that a crewmate whose report block is read directly by firstmate can still surface a captain call through the report itself, which is exactly the harness-conditional routing `bin/fm-brief.sh` scaffolds for this harness.
The opening `working: starting verification` line is conspicuously ABSENT from the status file above: the crewmate's first reply included a tool call before its next reply, triggering bug 2 above in the wild on the very first live run after the fix - the fix for bug 2 (delta accumulation) was applied and re-verified by direct dispatch (see bug 2's own entry) after this run had already demonstrated the gap.
`bin/fm-control.sh hv-protocol-verify exit` cleanly closed the session afterward, same as the "Known limitation" section's run above.

### Known limitation, updated

Status, report, and steering are now solved.
`session.create`'s `cwd` still is not honored, so a `hermes-vps` crewmate still cannot read or edit a task's local git worktree, run `git`, or drive the no-mistakes pipeline - only VPS-local sandbox work and this fleet-visibility wiring are proven use cases.
Do not dispatch a ship task onto it that needs local repo access; `hermes-vps.md`'s "Known limitation" owns this for future dispatch decisions.

## hermes-vps: typed pane input investigation - one real defect found and fixed, root cause not confirmed

Investigated 2026-09-14 after a captain report: typed a line directly into a live `hermes-vps` pane and pressed Enter, and observed no response and no visible change.

### Hypotheses tested and falsified by direct live reproduction

Against a real, already-running `hermes-vps` bridge pane (`hermes-vps-live-verify-2`, the same pane type and session shape the captain used), every interactive-input path constructible through Herdr's pane API succeeded with a real VPS round trip:

1. **Bulk paste (`herdr pane send-text`) with no trailing Enter, then a separate `herdr pane send-keys Enter`.** Works (this was Firstmate's own earlier partial repro).
2. **Individual per-character key events (`herdr pane send-keys` one letter at a time) ending in a real logical `Enter` key event** - the closest reproduction of physical typing available without a physical keyboard. Works, with a real completed VPS turn (`echo QQQENTERDIVERGENCEQQQ` round-tripped correctly).
3. **A literal embedded carriage return (`\r`, no `\n`) sent as part of one `send-text` payload, with no separate Enter call at all** - the direct test of a `\r`-vs-`\n` line-ending mismatch theory. Works; the VPS agent itself confirmed the text "arrived intact, no mangling, no stray CR artifacts."

These three results directly falsify "the bridge's `select()`/`os.read()`/line-splitting logic" (module docstring's own suspect) as an unqualified root cause: every keystroke-pacing and line-termination shape reachable through Herdr's pane input primitives is handled correctly by the code as shipped.

The "Herdr's own key routing for a composer-less foreground process" theory was also weakened, not strengthened: `bin/backends/herdr.sh`/`docs/herdr-backend.md` confirm every crewmate pane on every harness (composer or not) is spawned with `--no-focus`, so lack of auto-focus is universal, not hermes-vps-specific - and the SAME composer-less `hermes-vps-live-verify-2` pane shows an earlier real captain-typed exchange (`is it going to work?` / `pwd`) that worked, in this same episode. A pane-focus explanation cannot be ruled out (real GUI keyboard/mouse focus was not, and could not be, exercised from this investigation), but it is not the well-evidenced, falsification-surviving explanation the code-level hypotheses were.

### Real defect found by reading the code, not by reproduction: unwrapped socket exceptions can crash the bridge uncaught

`bin/fm-hermes-ws.py`'s `_WSSocket` wrote and read the raw socket directly (`self._sock.sendall(...)`, `self._sock.recv(...)`) in `__init__`, `send_text`, `_send_control`, `_recv_exact`, and `_read_http_response_head`, with no exception translation. A genuine connection failure - dropped VPS connectivity, a laptop sleep/wake, a network roam, anything that raises a raw `OSError` subclass (`ConnectionResetError`, `BrokenPipeError`, `ssl.SSLError`, a bare `socket.timeout`) rather than the module's own `HermesWsError` - propagated straight through `HermesWsSession.rpc()` (no wrapping) into `Bridge._forward()`'s `except HermesWsError` (which does not match a raw `OSError`), through `Bridge.run()`'s main loop (no handler around `handle_input_line()`), and out of `main()` (`except HermesWsError` only) as an **uncaught Python exception** - crashing the whole bridge process with a bare traceback, no `write_status_line()` call, and no `blocked:` signal. This is exactly the silent-failure mode the bridge's own status/report protocol exists to prevent (see "hermes-vps: local status/report/steering protocol" above).

Live-verified with a real dead connection: `bin/fm-hermes-ws.sh create <cwd>` against a refused port crashed with an uncaught `ConnectionRefusedError` traceback before the fix, confirmed by directly reverting the fix and re-running the CLI.

**Fix**: `_WSSocket` now routes every raw socket write through `_send()` and every raw socket read through `_recv()`, both of which catch `OSError` (covers `ConnectionResetError`, `BrokenPipeError`, `ssl.SSLError`, and `socket.timeout`, an `OSError` subclass since Python 3.3) and re-raise as `HermesWsError`; the initial `socket.create_connection`/`ctx.wrap_socket` in `__init__` are wrapped the same way. `recv_text`'s per-iteration `self._sock.settimeout(remaining)` call sits outside the `_send`/`_recv` wrapper pattern (it's neither a write nor a read) and is wrapped inline with its own `try`/`except OSError` for the same reason. Every existing caller (`HermesWsSession.rpc()`, `Bridge._forward()`, `Bridge.reconnect()`, `main()`) already only ever handled `HermesWsError`, so no caller-side change was needed - the fix closes the gap between what those handlers expected and what the raw socket layer could actually raise.

Pinned by `tests/fm-hermes-ws.test.sh`'s `test_dead_connection_fails_closed_not_uncaught`: a refused connection now fails closed through the same `fm-hermes-ws.py: ...` message every other failure mode already used, never an uncaught traceback. Confirmed live that this test fails (reproduces the uncaught traceback) against the pre-fix code and passes against the fix.

### Honest status: root cause not confirmed by reproduction

This is a real, serious, and now-fixed robustness gap, and it is consistent with the captain's report (a connection gone stale in the time between dispatch and typing would previously crash the bridge with no visible pane signal before the captain even started typing, or mid-delivery of his line, matching "no response, no visible change"). It is **not**, however, a confirmed match: no reproduction attempt - through any path reachable via the Herdr pane API - ever produced the captain's exact failure, with or without this defect present. The pane-focus/GUI-routing hypothesis above also remains untested by anything but indirect evidence. Anyone re-investigating a future recurrence of "typed a line, pressed Enter, nothing happened" on `hermes-vps` should check first whether the pane crashed to a bare shell prompt (this defect's old signature, now fixed) versus whether the pane is still showing the bridge's own idle state (points back toward the pane-focus/GUI-routing gap this investigation could not rule in or out).

A follow-up re-test found a THIRD explanation, distinct from both hypotheses above: a genuinely working but slow turn rendered nothing at all in the pane while it was in flight, indistinguishable from either failure mode above by a captain watching the pane - see "hermes-vps: working indicator for a slow in-flight turn" below.

## hermes-vps: working indicator for a slow in-flight turn

Fixed 2026-09-14, following a captain re-test of the pane after the fix above: a line typed directly into a live `hermes-vps` pane eventually got a real response, but the pane showed nothing at all while it was in flight - only the eventual content, with no way to tell a slow-but-working turn apart from a dead one in the meantime. This is a third, independent explanation alongside the two in the section above, not a contradiction of either: the pane genuinely had no busy/spinner/composer state of any kind (`../../.agents/skills/harness-adapters/references/harness/hermes-vps.md`'s "Composer" row already documented this as a known gap before this fix).

**Fix**: `bin/fm-hermes-vps-bridge.py`'s `handle_event` now prints a bare `[working...]` line on every `message.start` event - the earliest point-in-time signal the existing event stream offers, so no new polling loop was added. `message.start` already fired unconditionally at the top of every turn (used internally to set `self.busy = True` and reset the per-turn text buffer) but was never itself rendered before this fix; only `message.delta`/`tool.start`/`message.complete`/`error` were.

**Offline verification (no VPS credentials in this task's worktree)**: `tests/fixtures/fm-hermes-ws-stub-server.py` gained a `STUB_DELAY:<seconds>:<text>` `prompt.submit` trigger that sleeps server-side, real wall-clock time, between sending `message.start` and sending the delayed `message.delta`/`message.complete` - a stand-in for genuine slow-turn latency (e.g. a `sleep`-based VPS command) without slowing the suite down for real. `tests/fm-hermes-vps-bridge.test.sh`'s `test_bridge_renders_working_indicator_before_slow_response` drives the real bridge subprocess against this over a real loopback socket (never a background-`cat`-drained log file - see the test's own comment on why that specific technique is unsound for a timing assertion) and asserts, from the bridge's own stdout, that `[working...]` renders immediately after the delivery-confirmation bullet and that at least 2 of the stub's 4 configured delay seconds elapse before the delayed content itself renders:

```
$ bash tests/fm-hermes-vps-bridge.test.sh
...
ok - working indicator: [working...] renders immediately on message.start and nothing else renders until the delayed response lands
```

Also confirmed directly against the real bridge subprocess and stub, outside the test harness, with wall-clock timestamps on every rendered line (macOS arm64, Python 3.13.12):

```
[0.16s] READY: Hermes VPS bridge ready. session_id=test-session-1
[0.16s] LINE: ● STUB_DELAY:4:slow reply landed
[0.16s] LINE: [working...]
[4.19s] LINE: slow reply landed
[4.20s] LINE: [turn complete]
```

`[working...]` rendered within 0.02s of the delivery bullet, and the delayed content landed only once the stub's real 4-second sleep elapsed - proving the indicator is driven by `message.start` itself, not by anything that could coincide with the delayed content.
No VPS credentials exist in a dispatched task's own worktree (only in the running firstmate home's gitignored `.env`, per `bin/fm-hermes-ws-env-lib.sh`), so this fix has not yet been re-confirmed against the real VPS; re-run against a live `hermes-vps` pane submitting a genuinely slow command (e.g. `sleep 10`) the next time one is available, and update this section with that result.

## hermes-vps: local-submit ("sending") signal and a ready-for-input marker

Fixed 2026-09-14, following a captain live-test of the `[working...]` fix above: two further real gaps in the same pane. First, `[working...]` itself only ever rendered once the SERVER confirmed the turn (`message.start`), i.e. after the full round trip to the VPS had already begun - a captain pressing Enter got no feedback at all until that round trip completed. Second, the pane had no visible signal that it was idle and ready to accept a line at all, unlike every other verified harness's own composer.

**Fix**: `bin/fm-hermes-vps-bridge.py`'s `_forward()` - the one choke point every submission path already shares (pane-typed input, brief-content delivery, inbox-polled steers) - now prints a bare `[sending...]` line the instant it is about to issue `prompt.submit`/`session.steer`, before that RPC call; this is deliberately a distinct signal from `[working...]`, which still means the server has confirmed the turn is running, not just that this bridge tried to send it. Symmetrically, `handle_event` now prints a bare `❯` (the same idle-composer glyph `bin/fm-composer-lib.sh` already documents for claude) once whenever the bridge becomes idle: right after `start()`'s readiness banner, and after every `message.complete`/`error` event resets `self.busy` to `False`. Neither addition touches the RPC protocol, the status/report/inbox bridge, or fleet-dispatch wiring - both are pane-rendering only, and `hermes-vps`'s own busy classification (`fm_busy_hermes_vps_agent_running`) remains a live `session.status` RPC that never reads pane text, so neither marker can be mistaken for a structural busy/idle source.

**Offline verification (no VPS credentials in this task's worktree, same constraint as the working-indicator fix above)**: `tests/fm-hermes-vps-bridge.test.sh` gained two new tests exercising the real bridge subprocess against the real stub server over a real loopback socket - `test_bridge_renders_sending_indicator_before_working_on_ordinary_submit` (proves the print order `● <line>` -> `[sending...]` -> `[working...]` on the ordinary fast path, no artificial delay) and `test_bridge_renders_ready_marker_when_idle_and_absent_while_busy` (proves `❯` renders once on idle, never mid-turn across an entire busy stretch, and reappears exactly once after `[turn complete]`) - plus updates to the three existing tests whose exact-line-sequence assertions now need to account for the new markers (`test_bridge_lifecycle_over_real_socket`, `test_bridge_missing_brief_never_reports_false_delivery`, `test_bridge_renders_working_indicator_before_slow_response`):

```
$ bash tests/fm-hermes-vps-bridge.test.sh
...
ok - sending indicator: [sending...] renders on local submit before [working...] confirms the server round trip is in flight
ok - ready marker: ❯ renders when idle and never mid-turn, reappearing once the turn completes
```

Also confirmed directly against the real bridge subprocess and stub, outside the test harness, with wall-clock timestamps on every rendered line (macOS arm64, Python 3.13.12) - an ordinary fast submission, then a `STUB_DELAY:3` slow one:

```
[0.06s] READY: Hermes VPS bridge ready. session_id=test-session-1
[0.06s] LINE: ❯
[0.06s] LINE: ● hello captain
[0.06s] LINE: [sending...]
[0.06s] LINE: [working...]
[0.06s] LINE: stub
[0.06s] LINE: [turn complete]
[0.06s] LINE: ❯
[0.11s] LINE: ● STUB_DELAY:3:slow reply landed
[0.11s] LINE: [sending...]
[0.12s] LINE: [working...]
[3.15s] LINE: slow reply landed
[3.15s] LINE: [turn complete]
[3.15s] LINE: ❯
```

`[sending...]` rendered within the same tick as the submitted line's delivery bullet on both turns - well before `[working...]`, which (as the working-indicator fix above already established) only renders once `message.start` actually arrives - and `❯` rendered once on open, never during either busy stretch, reappearing once each turn completed.
Under this sandbox's own CPU scheduling, a further repeat of the delayed-submission run occasionally showed `[working...]` itself arriving only once the stub's sleep elapsed instead of promptly after `message.start` - the SAME class of timing variance the working-indicator fix's own test already carries as a rare environment-level flake (`docs/verification/hermes.md`'s prior section; reproduced identically against this task's unmodified baseline before any of this task's changes, so it predates and is unrelated to the sending/ready-marker work here) rather than anything introduced by this fix, since neither new marker touches `message.start` handling at all.
No VPS credentials exist in a dispatched task's own worktree, so neither fix has yet been re-confirmed against the real VPS; re-run against a live `hermes-vps` pane the next time one is available, and update this section with that result.

## hermes-vps: the sending/ready-marker fix above did not survive real-world use

Fixed 2026-09-14, following a captain live-test of the fix directly above against a fresh `hermes-vps` crewmate: both regressions the prior fix targeted were still present in practice, for two different reasons neither the offline stub tests above nor a direct-pane-typing live check could have caught.

**"[sending...]" not immediate.** Live-testing the merged fix by typing directly into a real `hermes-vps` pane (a raw pty, and a real tmux pane, both against the real VPS) showed `[sending...]` rendering within milliseconds of pressing Enter, exactly as the section above documented - direct pane typing was never the broken path. The captain's actual steering path is `fm-send.sh`'s durable inbox (`AGENTS.md` section 7: "Steer a worker with ordinary text through fail-closed fm-send"), delivered here by `poll_inbox()`, never by typing into this pane directly. `poll_inbox()` ran only once per `run()`'s own `select()` loop iteration, gated by `now - self._last_inbox_poll >= INBOX_POLL_INTERVAL`, and `INBOX_POLL_INTERVAL` was `EVENT_WAIT_TIMEOUT` (30s) - the SAME value `select()` itself used as its blocking timeout whenever the pane was otherwise idle. A steer landing on an idle bridge could therefore sit unnoticed for up to roughly two poll periods before `[sending...]` ever printed. Live-reproduced against the real VPS: a steering record dropped into an idle bridge's `--inbox-dir` took **38 seconds** to produce `[sending...]`.

**Ready marker not inline.** `_print_ready_marker()` printed the glyph with a normal trailing newline (`print(READY_MARKER, flush=True)`), which is exactly what makes it read as a label sitting above an empty line rather than a prompt a captain types into: the cursor ends up on a fresh blank line below the marker, not beside it. Live-reproduced against the real VPS over both a raw pty and a real tmux pane; the raw bytes right after the readiness banner were `...\xe2\x9d\xaf\r\n` (glyph, then an unconditional carriage-return-newline).

**Fix**: `bin/fm-hermes-vps-bridge.py`.

- `INBOX_POLL_INTERVAL` is now its own constant (1.0s), decoupled from `EVENT_WAIT_TIMEOUT`, and `run()`'s `select()` call uses `min(EVENT_WAIT_TIMEOUT, INBOX_POLL_INTERVAL)` as its own timeout whenever `--inbox-dir` is armed, so an idle bridge wakes and checks the inbox on `INBOX_POLL_INTERVAL`'s cadence instead of `EVENT_WAIT_TIMEOUT`'s.
- `_print_ready_marker()` now prints the glyph plus one trailing space with **no** trailing newline (`print(f'{READY_MARKER} ', end='', flush=True)`), so a real attached terminal's own input echo continues on the same line. Because the pane can no longer assume every earlier print left it on a fresh line, `self._prompt_pending` tracks whether the bare marker is still the last thing printed (set by `_print_ready_marker()`, cleared by `_echo()`), and `_forward()` - the one choke point every submission path shares - prepends a single newline exactly when nothing has cleared it since the marker. This matters only for `poll_inbox()`'s direct `_forward()` call, since it never calls `_echo()` first the way pane-typed input does; without it, fixing the newline would have made an inbox-delivered `[sending...]` glue onto the marker's own line instead.

**Live verification against the real VPS** (not the offline stub - this task's worktree had no VPS credentials of its own, so the running firstmate home's `.env` values were exported directly into a disposable Python/tmux probe rather than copied into the worktree):

Inbox-steer promptness, before the fix (raw pty, `--inbox-dir` armed, a steering record dropped in immediately after the bridge opened idle):

```
t=0.00  ready, idle
... (nothing renders)
t=38.48  [sending...]
t=38.60  [working...]
```

The same probe after the fix:

```
t=0.02  Hermes VPS bridge ready. session_id=8912da10
❯
t=1.12  [sending...]
[working...]
```

Ready-marker byte shape, before and after, captured with a raw pty (`repr()` of the exact bytes right after the readiness banner):

```
before: b'Hermes VPS bridge ready. session_id=...\r\n\xe2\x9d\xaf\r\n'
after:  b'Hermes VPS bridge ready. session_id=...\r\n\xe2\x9d\xaf '
```

And confirming the marker/sending-boundary fix (an inbox-delivered steer right after the marker, raw bytes):

```
b'\r\n[sending...]\r\n[working...]\r\n...\r\n[turn complete]\r\n\xe2\x9d\xaf '
```

- the leading `\r\n` is `_forward()`'s inserted separator, proving `[sending...]` starts its own line rather than gluing onto `\xe2\x9d\xaf` (the bare marker).

Also confirmed in a real tmux pane against the real VPS (not just a raw pty): a captain-typed line still produces `[sending...]` within single-digit milliseconds of pressing Enter (unaffected by this fix, matching the section above), and `tmux capture-pane` shows the marker and a subsequent typed line sharing one visual row instead of the marker occupying an empty row by itself.

**Test coverage**: `tests/fm-hermes-vps-bridge.test.sh` gained `test_bridge_forwards_inbox_steer_promptly` (pins the inbox-promptness fix: a steer dropped into an idle bridge's `--inbox-dir` must produce `[sending...]` within a few seconds, not the old ~30-60s-tied cadence, and the marker/sending boundary must never glue together) and a new `expect_ready_marker` helper used by every existing ready-marker assertion, which reads the marker's exact bytes (a bare `read -r` line read cannot: the marker no longer ends in a newline) and confirms nothing - in particular no trailing newline - follows it until new input is submitted. bash 3.2 (macOS's system bash, this suite's actual runtime) has no `read -N`, so the new `read_bytes_timeout` helper drives a small `python3 os.read()`/`select()` reader against the same already-open fd instead.

## hermes-vps: `prompt.submit`'s transport rebind fires before the busy check - confirmed by source, not by test

Confirmed 2026-09-15 by reading the installed vendor source directly (`~/.hermes/hermes-agent/tui_gateway/server.py`, the same v0.16.0 install this record's "Subject" section pins), in response to a review finding that `bin/fm-hermes-vps-bridge.py`'s `_submit_or_steer` docstring asserted a rebind-on-reject behavior neither the offline stub server nor any test in this repo could prove.

The `prompt.submit` RPC handler (`tui_gateway/server.py:4526-4540`):

```python
@method("prompt.submit")
def _(rid, params: dict) -> dict:
    sid, text = params.get("session_id", ""), params.get("text", "")
    ...
    session, err = _sess_nowait(params, rid)
    if err:
        return err
    # Re-bind to the current client transport for this request. This keeps
    # streaming events on the active websocket even if an earlier disconnect
    # or fallback moved the session transport to stdio.
    if (t := current_transport()) is not None:
        session["transport"] = t
    with session["history_lock"]:
        if session.get("running"):
            return _err(rid, 4009, "session busy")
```

The transport rebind (`session["transport"] = t`) runs unconditionally on every `prompt.submit` call that resolves a session, strictly before the `session.get("running")` check that returns the `4009 "session busy"` error. So a `prompt.submit` rejected as busy still rebinds the session's transport to the caller's current connection first - a turn genuinely still running server-side after a reconnect gets its remaining events routed to the new connection even though the submit itself was rejected.

This is vendor-controlled server behavior, not something `bin/fm-hermes-vps-bridge.py` causes or enforces, and the offline stub server used by `tests/fm-hermes-vps-bridge.test.sh` has no session/transport-routing model that could prove this without reimplementing a meaningful slice of the real server's session internals - so this fact is recorded here by source inspection, the same way the `session.create` `cwd`-not-honored finding above is, rather than pinned by an executable test. Re-confirm against the installed source if `~/.hermes/hermes-agent` is upgraded past v0.16.0, since this ordering is vendor-controlled and could change.
