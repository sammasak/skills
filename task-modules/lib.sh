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
  emit "$(jq -cn --arg k "$2" --arg m "$3" --argjson x "${4:-{\}}" '$x + {schema_version:1, error:{kind:$k, message:$m}}')"
  exit "$1"
}
# observe_error <kind> <message> <extra-json-object>: a completed observation whose
# subject failed (exit 0, so the DAG still carries the record downstream).
observe_error() { emit "$(jq -cn --arg k "$1" --arg m "$2" --argjson x "$3" --arg at "$(now_iso)" '$x + {schema_version:1, observed_at:$at, error:{kind:$k, message:$m}}')"; }
# upstream <task-name>: that task's output from $DEVENV_TASKS_OUTPUTS, or "null" when it did not complete.
upstream() { jq -c --arg t "$1" '.[$t] // null' <<<"${DEVENV_TASKS_OUTPUTS:-{\}}"; }
