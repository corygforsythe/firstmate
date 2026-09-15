# Hermes Agent, VPS-bridged transport (`harness=hermes-vps`)

Verified 2026-09-13, fleet-dispatch wiring landed against Hermes Agent v0.21.2 on the captain's real VPS (`gateway_mode: multiplex`).
Crewmate/scout only, exactly like its pane-based sibling `hermes` (`references/harness/hermes.md`); refused for `--secondmate` because no primary supervision protocol exists for this transport either.
Distinct from `hermes` in identity, launch, busy state, and lifecycle control - never conflate the two, and never infer hermes-vps's facts from bare hermes's adapter reference.

## What this is

`hermes` (bare) drives the real `hermes --cli` binary directly in a pane.
`hermes-vps` never launches that binary at all: `../../../../bin/fm-hermes-vps-bridge.py` is a local process that opens a session against the captain's remote VPS Hermes gateway over `/api/ws` (the same JSON-RPC-over-WebSocket transport `../../../../bin/fm-hermes-ws.py`/`.sh` expose as a standalone dispatch primitive - `docs/verification/hermes.md` owns that primitive's own evidence) and renders that session's conversation into this pane, so a VPS-dispatched Hermes crewmate is visible and interactive exactly like a local pane-based crewmate.
The pane's foreground process is always this bridge (a python script), never the vendor CLI.

## Operating facts

