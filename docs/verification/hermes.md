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

`data/hermes-serve-verify/report.md` (2026-09-13) found that the captain's real VPS (`http://vps.tail8bdd14.ts.net:9119`, Hermes Agent v0.21.2) puts `/api/ws` in gated mode (`_ws_auth_reason()` in `hermes_cli/web_server.py`) and left the ticket-minting flow uninventoried.
This section resolves the flow itself, by reading the actual v0.21.2 upstream source (via the local install's already-fetched-but-not-checked-out git history at `~/.hermes/hermes-agent`, commit `ee4452991d17534aa561f31ee55596d082aa94e7`, since the local checkout is v0.16.0 and predates it) and confirming the two public, unauthenticated probe endpoints live against the real VPS.
No write or state-changing call was made against the VPS; both requests below are plain `GET`s.

```
$ curl -sS http://vps.tail8bdd14.ts.net:9119/api/status
{"version":"0.21.2", ..., "auth_required":true,"auth_providers":["basic"],"auth_flows":["cookie","native_pkce"], ...}
$ curl -sS http://vps.tail8bdd14.ts.net:9119/api/auth/providers
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

Run 2026-09-14, `FM_HERMES_WS_BASE_URL=http://vps.tail8bdd14.ts.net:9119`, credentials from `$FM_HOME/.env`, Hermes Agent v0.21.2 (`gateway_mode: multiplex`, model `claude-opus-5 (anthropic)`).
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
Do not dispatch a ship task onto it that needs local repo access; `hermes-vps.md`'s "Known limitation" owns this for future dispatch decisions.
