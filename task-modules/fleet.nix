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
      default = if builtins.getEnv "COORDINATOR_FLEET" != "" then builtins.getEnv "COORDINATOR_FLEET"
                else "${if builtins.getEnv "XDG_CONFIG_HOME" != "" then builtins.getEnv "XDG_CONFIG_HOME" else "${home}/.config"}/coordinator/fleet.json";
      description = "Schema-1 fleet file: hosts (name, ssh|null) and repos (name, gh, checkout). Env COORDINATOR_FLEET overrides; absent file = empty fleet.";
    };
    stateDir = lib.mkOption {
      type = t.str;
      default = "${if builtins.getEnv "XDG_STATE_HOME" != "" then builtins.getEnv "XDG_STATE_HOME" else "${home}/.local/state"}/coordinator";
    };
    sshCommand = lib.mkOption { type = t.str; default = "ssh"; description = "Overridable for tests (fake ssh)."; };
    herdrCommand = lib.mkOption { type = t.str; default = "herdr"; description = "Overridable for tests (fake herdr)."; };
    timeoutSeconds = lib.mkOption { type = t.int; default = 8; };
    maxAgeSeconds = lib.mkOption { type = t.int; default = 120; description = "Snapshots older than this are not served for an unreachable host."; };
    hosts = lib.mkOption { type = t.listOf t.attrs; readOnly = true; default = hosts; };
    repos = lib.mkOption { type = t.listOf t.attrs; readOnly = true; default = repos; };
    lib = lib.mkOption { type = t.path; readOnly = true; default = ./lib.sh; };
    # Shell fragments shared by every task exec: resolve $host to its ssh target
    # (empty = local) or fail with invalid_input; `prelude` sources lib.sh and
    # points run_on at the configured ssh command.
    hostCase = lib.mkOption { type = t.str; readOnly = true; default = ''
      target=""
      case "$host" in
        ${lib.concatMapStringsSep "\n        " (h: ''${h.name}) target="${if h.ssh == null then "" else h.ssh}" ;;'') hosts}
        *) fail 3 invalid_input "host not in fleet: $host" ;;
      esac
    ''; };
    prelude = lib.mkOption { type = t.str; readOnly = true; default = ''
      set -uo pipefail
      . ${./lib.sh}
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
