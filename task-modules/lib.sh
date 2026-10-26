#!/usr/bin/env bash
# Shared helpers sourced by task execs. Exit codes (RFC 2026-10-26-agent-roles):
# 0 result (partial allowed), 2 nothing usable, 3 invalid input.
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now_epoch() { date -u +%s; }
valid_id() { [[ "$1" =~ ^[A-Za-z0-9_:.@/-]+$ ]]; }
input() { jq -r "$1 // empty" <<<"${DEVENV_TASK_INPUT:-{\}}"; }
# emit <json>: the task's output, to stdout and to devenv's output file.
emit() { printf '%s\n' "$1" | tee "${DEVENV_TASK_OUTPUT_FILE:-/dev/null}"; }
fail() { # <exit> <kind> <message> [extra-json-object]
  emit "$(jq -cn --arg k "$2" --arg m "$3" --argjson x "${4:-{\}}" '{schema_version:1} + $x + {error:{kind:$k, message:$m}}')"
  exit "$1"
}
# observe_error <kind> <message> <extra-json-object>: a completed observation whose
# subject failed (exit 0, so the DAG still carries the record downstream).
observe_error() { emit "$(jq -cn --arg k "$1" --arg m "$2" --argjson x "$3" --arg at "$(now_iso)" '{schema_version:1} + $x + {observed_at:$at, error:{kind:$k, message:$m}}')"; }
# run_on <timeout_s> <ssh-target-or-empty> <argv...>: run locally or over ssh with
# bounded time. ssh hands the remote shell ONE string, so every argv word is
# %q-quoted first; the remote shell then sees exactly the words given here.
run_on() {
  local t="$1" target="$2"; shift 2
  if [ -z "$target" ]; then timeout -k 1 "$t" "$@"
  else timeout -k 1 "$t" "${COORDINATOR_SSH:-ssh}" -o BatchMode=yes -o ConnectTimeout="$t" -o StrictHostKeyChecking=accept-new -- "$target" "$(printf '%q ' "$@")"; fi
}
# herdr_on <timeout_s> <ssh-target-or-empty> <herdr-args...>: the configured herdr
# binary locally (tests inject a fake), plain `herdr` on a remote host.
herdr_on() { local t="$1" target="$2"; shift 2; if [ -z "$target" ]; then run_on "$t" "" "${COORDINATOR_HERDR:-herdr}" "$@"; else run_on "$t" "$target" herdr "$@"; fi; }
# rc_kind <rc>: timeout | unreachable | command_failed
rc_kind() { case "$1" in 124) echo timeout ;; 255) echo unreachable ;; *) echo command_failed ;; esac; }
# upstream <task-name>: that task's output from $DEVENV_TASKS_OUTPUTS, or "null" when it did not complete.
upstream() { jq -c --arg t "$1" '.[$t] // null' <<<"${DEVENV_TASKS_OUTPUTS:-{\}}"; }
