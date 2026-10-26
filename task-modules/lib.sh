#!/usr/bin/env bash
# Shared helpers for task-modules/bin/*. Source after `set -euo pipefail`.
# Exit codes (RFC 2026-10-26-agent-roles): 0 result, 2 nothing usable, 3 invalid input.

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now_epoch() { date -u +%s; }
die() { # <exit> <kind> <message>
  jq -cn --arg k "$2" --arg m "$3" '{schema_version:1,error:{kind:$k,message:$m}}'
  exit "$1"
}
valid_id() { [[ "$1" =~ ^[A-Za-z0-9_:.@/-]+$ ]]; }

state_dir() { echo "${COORDINATOR_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/coordinator}"; }

fleet_file() { echo "${1:-${COORDINATOR_FLEET:-${XDG_CONFIG_HOME:-$HOME/.config}/coordinator/fleet.json}}"; }

# load_fleet <file>: prints the fleet JSON after validating shape and identifiers.
load_fleet() {
  local f="$1" fleet
  [ -r "$f" ] || die 3 invalid_fleet "fleet file not readable: $f"
  fleet=$(jq -c . "$f" 2>/dev/null) || die 3 invalid_fleet "fleet file is not JSON: $f"
  [ "$(jq -r '.schema_version' <<<"$fleet")" = "1" ] || die 3 invalid_fleet "fleet schema_version must be 1"
  local n s
  while IFS=$'\t' read -r n s; do
    valid_id "$n" || die 3 invalid_fleet "host name rejected: $n"
    [ "$s" = "null" ] || valid_id "$s" || die 3 invalid_fleet "ssh target rejected for $n"
  done < <(jq -r '.hosts[] | [.name, (.ssh // "null")] | @tsv' <<<"$fleet")
  while IFS=$'\t' read -r n s; do
    valid_id "$n" || die 3 invalid_fleet "repo name rejected: $n"
    [[ "$s" =~ ^[A-Za-z0-9_./-]+$ ]] || die 3 invalid_fleet "checkout path rejected for $n"
  done < <(jq -r '.repos[]? | [.name, .checkout] | @tsv' <<<"$fleet")
  echo "$fleet"
}

# run_on_host <timeout_s> <ssh-target-or-null> <argv...>: runs argv locally or
# via ssh with argv passed as separate words. Prints stdout; returns
# 0 ok, 124 timeout, 255 unreachable, other = command's own exit.
run_on_host() {
  local t="$1" target="$2"; shift 2
  if [ "$target" = "null" ]; then
    timeout -k 1 "$t" "$@"
  else
    timeout -k 1 "$t" ssh -o BatchMode=yes -o ConnectTimeout="$t" -o StrictHostKeyChecking=accept-new "$target" "$@"
  fi
}
