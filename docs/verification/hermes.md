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

Two prior scout investigations established the baseline facts with no adapter code landed:
[`data/hermes-harness-verify/report.md`](../../data/hermes-harness-verify/report.md) (launch shape, detection problem, busy/interrupt findings, terminal-backend blocker) and
[`data/hermes-serve-verify/report.md`](../../data/hermes-serve-verify/report.md) (the `hermes serve`/`/api/ws` JSON-RPC transport alternative).
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

Per this task's brief, the `/api/ws` JSON-RPC transport (`data/hermes-serve-verify/report.md`) was NOT pursued: it requires either resolving the captain's VPS ticket-auth flow (out of scope, a real design decision) or deciding whether Firstmate should launch its own scratch `hermes serve` process per crewmate versus dispatching against the captain's existing persistent instance (also a real design decision, not one this task should presuppose).
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