| Fact | Value |
|---|---|
| Binary | No vendor binary at all. `../../../../bin/fm-hermes-vps-bridge.sh` (env/credential resolution) execs `../../../../bin/fm-hermes-vps-bridge.py` (the bridge itself), both tracked in this repo. |
| Launch | Bare `env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS <bridge.sh> --cwd <worktree>`, the same launch-then-send shape as bare hermes: a readiness gate on the bridge's own `Hermes VPS bridge ready.` banner, then the standard typed absolute brief pointer, then a delivery-confirmation gate - but every signal is a marker the bridge prints itself, not vendor UI text (`../../../../bin/fm-spawn.sh`'s `hermes_vps_wait_for_ready`/`hermes_vps_wait_for_delivery`). |
| Credentials | `FM_HERMES_WS_BASE_URL` plus either `FM_HERMES_WS_TOKEN` or `FM_HERMES_WS_USER`/`FM_HERMES_WS_PASS`, resolved from `$FM_HOME/.env` by `../../../../bin/fm-hermes-ws-env-lib.sh` (shared with `fm-hermes-ws.sh`) - never in a launch command, brief, or status line. |
| Models | None. `session.create`'s own RPC signature carries no model or effort param, so both axes are record-and-omit in task metadata, same contract as bare hermes/kimi. |
| Busy state | Live and structural, not rendered: `../../../../bin/fm-busy-lib.sh`'s `fm_busy_hermes_vps_agent_running` pulls `session.status`'s own literal `Agent Running: Yes`/`Agent Running: No` line over a fresh RPC call each time it is asked - a strictly better signal than bare hermes's rendered-tail fallback, at the cost of one WS round trip (including gated-mode auth) per poll. |
| Exit command | `/exit`, delivered the ordinary text-submit way. The bridge recognizes this exact line locally, calls the real `session.close` RPC to retire the server-side session, then exits the local process - it is never forwarded to the model. The bridge traps SIGTERM, SIGINT, and SIGHUP identically and runs this same `session.close` shutdown on any of them, not just on `/exit` - a post-readiness spawn failure that tears the pane down (`hermes_vps_spawn_fail`'s `tmux kill-window`, which delivers SIGHUP) still closes the VPS session instead of orphaning it; `tests/fm-hermes-vps-bridge.test.sh`'s `test_bridge_closes_session_on_sighup` pins this. |
| Interrupt | **A real, verified RPC** (`session.interrupt`), unlike bare hermes's "no safe key exists" gap. `../../../../bin/fm-control-lib.sh`'s `fm_control_interrupt_via_text` names the literal line `/interrupt`, delivered through the ordinary text-submit pane mechanic (not a named key - this transport has no composer for `Escape`/`Ctrl+C` to act on); the bridge recognizes it locally and calls the RPC instead of forwarding it as chat. `fm-control.sh interrupt\|exit\|relaunch` all work normally. |
| Skill invocation | Not applicable - crewmate/scout only. |
| Autonomy | Whatever the VPS's own Hermes deployment is configured with; the bridge passes no autonomy flag of its own. |
| File access | **The VPS's own filesystem only for the agent's own tools - see "Known limitation" below.** Status, report, and steering are bridged locally instead - see "Status, report, and steering". |
| Trust dialog | None observed (no vendor UI at all). |
| Environment marker | None needed: the bridge is a distinct tracked script (`fm-hermes-vps-bridge.py`), matched structurally by `../../../../bin/fm-hermes-lib.sh`'s `fm_hermes_vps_bridge_*` functions, the same interpreter-argv[1] pattern bare hermes's own identity check uses. |
| Process name | Always the python interpreter (`python3`/`python3.*`), with `fm-hermes-vps-bridge.py` as argv[1] - see Detection. |
| Composer | None. The pane is a scrolling event-rendered log, not a composer; there is deliberately no composer-emptiness half in the readiness/delivery gates. A bare `❯` line now renders once whenever the session is idle (see "Ready-for-input marker" below) - a visual signal only, not a real composer a gate could classify. |
| Effort | None - see Models. |

## Detection

Structurally identical in shape to bare hermes's python-interpreter problem, but a DIFFERENT script identity: `fm_hermes_vps_bridge_path_is_bridge`/`fm_hermes_vps_bridge_args_are_bridge`/`fm_hermes_vps_bridge_pid_is_bridge` (`../../../../bin/fm-hermes-lib.sh`) match a path whose basename is exactly `fm-hermes-vps-bridge.py`, wired into `../../../../bin/fm-agent-process-lib.sh`'s `fm_agent_process_classify` alongside (never merged into) the bare-hermes checks.
This is what lets tmux/Herdr pane liveness (`fm_backend_tmux_agent_state` and the Herdr equivalent) recognize the bridge process as a live agent for `bin/fm-control.sh`'s `alive`/`dead` postconditions.

## Launch and readiness

`launch_template` in `../../../../bin/fm-spawn.sh` resolves `__HERMESVPSBRIDGE__` to the tracked `bin/fm-hermes-vps-bridge.sh` path (no PATH search, no `resolve_*_binary` function - there is no vendor binary to find) and `__WORKTREE__` to this task's worktree, passed as the bridge's own `--cwd` (best-effort only - see "Known limitation").
Readiness (`hermes_vps_wait_for_ready`) greps the pane for the bridge's own `Hermes VPS bridge ready.` banner, printed only once the bridge has actually created a live VPS session; the session's own `session_id` is parsed back out of that same line and recorded as `hermes_vps_session_id=` in `state/<id>.meta` (`hermes_vps_record_session_id`) once delivery is confirmed.
Every other launch-then-send harness's readiness/delivery gates infer state from vendor UI text; this transport's gates read markers the bridge controls completely, so they are a stronger proof, not a weaker one.

## Brief delivery: content, not a pointer

Every other launch-then-send harness receives the literal pointer sentence `Read the brief at <absolute-path> and follow it exactly.` and opens that path itself.
A VPS-hosted Hermes session cannot: it has no access to this machine's filesystem at all.
So the bridge - which DOES run locally - special-cases exactly the FIRST line it receives: if it matches that literal pointer shape and the path is locally readable, the bridge reads the file itself and forwards the file's own CONTENT to the VPS session via `prompt.submit`, instead of the sentence about it.
Every later line (an ordinary steer) is forwarded verbatim, unexamined.
Delivery confirmation mirrors bare hermes's own convention: the bridge echoes every line it forwards with a leading `●` (the same bullet hermes itself prepends to an accepted, submitted message), so `hermes_vps_wait_for_delivery` can grep this pane's plain-text capture for that literal marker exactly like bare hermes's gate does.
If the pointer's path is NOT locally readable, the bridge never echoes that line at all - it prints a local `brief not found` diagnostic and forwards nothing, so the delivery gate's marker grep finds nothing and `hermes_vps_spawn_fail` correctly times the launch out instead of a false CONFIRMED; `tests/fm-hermes-vps-bridge.test.sh`'s `test_bridge_missing_brief_never_reports_false_delivery` pins this.

## Rendering

The bridge renders a grounded subset of the real Hermes event vocabulary (read directly from the installed Hermes source, `tui_gateway/server.py`, not inferred): `message.start` (a bare `[working...]` line, see "Working indicator" below), `message.delta` (streamed text), `message.complete` (a `[turn <status>]` marker), `tool.start`/`tool.complete` (a one-line summary each), and `error`.
Every other event type (`reasoning.available`, `subagent.*`, `tool.generating`, todo updates) is deliberately not rendered - an initial pane-rendering scope, not a wire-protocol gap.
Two further lines are rendered locally by the bridge itself, never from a server event: a `[sending...]` line the instant a line reaches `_forward()` (see "Sending indicator" below), and a bare `❯` whenever the session becomes idle (see "Ready-for-input marker" below).

### Working indicator

The pane has no composer, spinner, or busy state of any kind (see "Composer" above), so a genuinely working but slow turn - one whose first `message.delta` or `tool.start` is many seconds out, with no vendor "typing" signal on this transport - was indistinguishable from a dead session.
The bridge now prints a bare `[working...]` line on every `message.start`, the earliest point-in-time signal the event stream offers without adding a new polling loop; it is a pane log line like every other rendered marker, never cleared in place, and the turn's own later `message.delta`/`tool.start`/`[turn <status>]` lines are what tell the reader the wait ended.
Live-verified (offline, no VPS credentials in a task worktree - see `docs/verification/hermes.md`'s "hermes-vps: working indicator" section) with a stub-driven multi-second delay standing in for a real slow turn (e.g. a `sleep`-based VPS command): `[working...]` renders immediately after submission, nothing else renders during the delay, and the eventual content plus `[turn complete]` land once the response arrives.

### Submit-vs-steer delivery

`_forward()` delivers through `_submit_or_steer()` (`bin/fm-hermes-vps-bridge.py`'s own docstring is the owner of the mechanism): it always tries `prompt.submit` first and falls back to `session.steer` only on the server's own "session busy" rejection (RPC error code 4009), never from a locally-tracked busy flag.
A dropped/reconnected connection can lose the `message.complete`/`error` event that would otherwise clear such a flag, and `session.steer`'s real server behavior queues text for a tool batch that may never arrive - an RPC that succeeds with no error, but a pane that hangs at `[sending...]` forever with nothing to show for it; live-reproduced against the captain's real VPS after a laptop sleep dropped the connection mid-turn.

### Sending indicator

`[working...]` itself only ever rendered once the SERVER confirmed the turn (`message.start`), i.e. after the full round trip to the VPS had already begun - a captain pressing Enter got no feedback at all until that round trip completed, worse on a slow network hop.
`_forward()` (the one choke point every submission path shares - pane-typed input, brief-content delivery, and inbox-polled steers alike) prints a bare `[sending...]` line the instant it is about to issue `prompt.submit`/`session.steer`, before that RPC call - a genuinely distinct, earlier signal from `[working...]`, which still means the server has confirmed the turn is running.
Never printed for input that never reaches `_forward()` (the doorbell line, a brief pointer whose path does not exist, `/exit`, `/interrupt`), so a local read/parse failure before submission never falsely claims a send was attempted.
Direct pane-typed input was always immediate (proven within milliseconds against the real VPS, `docs/verification/hermes.md`'s "did not survive real-world use" section), but that was never the captain's real steering path: `AGENTS.md` section 7's `fm-send.sh` writes into `--inbox-dir`, delivered by `poll_inbox()`.
`poll_inbox()` only runs once per `run()`'s own `select()` loop iteration; `INBOX_POLL_INTERVAL` is its own constant (1.0s by default, decoupled from `EVENT_WAIT_TIMEOUT`), and `run()`'s `select()` timeout is capped to it whenever `--inbox-dir` is armed, so an idle bridge notices a durable steer on that cadence instead of `EVENT_WAIT_TIMEOUT`'s (30s) - live-verified against the real VPS: an inbox-delivered steer on an idle bridge previously took 38s to produce `[sending...]`, now under 2s.

### Ready-for-input marker

The pane had no visible signal that it was idle and ready to accept a line at all, unlike every other verified harness's own composer.
A bare `❯` (the same idle-composer glyph `bin/fm-composer-lib.sh` already documents for claude), followed by a trailing space and **no newline**, renders once whenever the bridge becomes idle: right after the readiness banner, and after every `message.complete`/`error` event.
No trailing newline is deliberate: a real attached terminal's own input echo continues on the marker's own line, so it reads as an inline prompt rather than a label sitting over an empty line below it (live-verified against the real VPS, both a raw pty and a real tmux pane - `docs/verification/hermes.md`'s "did not survive real-world use" section has the exact before/after bytes).
Because the pane can no longer assume every earlier print left it on a fresh line, `self._prompt_pending` tracks whether the bare marker is still the last thing printed; `_forward()` prepends one newline exactly when nothing has cleared it since the marker (only `poll_inbox()`'s direct `_forward()` call needs this, since it never echoes the line first the way pane-typed input does), so an inbox-delivered `[sending...]` still starts its own line instead of gluing onto the marker's.
Because the pane is an append-only scrollback with no way to erase a prior line, "absent while a submission is in flight" means exactly that no NEW `❯` line is printed between a `[sending...]` and the next idle transition - the reader judges the pane's current state from its tail, the same convention every composer-having harness already uses.
This is a rendering-only signal: `hermes-vps`'s own busy classification (`fm_busy_hermes_vps_agent_running`) is a live `session.status` RPC and never reads pane text, so neither this marker nor `[sending...]` can be mistaken for a structural busy/idle source by anything that classifies this task's state.
Live-verified (offline, same methodology as above): `❯` renders once right after the readiness banner, no `❯` line appears anywhere during a submission's busy stretch (bullet, `[sending...]`, `[working...]`, streamed content, `[turn <status>]`), and it reappears exactly once more right after the turn completes.

## Status, report, and steering: bridged locally, not filesystem access

The remote VPS agent has no path back to this Mac's filesystem at all (see "Known limitation" below), so it cannot append `state/<id>.status`, write `data/<id>/report.md`, or read `state/<id>.inbox/` the way every other harness's crewmate does directly.
Live-verified 2026-09-14 (`docs/verification/hermes.md`'s "hermes-vps: local status/report/steering protocol" section) after a live-verification finding that a broken dispatch on this harness produced literally no signal in Firstmate, not even a `blocked:` line: the local bridge (`../../../../bin/fm-hermes-vps-bridge.py`) now owns all three as a transport concern, using `--status-file`/`--report-file`/`--inbox-dir` (armed by `../../../../bin/fm-spawn.sh`'s launch template, all optional so older callers and tests still work with `--cwd` alone).

- **Status**: the remote agent includes a line of the exact shape `FIRSTMATE-STATUS: <state>[ [key=..]]: <note>` in the plain text of its own chat reply (never a shell command); the bridge scans each completed turn's FULL accumulated text (every `message.delta` chunk since the last `message.start`, never `message.complete`'s own `text` field alone - see the next paragraph) for that sentinel, validates the state word against `fm-classify-lib.sh`'s vocabulary itself, and appends only the validated `<state>: <note>` line to the real local status file. A line that fails validation is never written verbatim.
- **Report**: the remote agent wraps its findings between bare `FIRSTMATE-REPORT-BEGIN`/`FIRSTMATE-REPORT-END` marker lines in ONE reply; the bridge writes exactly the text between them to the real local report file, replacing prior content.
- **Steering**: the bridge itself polls `--inbox-dir` once per loop iteration (`fm-task-inbox-lib.sh`'s own record format), forwards each body through the same `_forward()` path pane-typed input uses, and moves the record to `handled/` only after a confirmed delivery. The doorbell line every other harness's pane receives (`fm_task_inbox_doorbell_line`, `": Firstmate instruction waiting: ..."`) names a local path this agent can never reach, so the bridge recognizes and swallows that exact line locally rather than forwarding an instruction the model cannot act on.
- **Failure signal**: a protocol failure (malformed status line, a local write that fails, an unreadable inbox record) always produces a bridge-authored diagnostic through the bridge's own `write_status_line()`, never text the remote agent supplied, so the fix cannot itself become a new silent-failure path.
- **Scaffolding**: `../../../../bin/fm-brief.sh --harness hermes-vps` renders this protocol into the worker-side brief instead of the literal local shell commands every other harness receives, and for a scout, routes the captain-hold-lifecycle completion gate to firstmate itself rather than the worker - the worker cannot read `.agents/skills/captain-hold-lifecycle/SKILL.md` or run `bin/fm-captain-hold.sh` either. If its investigation surfaces a captain-relevant question, the brief tells it to name that explicitly inside its report's own `## Open questions for the captain` section instead.

`message.complete`'s `text` field is NOT reliably a turn's full cumulative text: live-reproduced, a turn that emits text, then a tool call, then more text fires exactly ONE `message.start`/`message.complete` pair for the whole turn, and that field holds only the LAST text segment.
An opening `FIRSTMATE-STATUS:` line emitted before the agent reaches for a tool would be silently dropped by trusting that field alone; the bridge instead accumulates every delta chunk itself.
A second, independent bug fixed alongside this one: mixing `select()` with buffered `sys.stdin.readline()` can strand an already-buffered second line invisibly whenever two lines arrive close together (a steering doorbell immediately followed by real content, for example), because `readline()` can pull multiple lines into its own internal buffer from one underlying read while `select()` only observes the OS-level fd - fixed by reading stdin with raw `os.read()` and assembling lines ourselves.
Both are pinned by portable regressions in `tests/fm-hermes-vps-bridge.test.sh` (`test_bridge_recovers_status_line_split_by_tool_call`, `test_bridge_suppresses_inbox_doorbell_line`).

## Known limitation: no local file or repo access for the agent's own tools

**`session.create`'s `cwd` param is NOT honored on the captain's real VPS deployment** (live-verified, `docs/verification/hermes.md`'s "Live verification against the real VPS" section - a real `terminal` tool call inside a created session printed `pwd` as `/`, not the requested cwd).
The VPS agent's own file and terminal tools therefore reach only the VPS's OWN filesystem, never this task's local git worktree, regardless of what `--cwd` the bridge was launched with.
**Do not dispatch a ship or scout task onto `hermes-vps` that needs the agent to read or edit this project's code, run `git`, or drive the no-mistakes pipeline** - none of that is reachable from the VPS's own remote shell.
This transport is proven useful today for VPS-local work (the agent's own sandbox: shell commands, files, and tools that live on the VPS itself) and for proving the fleet-visibility wiring end to end; it is not yet a substitute for a real local crewmate on project work.
A local worktree is still created and recorded for this task like any other (`worktree=` in `state/<id>.meta`), for bookkeeping and PR-path consistency, not because the VPS agent can reach it.

## Live verification

```
$ bin/fm-spawn.sh <id> <project> --scout --harness hermes-vps
spawned <id> harness=hermes-vps backend=<tmux|herdr> ...
$ bin/fm-crew-state.sh <id>
state: working · source: hermes-vps-status ...
$ bin/fm-control.sh <id> interrupt
interrupt-delivered <id> harness=hermes-vps backend=<...> verified=...
$ bin/fm-control.sh <id> exit
stopped <id> harness=hermes-vps backend=<...> endpoint=... worktree=...
```

See `docs/verification/hermes.md`'s "hermes-vps: fleet-dispatch wiring" section for the exact dated commands and output this table summarizes, and re-run after any change to the bridge, `bin/fm-hermes-ws.py`, or a VPS Hermes upgrade.
