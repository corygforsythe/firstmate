# Hermes Agent (`hermes` CLI)

Verified 2026-09-13 on Hermes Agent v0.16.0 (2026.6.5) for crewmate/scout work only.
Not verified, and not naturally verifiable, as a secondmate or primary: hermes has no turn-end hook and no primary supervision protocol, the same gap that scopes rovo/muse/gemini/agy to crewmate/scout.
Also NOT wired into `../../../bin/fm-control-lib.sh` at all (see "Interrupt: no safe key exists" below) - `bin/fm-control.sh interrupt|exit|relaunch` refuses a hermes task outright rather than guessing a mechanic for it.

## Operating facts

| Fact | Value |
|---|---|
| Binary | `resolve_hermes_binary` in `../../../bin/fm-spawn.sh` resolves `PATH`, then falls back to `$HOME/.local/bin/hermes`; spawning refuses if neither is executable. |
| Launch | Bare `hermes --cli --yolo` (no positional prompt), the kimi/rovo launch-then-send shape: a readiness gate on the `Welcome to Hermes Agent!` banner, then a typed absolute brief pointer, then a delivery-confirmation gate. `--tui` and `-z`/`--oneshot` are both non-viable (see "Launch and readiness" below). |
| Models | `-m <model>` (NOT the generic `--model` flag - hermes's own flag name), `--provider <provider>` for a non-default provider. The account's configured default model can be unavailable for its integrator (verified: `gpt-5.3-codex` failed `model_not_available_for_integrator` on a GitHub Copilot pool); `hermes` has no quota-axi provider mapping (stays unmapped, like rovo), so a real dispatch needs an explicit `--model` the captain knows works for that account. |
| Busy state | Rendered-tail fallback, isolated to hermes like grok/rovo - the busy footer's `msg=interrupt` hint token, matched by `fm_busy_hermes_tail_busy` in `../../../bin/fm-busy-lib.sh` - because no turn-granularity or busy/idle-granularity hook was found (`hermes hooks`/`--accept-hooks` exist but were not confirmed to carry one). |
| Exit command | `/exit`; cleanly returns to the shell prompt (confirmed live, twice). Typing `/exit` while the agent is BUSY does NOT reliably exit - it was observed being swallowed into the busy-redirect input path instead of executing as a command (see "Interrupt" below); only send it while idle. |
| Interrupt | **No safe key exists.** Ctrl+C exits the whole session outright (`Goodbye! ⚕`, back to a bare shell) despite the busy footer's own `Ctrl+C cancel` text. Escape is a no-op: sent mid-tool-call it printed a transient `Initializing agent...` redraw but did NOT cancel the running tool call, which continued and completed normally (confirmed live, both findings independently reproduced). The only verified-safe redirect is typing new text and pressing Enter while busy, which prints `Operation interrupted: retrying API call after error...` / `[Interrupted - processing new message]` and redirects the run without killing it - a message-submission mechanic, not a key, which `../../../bin/fm-control-lib.sh`'s key-based interrupt table cannot express today. |
| Skill invocation | Not applicable - hermes is crewmate/scout only and no ship crewmate has been verified end to end against a real, working provider (see "Terminal-backend prerequisite" below). |
| Autonomy | `--yolo` bypasses all dangerous command approval prompts. |
| File access | **No confinement at all** - any absolute path is accessible with no grant mechanism needed (the opposite of rovo). `_resolve_path_for_task` in hermes's own `file_tools.py` passes an absolute path straight through unchecked; a relative path resolving outside the workspace root only warns. The standard instructions/steering/status/report loop works with zero extra flags. |
| Trust dialog | None observed. |
| Environment marker | **None.** hermes publishes no launch-time env marker comparable to rovo's `ROVODEV_CLI=1` (checked against v0.16.0's `cli.py`); detection is structural-only (see Detection). |
| Process name | Always the python interpreter (`python3`/`python3.11`), never `hermes` - see Detection. |
| Composer | A bare `❯` prompt when idle, no border, no ghost/placeholder text observed. Busy renders as `⚕ ❯ msg=interrupt · /queue · /bg · /steer · Ctrl+C cancel` on the same prompt row - a DIFFERENT shape than idle, which `../../../bin/fm-composer-lib.sh`'s shared classifier reads as `unknown`, never `empty` (see "Delivery gate" below). |
| Effort | **None.** No effort/reasoning-level concept exists anywhere in the CLI (`hermes --help`, `hermes chat --help`, and a grep of both for effort/reasoning found nothing); the requested axis is recorded in task metadata only, never passed to the launch, the same record-and-omit contract as kimi. |

## Detection

