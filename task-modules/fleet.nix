# Fleet configuration for the coordinator task graph. fleet.json is read at
# evaluation time so the graph contains exactly the configured hosts and repos;
# tests swap it with --option coordinator.fleetFile:path <fixture>.
{ lib, config, pkgs, ... }:

let
  cfg = config.coordinator;
  t = lib.types;
  idRe = "^[A-Za-z0-9_][A-Za-z0-9_:.@/-]*$";
  validId = s: builtins.match "[A-Za-z0-9_][A-Za-z0-9_:.@/-]*" s != null;
  validGh = s: builtins.match "[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+" s != null;
  validCheckout = s: builtins.match "/[A-Za-z0-9_./-]*" s != null;
  # A missing fleet file yields an empty graph (tests and fresh clones still evaluate); the launcher host renders one.
  raw = if builtins.pathExists cfg.fleetFile then builtins.fromJSON (builtins.readFile cfg.fleetFile) else { schema_version = 1; hosts = [ ]; repos = [ ]; };
  hosts = map (h: { name = h.name; ssh = h.ssh or null; }) (raw.hosts or [ ]);
  repos = map (r: { name = r.name; gh = r.gh or null; checkout = r.checkout or null; }) (raw.repos or [ ]);
  home = builtins.getEnv "HOME";
