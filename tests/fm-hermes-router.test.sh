#!/usr/bin/env bash
# Behavior tests for bin/fm-hermes-router-lib.sh (the multi-host Hermes
# registry and capability-based host selection) and its wiring into
# bin/fm-spawn.sh's --hermes-capabilities flag.
#
# What is pinned here:
#   1. An absent or empty config/hermes-hosts.json resolves to the single
#      implicit "default" host, matching only an empty capability
#      requirement - the pre-registry single-host path stays byte-identical.
#   2. Capability selection matches by superset, refuses loudly when no host
#      qualifies, and reports (never silently resolves) a multi-match
#      tie-break.
#   3. Malformed registries (duplicate id, non-array capabilities) refuse
#      loudly rather than being parsed partially.
#   4. fm_hermes_router_write_host_env writes only a resolved host's set
#      fields, nothing for "default", and refuses an unregistered host id.
#   5. bin/fm-hermes-ws-env-lib.sh's generic fm_hermes_ws_load_env_file: a
#      resolved host's file wins over $FM_HOME/.env, matching the "first
#      setter wins" contract fm_hermes_ws_load_env already had.
#   6. fm-spawn.sh: --hermes-capabilities is refused for a non-hermes-vps
#      harness and combined with --relaunch; an unmet capability refuses the
#      spawn before any endpoint or task record exists; a real dispatch
#      through the router writes the launch command's --host-env-file, the
#      resolved host's connection values, and hermes_host= in task meta.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-hermes-router)
ROUTER_LIB="$ROOT/bin/fm-hermes-router-lib.sh"
ENV_LIB="$ROOT/bin/fm-hermes-ws-env-lib.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"

# shellcheck source=bin/fm-hermes-router-lib.sh
. "$ROUTER_LIB"

write_registry() {  # <fm-home> <json>
  mkdir -p "$1/config"
  printf '%s' "$2" > "$1/config/hermes-hosts.json"
}

# --- registry/selection: absent or empty --------------------------------

test_absent_registry_matches_only_empty_capabilities() {
  local home out status
  home="$TMP_ROOT/absent"
  mkdir -p "$home"

  out=$(fm_hermes_router_select "$home" "" 2>/dev/null) || fail "empty registry + no capabilities should select the implicit default host"
  [ "$out" = default ] || fail "expected 'default', got '$out'"

  fm_hermes_router_select "$home" "gpu" >/dev/null 2>/tmp/fm-hermes-router-err.$$
  status=$?
  [ "$status" -ne 0 ] || fail "empty registry + a required capability should refuse rather than silently match"
  assert_contains "$(cat /tmp/fm-hermes-router-err.$$)" "no Hermes host registry" "refusal did not explain the missing registry"
  rm -f /tmp/fm-hermes-router-err.$$

  [ "$(fm_hermes_router_hosts_json "$home")" = '[]' ] || fail "an absent registry did not resolve to an empty host list"

  pass "router: absent/empty registry keeps the single implicit host, matching only an empty capability requirement"
}

# --- registry/selection: capability matching -----------------------------

test_capability_selection_matches_superset_and_refuses_loudly() {
  local home out status err
  home="$TMP_ROOT/select"
  mkdir -p "$home"
  write_registry "$home" '[
    {"id":"vps","base_url":"http://vps:9119","token":"tok123","capabilities":[]},
    {"id":"gpu-box","base_url":"http://gpu:9119","user":"u","pass":"p","capabilities":["gpu","air-gapped"]}
  ]'

  out=$(fm_hermes_router_select "$home" "" 2>/dev/null) || fail "no capability requirement should still resolve a host"
  [ "$out" = vps ] || fail "expected the first-listed host 'vps' for an empty requirement, got '$out'"

  out=$(fm_hermes_router_select "$home" "gpu" 2>/dev/null) || fail "a single satisfiable capability should resolve"
  [ "$out" = gpu-box ] || fail "expected 'gpu-box' for capability [gpu], got '$out'"

  out=$(fm_hermes_router_select "$home" "gpu,air-gapped" 2>/dev/null) || fail "multiple satisfiable capabilities should resolve"
  [ "$out" = gpu-box ] || fail "expected 'gpu-box' for capabilities [gpu,air-gapped], got '$out'"

  err=$(fm_hermes_router_select "$home" "tpu" 2>&1 >/dev/null)
  status=$?
  [ "$status" -ne 0 ] || fail "an unsatisfiable capability should refuse rather than fall back to a mismatched host"
  assert_contains "$err" "no registered Hermes host carries every required capability" "the refusal did not name the unmet requirement"
  assert_contains "$err" "tpu" "the refusal did not name the missing capability"

  pass "router: capability selection matches by superset and refuses loudly on no match"
}