hermes ships as a python venv script (`~/.hermes/hermes-agent/venv/bin/python3 ~/.hermes/hermes-agent/venv/bin/hermes ...`), so its live process reports `comm` as the interpreter (`python3`/`python3.11`) and argv[0] is that same interpreter path - nothing about the process NAME says hermes.
Only argv[1], the script path, carries the identity, the same structural shape `../../../bin/fm-gemini-lib.sh` exists to solve for Gemini's node-bundle process (interpreter argv[0], script argv[1]).
`../../../bin/fm-hermes-lib.sh` is the direct python-interpreter analogue: `fm_hermes_path_is_hermes` matches a path whose basename is exactly `hermes` or which sits inside a `hermes-agent` install-tree component; `fm_hermes_args_are_hermes`/`fm_hermes_pid_is_hermes` skip a `python3`/`python3.*`/`python`/`Python` argv[0] and then require the next non-flag token to satisfy that path check.
`../../../bin/fm-harness.sh`'s `python*` interpreter arm and `../../../bin/fm-agent-process-lib.sh`'s tmux/herdr liveness classifier both consult it, so both the "who am I" detection and "is that pane still alive" liveness question resolve the same live process correctly - confirmed live (`bin/fm-harness.sh ancestry <pid>` returned `args hermes` for a real running `hermes --cli` process, and `fm_agent_process_classify` returned `agent` for the same process).

## Launch and readiness

The launch template clears `CLAUDECODE`, `PI_CODING_AGENT`, `GROK_AGENT`, and `FM_PI_HARNESS` inline as defense in depth (unverified either way whether hermes scrubs an inherited marker), and the shared outer wrap clears `CURSOR_AGENT`/`CURSOR_INVOKED_AS` like every other non-cursor harness.
hermes launches BARE (`hermes --cli --yolo`, plus any `-m` flag) and takes its brief only after the CLI comes up - the same launch-then-send shape as kimi/rovo, wired through the same shared readers (`fm_backend_capture`, `fm_backend_composer_state`, `fm_backend_send_text_submit`):

1. **Readiness gate** (`hermes_wait_for_ready` in `../../../bin/fm-spawn.sh`): poll for the fresh-launch `Welcome to Hermes Agent!` banner, falling back to composer-empty.
2. **Typed pointer**: `Read the brief at <absolute-path> and follow it exactly.`, submitted through `fm_backend_send_text_submit`.
3. **Delivery gate** (`hermes_wait_for_delivery`): see "Delivery gate: deliberately not composer-empty-gated" below.