in
{
  options.coordinator = {
    fleetFile = lib.mkOption {
      type = t.path;
      default = "${if builtins.getEnv "XDG_CONFIG_HOME" != "" then builtins.getEnv "XDG_CONFIG_HOME" else "${home}/.config"}/coordinator/fleet.json";
      # devenv's eval cache does not track environment changes, so there is no env override: use --option coordinator.fleetFile:path.
      description = "Schema-1 fleet file: hosts (name, ssh|null) and repos (name, gh, checkout). An absent file is an empty fleet.";
    };
    stateDir = lib.mkOption {
      type = t.str;
      default = "${if builtins.getEnv "XDG_STATE_HOME" != "" then builtins.getEnv "XDG_STATE_HOME" else "${home}/.local/state"}/coordinator";
    };
    sshCommand = lib.mkOption { type = t.str; default = "ssh"; description = "Overridable for tests (fake ssh)."; };
    herdrCommand = lib.mkOption { type = t.str; default = "herdr"; description = "Overridable for tests (fake herdr)."; };
    timeoutSeconds = lib.mkOption { type = t.int; default = 8; };
    messageTimeoutSeconds = lib.mkOption { type = t.int; default = 20; description = "Bound for herdr agent prompt (submission incl. bracketed paste)."; };
    maxAgeSeconds = lib.mkOption { type = t.int; default = 120; description = "Snapshots older than this are not served for an unreachable host."; };
    hosts = lib.mkOption { type = t.listOf t.attrs; readOnly = true; default = hosts; };
    repos = lib.mkOption { type = t.listOf t.attrs; readOnly = true; default = repos; };
    # Shell fragments shared by every task exec: resolve $host to its ssh target
    # (empty = local) or fail with invalid_input; `prelude` defines the shared
    # helpers and points run_on at the configured ssh command.
    hostCase = lib.mkOption { type = t.str; readOnly = true; default = ''
      target=""
      case "$host" in
        ${lib.concatMapStringsSep "\n        " (h: ''${h.name}) target="${if h.ssh == null then "" else h.ssh}" ;;'') hosts}
        *) fail 3 invalid_input "host not in fleet: $host" "''${ctx:-{\}}" ;;
      esac
    ''; };
    prelude = lib.mkOption { type = t.str; readOnly = true; default = ''
      set -uo pipefail
      # Shared helpers sourced by task execs. Exit codes (RFC 2026-10-26-agent-roles):
      # 0 result (partial allowed), 2 nothing usable, 3 invalid input.
      now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
      now_epoch() { date -u +%s; }
      valid_id() { [[ "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9_:.@/-]*$ ]]; }
      input() { jq -r "$1 // empty" <<<"''${DEVENV_TASK_INPUT:-{\}}"; }
      # emit <json>: the task's output, to stdout and to devenv's output file.
      emit() { printf '%s\n' "$1" | tee "''${DEVENV_TASK_OUTPUT_FILE:-/dev/null}"; }
      fail() { # <exit> <kind> <message> [extra-json-object]
        emit "$(jq -cn --arg k "$2" --arg m "$3" --argjson x "''${4:-{\}}" '{schema_version:1} + $x + {error:{kind:$k, message:$m}}')"
        exit "$1"
      }
      # observe_error <kind> <message> <extra-json-object>: a completed observation whose
      # subject failed (exit 0, so the DAG still carries the record downstream).
      observe_error() { emit "$(jq -cn --arg k "$1" --arg m "$2" --argjson x "$3" --arg at "$(now_iso)" '{schema_version:1} + $x + {observed_at:$at, error:{kind:$k, message:$m}}')"; }
      # run_on <timeout_s> <ssh-target-or-empty> <argv...>: run locally or over ssh with
      # bounded time. Over ssh the argv travels as a base64 blob of NUL-separated words
      # that a remote bash turns back into argv with mapfile and exec: no shell ever
      # re-parses the words (quotes, newlines, $(..) in a handoff text stay literal),
      # and a worker's forced-command shim can check argv[0..2] before exec.
      REMOTE_RUNNER='mapfile -d "" a < <(printf %s "$1" | base64 -d); exec "''${a[@]}"'
      # COORDINATOR_SSH_IDENTITY (set by the nixos launcher) makes the dedicated key the only one offered: -F none
      # reads no ssh_config at all (a user `Host *` IdentityFile would otherwise be appended as a fallback and could
      # log in past the worker's herdr-shim), IdentitiesOnly keeps other agent keys out. Fleet targets must resolve
      # without ssh_config: a Host alias, User or ProxyJump defined only there is not honoured (shows as unreachable).
      run_on() {
        local t="$1" target="$2"; shift 2
        if [ -z "$target" ]; then timeout -k 1 "$t" "$@"
        else
          local b64; b64=$(printf '%s\0' "$@" | base64 -w0)
          local -a idopt=()
          [ -n "''${COORDINATOR_SSH_IDENTITY:-}" ] && idopt=(-F none -i "$COORDINATOR_SSH_IDENTITY" -o IdentitiesOnly=yes)
          timeout -k 1 "$t" "''${COORDINATOR_SSH:-ssh}" -o BatchMode=yes -o ConnectTimeout="$t" -o StrictHostKeyChecking=accept-new "''${idopt[@]}" -- "$target" "bash -c '$REMOTE_RUNNER' _ $b64"
        fi
      }
      # herdr_on <timeout_s> <ssh-target-or-empty> <herdr-args...>: the configured herdr
      # binary locally (tests inject a fake), plain `herdr` on a remote host.
      herdr_on() { local t="$1" target="$2"; shift 2; if [ -z "$target" ]; then run_on "$t" "" "''${COORDINATOR_HERDR:-herdr}" "$@"; else run_on "$t" "$target" herdr "$@"; fi; }
      # rc_kind <rc>: timeout | unreachable | command_failed
      rc_kind() { case "$1" in 124) echo timeout ;; 255) echo unreachable ;; *) echo command_failed ;; esac; }
      # upstream <task-name>: that task's output from $DEVENV_TASKS_OUTPUTS, or "null" when it did not complete.
      upstream() { jq -c --arg t "$1" '.[$t] // null' <<<"''${DEVENV_TASKS_OUTPUTS:-{\}}"; }
      export COORDINATOR_SSH=${cfg.sshCommand} COORDINATOR_HERDR=${cfg.herdrCommand}
    ''; };
  };

  config = {
    assertions = [
      { assertion = (raw.schema_version or 0) == 1; message = "coordinator: fleet.json schema_version must be 1"; }
      { assertion = lib.all (h: validId h.name && (h.ssh == null || validId h.ssh)) hosts; message = "coordinator: a host name or ssh target in fleet.json does not match ${idRe}"; }
      { assertion = lib.all (r: validId r.name && (r.gh == null || validGh r.gh) && (r.checkout == null || validCheckout r.checkout)) repos; message = "coordinator: a repo name, gh (OWNER/REPO) or absolute checkout in fleet.json has unsafe characters"; }
      { assertion = lib.length (lib.unique (map (h: h.name) hosts)) == lib.length hosts; message = "coordinator: duplicate host names in fleet.json"; }
    ];
    packages = [ pkgs.jq pkgs.coreutils ];
  };
}
