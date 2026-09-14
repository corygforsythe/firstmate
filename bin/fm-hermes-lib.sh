#!/usr/bin/env bash
# Hermes Agent (the `hermes` CLI) process identity.
# Sourced by bin/fm-harness.sh and bin/fm-agent-process-lib.sh. This file is
# sourced by scripts and has no side effects on source.
#
# Why one owner: Hermes ships as a Python venv script, so a live hermes pane
# presents as the generic interpreter and nothing about its command NAME says
# hermes. Measured live on Hermes Agent v0.16.0 (2026.6.5) on macOS arm64, a
# `hermes --cli` pane's foreground process:
#
#   comm (short, `ps -c -o comm=`) : python3
#   comm (full,  `ps -o comm=`)    : /Users/<user>/.hermes/hermes-agent/venv/bin/python3
#   args (`ps -o args=`)           : .../hermes-agent/venv/bin/python3 .../hermes-agent/venv/bin/hermes --cli -m gpt-4o --provider copilot
#
# `comm` is always the interpreter (short or long form), and argv[0] is that
# same interpreter path. Only argv[1] - the script path - carries the
# identity, so the liveness classifier has to read the arguments rather than
# the name. This is the same hazard bin/fm-gemini-lib.sh exists to close for
# Gemini's node-bundle shape (interpreter argv[0], script argv[1]); this file
# is the direct python-interpreter analogue and deliberately mirrors its
# structure function-for-function.
#
# Hermes publishes no launch-time env marker comparable to rovo's
# ROVODEV_CLI=1 (checked against Hermes Agent v0.16.0's cli.py), so detection
# of a live hermes process depends entirely on this structural argv[1] check;
# there is no marker fast path to fall back on. See
# data/hermes-harness-verify/report.md and docs/verification/hermes.md for
# the live evidence this was built from.

# True when path $1 carries Hermes's own structural evidence: the file is
# named hermes (the `~/.local/bin/hermes` wrapper and the venv's own
# `.../hermes-agent/venv/bin/hermes` script both end in this exact
# component), or it sits inside the `hermes-agent` install tree. A directory
# component merely named `hermes` is never enough on its own (e.g. a stray
# `~/hermes/` workspace), and a bare interpreter is always rejected.
fm_hermes_path_is_hermes() {  # <path>
  local path=$1
  [ -n "$path" ] || return 1
  case "$path" in
    -*) return 1 ;;
  esac
  case "${path##*/}" in
    hermes) return 0 ;;
  esac
  case "$path" in
    */hermes-agent/*) return 0 ;;
  esac
  return 1
}

# True when process $1 has Hermes's structural argv evidence. Linux exposes
# argv as NUL-delimited fields, which preserves a script path containing
# spaces that `ps -o args=` necessarily flattens into an ambiguous string.
fm_hermes_pid_is_hermes() {  # <pid>
  local pid=$1 token argv0='' index=0
  [ -r "/proc/$pid/cmdline" ] || return 1
  while IFS= read -r -d '' token; do
    if [ "$index" -eq 0 ]; then
      argv0=$token
      fm_hermes_path_is_hermes "$argv0" && return 0
      case "${argv0##*/}" in
        python3|python3.*|python|Python) ;;
        *) return 1 ;;
      esac
    else
      case "$token" in
        -*) ;;
        *) fm_hermes_path_is_hermes "$token" && return 0; return 1 ;;
      esac
    fi
    index=$((index + 1))
  done < "/proc/$pid/cmdline"
  return 1
}

# True when the whitespace-separated command line $1 is a Hermes process.
#
# Accepted: a command whose own argv[0] is hermes (a future natively-named
# binary), and a python interpreter whose first non-flag argument is
# Hermes's own script or install-tree path.
#
# Rejected: a bare interpreter with no hermes argument, and any command line
# whose only mention of hermes is a later flag value, a working directory, or
# a prompt string - only argv[0] and the script argument are ever consulted,
# so an unrelated command that merely TALKS about hermes never matches.
fm_hermes_args_are_hermes() {  # <args>
  local args=$1 argv0 rest token
  [ -n "$args" ] || return 1
  args=${args#"${args%%[![:space:]]*}"}
  argv0=${args%%[[:space:]]*}
  fm_hermes_path_is_hermes "$argv0" && return 0
  case "${argv0##*/}" in
    python3|python3.*|python|Python) ;;
    *) return 1 ;;
  esac
  rest=${args#"$argv0"}
  # The first non-flag token after the interpreter is the script it runs.
  while [ -n "$rest" ]; do
    rest=${rest#"${rest%%[![:space:]]*}"}
    [ -n "$rest" ] || break
    token=${rest%%[[:space:]]*}
    rest=${rest#"$token"}
    case "$token" in
      -*) continue ;;
    esac
    fm_hermes_path_is_hermes "$token" && return 0
    return 1
  done
  return 1
}