`--tui` reaches a real, well-defined ready state but hit a hard `unsupported_api_for_model` wall on every model tried against a GitHub Copilot integrator (`--tui` always drives the OpenAI Responses API, which that account's pooled credential does not grant); `-z`/`--oneshot` never even attempts a turn (`hermes -z: no final response was produced`, reproduced twice, no `agent.turn_context` line in the log either time).
`--cli` is the only mode confirmed to work end to end: readiness banner, typed pointer accepted, a real terminal-tool call run to completion, and a clean `/exit`.
See `../../../../docs/verification/hermes.md`.

## Delivery gate: deliberately not composer-empty-gated

Unlike rovo/kimi, `hermes_delivery_is_confirmed` does NOT require `hermes_composer_is_empty` as a hard conjunct.
Confirmed live: while a submitted turn is busy, hermes's prompt row renders the `⚕ ❯ msg=interrupt · ...` hint line, which `../../../bin/fm-composer-lib.sh`'s shared classifier reads as an unrecognized shape ("unknown"), never "empty" - for the ENTIRE first turn, not just a brief in-flight moment.
A hard composer-empty AND-gate (the rovo/kimi shape) was tried first and reproduced exactly this failure live: a real `bin/fm-spawn.sh` dispatch against a real hermes install reported `hermes brief pointer delivery was not confirmed` even though the agent had genuinely received and begun acting on the brief.
The fix: confirm delivery instead by the leading `●` hermes prepends to an accepted, echoed user message in its transcript (confirmed live: the unsubmitted composer shows `❯ Read the brief at ...` with no bullet; the accepted, submitted message shows `● Read the brief at ...` on its own transcript line, distinct from the composer row) OR by the context token count (`<used>/<total>`, e.g. `12.2K/128K`) advancing off its pre-submission `ctx --` value - kept as a second, independent corroborating signal in case a hermes release changes the bullet glyph.
Re-verified live after the fix: the same dispatch shape now reports `spawned ... harness=hermes` successfully.

## Terminal-backend prerequisite: `terminal.backend: ssh`

The captain's real `~/.hermes/config.yaml` has `terminal.backend: ssh` with no `ssh_host`/`ssh_user` set, which breaks the agent's terminal/`execute_code` tool outright: `SSH backend selected but TERMINAL_SSH_HOST and TERMINAL_SSH_USER are not both set`.
Reproduced live end to end: a real `bin/fm-spawn.sh` dispatch against the real install launched, delivered its brief pointer cleanly, and then hung indefinitely (confirmed past 2 minutes, still busy, no progress) retrying `execute_code` to open the launch brief file, because the agent chose the terminal tool over a dedicated file-read tool for that call.
`--ignore-user-config` (documented to fall back to built-in defaults, `.env` credentials still loaded) reliably routes around it - re-verified with it forced on the raw-launch escape hatch, the same dispatch then used `read_file` successfully with no terminal error at all - but it ALSO discards the account's configured `model.provider: copilot` default, so a launch using it needs an explicit `--provider` too or the run fails a different way (`ValidationException: The provided model identifier is invalid`, from silently falling through to a `bedrock` provider default with a non-bedrock model id - reproduced live).
The launch template deliberately does NOT force `--ignore-user-config` (see `../../../bin/fm-spawn.sh`'s hermes launch-template comment and `../../../../docs/verification/hermes.md`) - forcing it would make that tradeoff for the captain rather than surfacing it.
A real crewmate dispatch against this account needs either the captain's `~/.hermes/config.yaml` fixed (`terminal.backend: local`) or an explicit, captain-approved per-dispatch `--ignore-user-config --provider copilot` (or equivalent) override.

## Interrupt: no safe key exists

This is the single most safety-relevant finding for this adapter, and it is why hermes is absent from every `../../../bin/fm-control-lib.sh` table rather than guessed into one.
Ctrl+C, despite the busy footer's own `Ctrl+C cancel` text, exits the ENTIRE session (`Goodbye! ⚕`, back to a bare shell prompt) - confirmed live during a genuine mid-flight terminal-tool call.
Escape, the key every other verified adapter interrupts with, is a no-op for hermes: sent during the same kind of mid-flight tool call, it printed a transient `Initializing agent...` redraw but the tool call was NOT cancelled - it continued running and completed normally at its expected duration.
The only verified-safe redirect is typing new text and pressing Enter while busy: confirmed live twice, including once against a genuinely hung API-retry loop, where it printed `Operation interrupted: retrying API call after error...` / `[Interrupted - processing new message]` and the session picked up the new message cleanly without wedging.
This is a message-submission mechanic, not a key, and `../../../bin/fm-control-lib.sh`'s `fm_control_interrupt_key`/`send_interrupt_keys` contract has no shape for it - `do_exit`'s busy-agent path unconditionally interrupts before exiting, so wiring hermes into `fm_control_harness_supported` without a real interrupt mechanic would let that path attempt to deliver a key that either does nothing (Escape) or kills the session (Ctrl+C).
Landing a real text-submission interrupt path in `bin/fm-control.sh` is real, scoped follow-up work, not attempted here.

## quota-axi provider mapping: not established

`bin/fm-quota-choose.sh`'s `provider_for_harness` has no `hermes` entry, matching rovo: hermes routes to multiple distinct model families (this account observed OpenAI and Claude ids through a pooled GitHub Copilot credential) and no live evidence of how, or whether, `quota-axi` models that relationship was found.
`hermes` stays absent from that mapping so a `hermes` candidate in a quota-balanced dispatch array fails closed with `unknown harness: hermes` instead of being silently misjudged.

## Known gaps, flagged rather than silently worked around

- **`hermes hooks`/`--accept-hooks`** were not deep-dived; a turn-granularity or busy/idle-granularity structural signal may exist and would be a strictly better busy source than the rendered-tail fallback if confirmed.
- **`claude-sonnet-5` model-registry gap**: a model present in the account's own returned catalog (via the `model_not_available_for_integrator` error body) still failed with a *different* error (`model_not_supported`) when passed verbatim as `-m claude-sonnet-5`; it may need a provider-qualified form. Not blocking (this task's live verification used `gpt-4o`/`gpt-4.1`, both of which work verbatim), so left as a known gap rather than solved speculatively.
- **`hermes serve`/`/api/ws` JSON-RPC transport**: a materially better transport than tmux/`--cli` exists (`data/hermes-serve-verify/report.md`).
  `../../../bin/fm-hermes-ws.py`/`.sh` is a standalone client for it (session create/submit/status/history/steer/interrupt/close, both loopback-token and gated ticket auth), offline-verified against a from-scratch stub server (`tests/fm-hermes-ws.test.sh`) but NOT yet run against the real VPS or any real Hermes install - see `../../../../docs/verification/hermes.md`'s "standalone JSON-RPC-over-WebSocket dispatch client" section for the wire-protocol grounding and the two things (the captain's VPS credentials, an unconfirmed `Origin`-header requirement) still blocking that.
  It is a captain-approved standalone primitive only, deliberately not wired into `../../../bin/fm-spawn.sh`/`fm-control.sh`/`fm-crew-state.sh`/`fm-busy-lib.sh` - those are entirely pane-shaped and a `/api/ws` session has no pane; fleet-dispatch wiring is a deferred follow-up task.
