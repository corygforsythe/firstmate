# hermes-vps exportable-patch verification

## What was checked

1. **No captain-specific hardcoding in code/tests (functional contract).**
   `bin/fm-hermes-ws.py`'s header comment previously hardcoded the captain's
   real Tailscale hostname (`vps.tail8bdd14.ts.net`) as the
   `FM_HERMES_WS_BASE_URL` example. Target commit 3646ad0 replaces it with a
   generic placeholder (`http://your-vps-host:9119`). Confirmed via
   `git diff d407749..3646ad0`.

2. **The env-var contract actually works, including for a third party.**
   Ran `tests/fm-hermes-ws.test.sh` (offline, uses a local stub server, no
   real VPS/credentials needed) — 10/10 passing, including the test
   specifically pinning "fm-hermes-ws.sh fills missing env from
   $FM_HOME/.env, env still wins over it", which is the exact contract the
   user intent requires (FM_HERMES_WS_* read from $FM_HOME/.env, never argv).

3. **The patch series is real and mechanically exportable to another fork.**
   Generated the full hermes-vps body of work as a 24-part git patch series
   (`git format-patch b182d0f..3646ad0`, where b182d0f is the commit
   immediately preceding the first hermes commit). Patches saved alongside
   this file in `hermes-vps-patch-series/`.

   Applied that series with `git am --3way` onto a fresh detached checkout
   of b182d0f (simulating a stranger's fork with none of the captain's
   history) — all 24 patches applied cleanly, zero conflicts, zero fuzz.

4. **The exported code works with zero captain environment present.**
   In that fresh fork checkout, ran `tests/fm-hermes-ws.test.sh` with
   FM_HERMES_WS_BASE_URL/USER/PASS/TOKEN explicitly unset — all 10 tests
   still passed, since the suite only talks to a local stub server and
   sources its own synthetic credentials.

5. **Scanned the full patch series for leaked secrets.** grepped all 24
   patches for FM_HERMES_WS_PASS=/USER=/TOKEN= and for the captain's real
   hostname. Every credential-shaped hit was a test-fixture variable
   (`$STUB_TOKEN`, `$user`, `$pass`), never a literal secret.

## Residual finding

`docs/verification/hermes.md` (not touched by target commit 3646ad0) still
contains the captain's real VPS hostname (`vps.tail8bdd14.ts.net`) in
several places, as part of a historical live-verification log (real curl
output, timestamps, etc.). This is evidence of what was actually tested,
not setup instructions a new fork owner would copy — but the user intent
explicitly calls out "docs" as in scope for "nothing hardcoded to the
captain's specific environment," and this file ships as part of the same
body of work being handed to other forks. Left as an open question for the
author rather than auto-redacted, since scrubbing a verification log's real
values would also reduce its evidentiary value.

## Flaky test noted (pre-existing, unrelated to this change)

`tests/fm-hermes-vps-bridge.test.sh` failed intermittently on a different
subtest each run (timing-sensitive), reproduced identically both on the
target worktree directly and on the fork-simulation checkout with
byte-identical source. Not caused by the hostname-comment fix under test.
