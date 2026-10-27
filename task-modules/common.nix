# Shared options and shell prelude for every coordinator/quality task (epic #16, herdr-native). Hosts are not
# configured here: the fleet IS herdr's saved machines (`herdr machine list --json`), and remote commands go
# through herdr's own forwarding (`herdr --machine <label> …`). A worker with no saved machines sees only itself.
{ lib, config, ... }:
let
  cfg = config.coordinator;
  t = lib.types;
  home = builtins.getEnv "HOME";
in
{
  options.coordinator = {
    herdrCommand = lib.mkOption { type = t.str; default = "herdr"; description = "Overridable for tests (fake herdr)."; };
    ghCommand = lib.mkOption { type = t.str; default = "gh"; description = "Overridable for tests (fake gh)."; };
    ghLimit = lib.mkOption { type = t.int; default = 20; };
    gitSince = lib.mkOption { type = t.str; default = "48 hours ago"; };
    stateDir = lib.mkOption {
      type = t.str;
      default = "${if builtins.getEnv "XDG_STATE_HOME" != "" then builtins.getEnv "XDG_STATE_HOME" else "${home}/.local/state"}/coordinator";
      description = "Drafts, audit log and the latest brief.";
    };
    timeoutSeconds = lib.mkOption { type = t.int; default = 8; description = "Bound for one herdr/gh/git call (remote machines included)."; };
    messageTimeoutSeconds = lib.mkOption { type = t.int; default = 20; description = "Bound for herdr agent prompt (submission incl. bracketed paste)."; };
    claudeProjectsDir = lib.mkOption { type = t.str; default = "$HOME/.claude/projects"; };
    piSessionsDir = lib.mkOption { type = t.str; default = "$HOME/.pi/agent/sessions"; };
    prelude = lib.mkOption { type = t.str; readOnly = true; default = ''
      set -uo pipefail
      # Exit codes (RFC 2026-10-26-agent-roles): 0 result (partial allowed), 2 nothing usable, 3 invalid input.
      now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
      now_epoch() { date -u +%s; }
      valid_id() { [[ "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9_:.@/-]*$ ]]; }
      valid_machine() { [[ "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]]; }
      input() { jq -r "$1 // empty" <<<"''${DEVENV_TASK_INPUT:-{\}}"; }
      emit() { printf '%s\n' "$1" | tee "''${DEVENV_TASK_OUTPUT_FILE:-/dev/null}"; }
      fail() { # <exit> <kind> <message> [extra-json-object]
        emit "$(jq -cn --arg k "$2" --arg m "$3" --argjson x "''${4:-{\}}" '{schema_version:1} + $x + {error:{kind:$k, message:$m}}')"
        exit "$1"
      }
      observe_error() { emit "$(jq -cn --arg k "$1" --arg m "$2" --argjson x "$3" --arg at "$(now_iso)" '{schema_version:1} + $x + {observed_at:$at, error:{kind:$k, message:$m}}')"; }
      rc_kind() { case "$1" in 124) echo timeout ;; *) echo command_failed ;; esac; }
      upstream() { jq -c --arg t "$1" '.[$t] // null' <<<"''${DEVENV_TASKS_OUTPUTS:-{\}}"; }
      local_host() { hostname -s 2>/dev/null || hostname; }
      # herdr_at <timeout_s> <machine-label-or-empty> <herdr args...>: the local server, or herdr's own forwarding to a saved machine
      herdr_at() { local tmo="$1" m="$2"; shift 2
        if [ -z "$m" ]; then timeout -k 1 "$tmo" ${cfg.herdrCommand} "$@"; else timeout -k 1 "$tmo" ${cfg.herdrCommand} --machine "$m" "$@"; fi; }
      # machines_json: {machines:[enabled saved machines], error:null|{kind,message}}; a failing herdr is data, never fatal
      machines_json() { local raw rc=0; raw=$(timeout -k 1 ${toString cfg.timeoutSeconds} ${cfg.herdrCommand} machine list --json 2>/dev/null) || rc=$?
        if [ "$rc" -ne 0 ]; then jq -cn --arg m "herdr machine list: $(rc_kind $rc) (exit $rc)" '{machines:[], error:{kind:"herdr_error", message:$m}}'; return 0; fi
        jq -c 'if type == "array" then {machines: map(select(type == "object" and .enabled == true and (.label|type) == "string")), error:null} else {machines:[], error:{kind:"malformed", message:"herdr machine list returned no JSON array"}} end' <<<"$raw" 2>/dev/null \
          || jq -cn '{machines:[], error:{kind:"malformed", message:"herdr machine list returned no JSON"}}'; }
    ''; };
  };
}
