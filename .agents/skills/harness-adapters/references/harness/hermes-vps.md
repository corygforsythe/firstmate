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
| Exit command | `/exit`, delivered the ordinary text-submit way. The bridge recognizes this exact line locally, calls the real `session.close` RPC to retire the server-side session, then exits the local process - it is never forwarded to the model. |
| Interrupt | **A real, verified RPC** (`session.interrupt`), unlike bare hermes's "no safe key exists" gap. `../../../../bin/fm-control-lib.sh`'s `fm_control_interrupt_via_text` names the literal line `/interrupt`, delivered through the ordinary text-submit pane mechanic (not a named key - this transport has no composer for `Escape`/`Ctrl+C` to act on); the bridge recognizes it locally and calls the RPC instead of forwarding it as chat. `fm-control.sh interrupt\|exit\|relaunch` all work normally. |
| Skill invocation | Not applicable - crewmate/scout only. |
| Autonomy | Whatever the VPS's own Hermes deployment is configured with; the bridge passes no autonomy flag of its own. |
| File access | **The VPS's own filesystem only - see "Known limitation" below.** |
| Trust dialog | None observed (no vendor UI at all). |
| Environment marker | None needed: the bridge is a distinct tracked script (`fm-hermes-vps-bridge.py`), matched structurally by `../../../../bin/fm-hermes-lib.sh`'s `fm_hermes_vps_bridge_*` functions, the same interpreter-argv[1] pattern bare hermes's own identity check uses. |
| Process name | Always the python interpreter (`python3`/`python3.*`), with `fm-hermes-vps-bridge.py` as argv[1] - see Detection. |
| Composer | None. The pane is a scrolling event-rendered log, not a composer; there is deliberately no composer-emptiness half in the readiness/delivery gates. |
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

## Rendering

The bridge renders a grounded subset of the real Hermes event vocabulary (read directly from the installed Hermes source, `tui_gateway/server.py`, not inferred): `message.delta` (streamed text), `message.complete` (a `[turn <status>]` marker), `tool.start`/`tool.complete` (a one-line summary each), and `error`.
Every other event type (`reasoning.available`, `subagent.*`, `tool.generating`, todo updates) is deliberately not rendered - an initial pane-rendering scope, not a wire-protocol gap.

## Known limitation: no local file access

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