test_capability_selection_ties_pick_first_listed_and_say_so() {
  local home out err
  home="$TMP_ROOT/tie"
  mkdir -p "$home"
  write_registry "$home" '[
    {"id":"host-a","capabilities":["gpu"]},
    {"id":"host-b","capabilities":["gpu"]}
  ]'

  err=$(fm_hermes_router_select "$home" "gpu" 2>&1 >/tmp/fm-hermes-router-tie.$$)
  out=$(cat /tmp/fm-hermes-router-tie.$$)
  rm -f /tmp/fm-hermes-router-tie.$$
  [ "$out" = host-a ] || fail "a tie should deterministically pick the first-listed host, got '$out'"
  assert_contains "$err" "naive v1 tie-break" "a multi-match tie was not reported as a naive tie-break, not final policy"
  assert_contains "$err" "host-a" "the tie-break explanation did not name the chosen host"
  assert_contains "$err" "host-b" "the tie-break explanation did not name the other matching host"

  pass "router: a multi-host tie is reported, not silently resolved"
}

# --- registry: malformed input refuses loudly -----------------------------

test_malformed_registry_refuses_loudly() {
  local home err status
  home="$TMP_ROOT/malformed-dup"
  mkdir -p "$home"
  write_registry "$home" '[{"id":"a","capabilities":[]},{"id":"a","capabilities":[]}]'
  err=$(fm_hermes_router_hosts_json "$home" 2>&1 >/dev/null)
  status=$?
  [ "$status" -ne 0 ] || fail "a duplicate host id should refuse rather than silently pick one"
  assert_contains "$err" "duplicate host" "the duplicate-id refusal did not name the problem"

  home="$TMP_ROOT/malformed-caps"
  mkdir -p "$home"
  write_registry "$home" '[{"id":"a","capabilities":"gpu"}]'
  err=$(fm_hermes_router_hosts_json "$home" 2>&1 >/dev/null)
  status=$?
  [ "$status" -ne 0 ] || fail "a non-array capabilities field should refuse rather than being silently coerced"
  assert_contains "$err" "capabilities" "the malformed-capabilities refusal did not name the field"

  home="$TMP_ROOT/malformed-noid"
  mkdir -p "$home"
  write_registry "$home" '[{"capabilities":[]}]'
  err=$(fm_hermes_router_hosts_json "$home" 2>&1 >/dev/null)
  status=$?
  [ "$status" -ne 0 ] || fail "a host with no id should refuse rather than being silently skipped"

  pass "router: malformed registries (duplicate id, non-array capabilities, missing id) refuse loudly"
}

# --- write_host_env --------------------------------------------------------

test_write_host_env_writes_only_set_fields() {
  local home out
  home="$TMP_ROOT/writeenv"
  mkdir -p "$home"
  write_registry "$home" '[
    {"id":"vps","base_url":"http://vps:9119","token":"tok123","capabilities":[]},
    {"id":"gpu-box","base_url":"http://gpu:9119","user":"u","pass":"p","capabilities":["gpu"]}
  ]'

  fm_hermes_router_write_host_env "$home" default "$TMP_ROOT/writeenv-default" \
    || fail "writing the default host's env file should never fail"
  [ ! -s "$TMP_ROOT/writeenv-default" ] || fail "the 'default' implicit host should write an empty env file"

  fm_hermes_router_write_host_env "$home" vps "$TMP_ROOT/writeenv-vps" \
    || fail "writing a real host's env file should not fail"
  out=$(cat "$TMP_ROOT/writeenv-vps")
  assert_contains "$out" "FM_HERMES_WS_BASE_URL=http://vps:9119" "vps host env file missing base_url"
  assert_contains "$out" "FM_HERMES_WS_TOKEN=tok123" "vps host env file missing token"
  assert_not_contains "$out" "FM_HERMES_WS_USER" "vps host env file should not carry an unset field"

  fm_hermes_router_write_host_env "$home" gpu-box "$TMP_ROOT/writeenv-gpu" \
    || fail "writing the gpu-box host's env file should not fail"
  out=$(cat "$TMP_ROOT/writeenv-gpu")
  assert_contains "$out" "FM_HERMES_WS_USER=u" "gpu-box host env file missing user"
  assert_contains "$out" "FM_HERMES_WS_PASS=p" "gpu-box host env file missing pass"
  assert_not_contains "$out" "FM_HERMES_WS_TOKEN" "gpu-box host env file should not carry an unset field"

  if fm_hermes_router_write_host_env "$home" nope "$TMP_ROOT/writeenv-nope" 2>/dev/null; then
    fail "an unregistered host id should refuse rather than write an empty file silently"
  fi

  pass "router: write_host_env writes only a host's set fields, empty for 'default', refuses an unknown host"
}

test_host_present_backs_relaunch_continuity() {
  local home
  home="$TMP_ROOT/present"
  mkdir -p "$home"
  write_registry "$home" '[{"id":"vps","capabilities":[]}]'

  fm_hermes_router_host_present "$home" default || fail "'default' must always be present"
  fm_hermes_router_host_present "$home" vps || fail "a registered host must be present"
  ! fm_hermes_router_host_present "$home" gone 2>/dev/null || fail "a removed host must not read as present"

  pass "router: fm_hermes_router_host_present proves a recorded host is still registered before relaunch reuse"
}

# --- env-lib: resolved host wins over .env ---------------------------------

test_host_env_file_wins_over_home_env() {
  local home out
  home="$TMP_ROOT/envprecedence"
  mkdir -p "$home"
  printf 'FM_HERMES_WS_BASE_URL=http://home-env:9119\nFM_HERMES_WS_TOKEN=hometoken\n' > "$home/.env"
  printf 'FM_HERMES_WS_BASE_URL=http://resolved-host:9119\n' > "$TMP_ROOT/envprecedence-hostfile"

  out=$(env -i PATH="$PATH" bash -c '
    set -eu
    . "'"$ENV_LIB"'"
    fm_hermes_ws_load_env_file "'"$TMP_ROOT"'/envprecedence-hostfile"
    fm_hermes_ws_load_env "'"$home"'"
    printf "BASE_URL=%s\nTOKEN=%s\n" "$FM_HERMES_WS_BASE_URL" "$FM_HERMES_WS_TOKEN"
  ')
  assert_contains "$out" "BASE_URL=http://resolved-host:9119" "the resolved host's base_url did not win over .env"
  assert_contains "$out" "TOKEN=hometoken" ".env should still fill a field the host file left unset"

  out=$(env -i PATH="$PATH" bash -c '
    set -eu
    . "'"$ENV_LIB"'"
    fm_hermes_ws_load_env "'"$home"'"
    printf "BASE_URL=%s\n" "$FM_HERMES_WS_BASE_URL"
  ')
  assert_contains "$out" "BASE_URL=http://home-env:9119" "the legacy single-call .env-only path changed behavior"

  pass "env-lib: a resolved host's file wins over \$FM_HOME/.env, and the legacy single-call path is unchanged"
}

# --- fm-spawn.sh wiring ------------------------------------------------------

# A fake tmux that always refuses window creation, so a case that clears the
# router/flag checks still creates no endpoint. Refusals under test here all
# happen before any window would be created.
make_refusing_home() {  # <name>
  local name=$1 home fakebin proj
  home="$TMP_ROOT/$name/home"
  proj="$TMP_ROOT/$name/project"
  fakebin="$TMP_ROOT/$name/bin"
  mkdir -p "$home/data" "$home/state" "$home/config" "$proj" "$fakebin"
  git -C "$proj" init -q || fail "could not initialize project fixture"
  printf '#!/bin/sh\nexit 1\n' > "$fakebin/tmux"
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$home|$proj|$fakebin"
}

write_hermes_vps_brief() {  # <home> <id>
  local home=$1 id=$2
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<'EOF'
You are a crewmate.

# Task
## Captain's intent
Exercise the multi-host router wiring.

## Firstmate spec
Verify capability-based host selection.

# Setup
Harness contract: harness=hermes-vps

# Definition of done
EOF
}

run_spawn_refusing() {  # <home> <fakebin> <spawn-args...>
  local home=$1 fakebin=$2
  shift 2
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/projects-unused" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

test_hermes_capabilities_refused_for_other_harnesses() {
  local rec home proj fakebin out status
  rec=$(make_refusing_home wrong-harness)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  mkdir -p "$home/data/wrong-harness-1"
  printf 'brief\n' > "$home/data/wrong-harness-1/brief.md"

  out=$(run_spawn_refusing "$home" "$fakebin" wrong-harness-1 "$proj" --scout --harness claude --hermes-capabilities gpu)
  status=$?
  [ "$status" -ne 0 ] || fail "--hermes-capabilities on a non-hermes-vps harness should refuse"
  assert_contains "$out" "applies only to harness=hermes-vps" "the refusal did not explain the harness restriction"
  assert_absent "$home/state/wrong-harness-1.meta" "a refused spawn wrote task metadata"

  pass "fm-spawn: --hermes-capabilities is refused for a resolved harness other than hermes-vps"
}

test_hermes_capabilities_refused_on_relaunch() {
  local rec home proj fakebin out status
  rec=$(make_refusing_home relaunch-refuse)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF

  out=$(run_spawn_refusing "$home" "$fakebin" no-such-task --relaunch --hermes-capabilities gpu)
  status=$?
  [ "$status" -ne 0 ] || fail "--hermes-capabilities combined with --relaunch should refuse"
  assert_contains "$out" "cannot override it" "the relaunch refusal did not name the recorded-host contract"

  pass "fm-spawn: --hermes-capabilities is refused together with --relaunch"
}

test_unmet_capability_refuses_before_any_endpoint() {
  local rec home proj fakebin out status
  rec=$(make_refusing_home unmet-cap)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  write_registry "$home" '[{"id":"vps","base_url":"http://vps:9119","capabilities":[]}]'
  write_hermes_vps_brief "$home" unmet-cap-1

  out=$(run_spawn_refusing "$home" "$fakebin" unmet-cap-1 "$proj" --scout --harness hermes-vps --hermes-capabilities gpu)
  status=$?
  [ "$status" -ne 0 ] || fail "an unmet capability requirement should refuse the spawn"
  assert_contains "$out" "no registered Hermes host carries every required capability" "the spawn refusal did not surface the router's own explanation"
  assert_absent "$home/state/unmet-cap-1.meta" "a router-refused spawn wrote task metadata"

  pass "fm-spawn: a capability no registered host carries refuses before any endpoint or task record exists"
}

# A fake tmux that supports capture-pane with a fixed pane transcript
# already carrying the bridge's readiness banner and delivery bullet, so a
# real hermes-vps launch completes end to end without a live bridge process.
# Window creation and send-keys succeed and (when FM_FAKE_LAUNCH_LOG is set)
# log literal payloads, exactly like fm_test_fake_tmux_spawn.
make_ready_hermes_vps_fakebin() {  # <dir> <session-id>
  local dir=$1 sid=$2 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
case "\$*" in
  *"#{pane_current_path}"*) printf '%s\n' "\${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "\${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window|set-window-option) exit 0 ;;
  capture-pane)
    printf 'Hermes VPS bridge ready. session_id=$sid\n'
    printf '\xe2\x97\x8f Read the brief at /some/path and follow it exactly.\n'
    exit 0
    ;;
  send-keys)
    if [ -n "\${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "\$@"; do
        if [ "\$prev" = "-l" ]; then
          printf '%s\n' "\$a" >> "\$FM_FAKE_LAUNCH_LOG"
        fi
        prev=\$a
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

test_hermes_vps_dispatch_wires_router_end_to_end() {
  local home proj wt fakebin launchlog out status meta hostenv
  home="$TMP_ROOT/e2e/home"
  proj="$TMP_ROOT/e2e/project"
  wt="$TMP_ROOT/e2e/wt"
  launchlog="$TMP_ROOT/e2e/launch.log"
  fm_test_spawn_home "$home"
  fm_git_worktree "$proj" "$wt" "wt-e2e"
  write_hermes_vps_brief "$home" hermes-e2e-1
  write_registry "$home" '[
    {"id":"vps","base_url":"http://vps:9119","token":"tok123","capabilities":[]},
    {"id":"gpu-box","base_url":"http://gpu:9119","capabilities":["gpu"]}
  ]'
  fakebin=$(make_ready_hermes_vps_fakebin "$TMP_ROOT/e2e/fake" test-session-42)
  : > "$launchlog"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/e2e/projects-unused" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux PATH="$fakebin:$PATH" \
    FM_FAKE_LAUNCH_LOG="$launchlog" FM_FAKE_PANE_PATH="$wt" \
    "$SPAWN" hermes-e2e-1 "$proj" --scout --harness hermes-vps --hermes-capabilities gpu 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "a satisfiable capability request should launch successfully, got: $out"

  hostenv="$home/state/hermes-e2e-1.hermes-host-env"
  assert_present "$hostenv" "no per-task host env file was written"
  assert_grep "FM_HERMES_WS_BASE_URL=http://gpu:9119" "$hostenv" "the host env file did not carry the resolved gpu-box host's base_url"

  assert_present "$launchlog" "no launch command was captured"
  assert_grep "--host-env-file '$hostenv'" "$launchlog" "the launch command did not pass --host-env-file for the resolved host"

  meta="$home/state/hermes-e2e-1.meta"
  assert_present "$meta" "a successful spawn left no task record"
  assert_grep "hermes_host=gpu-box" "$meta" "task metadata did not record the resolved Hermes host"

  pass "fm-spawn: a satisfiable --hermes-capabilities dispatch writes the resolved host's connection file, wires it into the launch command, and records hermes_host= in task metadata"
}

test_absent_registry_matches_only_empty_capabilities
test_capability_selection_matches_superset_and_refuses_loudly
test_capability_selection_ties_pick_first_listed_and_say_so
test_malformed_registry_refuses_loudly
test_write_host_env_writes_only_set_fields
test_host_present_backs_relaunch_continuity
test_host_env_file_wins_over_home_env
test_hermes_capabilities_refused_for_other_harnesses
test_hermes_capabilities_refused_on_relaunch
test_unmet_capability_refuses_before_any_endpoint
test_hermes_vps_dispatch_wires_router_end_to_end
