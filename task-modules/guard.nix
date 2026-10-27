# Role guard as devenv tasks (epic #16). The library is task-modules/guard-lib.nix. The settings-level dispatcher
# hook (hooks/role-guard-dispatch.sh, the one shell file Claude Code's hook contract requires) prefers a
# store-built binary of that library (nixos-config, ROLE_GUARD_BIN) and falls back to `guard:check` here, in which
# case the guard logic is the checkout's own and the checkout must be kept pulled. The same library drives the
# contract and negative suites in-process.
{ config, lib, ... }:
let
  cfg = config.coordinator;
  guardLib = import ./guard-lib.nix;
in
{
  options.coordinator.guardLib = lib.mkOption {
    type = lib.types.str;
    readOnly = true;
    default = guardLib;
    description = "Shell functions role_list_awk, integrity_check, _guard_inner and guard_check, shared by the guard tasks and the suites.";
  };

  config.tasks = {
    "guard:check" = {
      description = "Decide one Bash call for a role (fallback when no store-built guard is installed): input {role, hook, decision_file?} -> {decision: allow|ask|block, reason}; exit 0 whenever a decision was reached.";
      exec = ''
        ${cfg.prelude}
        ${guardLib}
        role=$(input .role); hook=$(jq -c '.hook // empty' <<<"''${DEVENV_TASK_INPUT:-{\}}"); df=$(input .decision_file)
        [ -n "$role" ] && [ -n "$hook" ] || fail 3 invalid_input "guard:check needs {role, hook}" '{"task":"guard:check"}'
        export COORDINATOR_CHECKOUT="''${COORDINATOR_CHECKOUT:-$DEVENV_ROOT}"
        dec=$(guard_check "$role" "$hook")
        [ -z "$df" ] || printf '%s\n' "$dec" > "$df"
        emit "$(jq -c --arg role "$role" '. + {schema_version:1, task:"guard:check", role:$role}' <<<"$dec")"
      '';
    };
    "guard:integrity" = {
      description = "Integrity predicate for a checkout: input {dir?, pin?, roles?} -> {intact, reason}; exit 1 when not intact.";
      exec = ''
        ${cfg.prelude}
        ${guardLib}
        dir=$(input .dir); [ -n "$dir" ] || dir="$DEVENV_ROOT"
        pin=$(input .pin); [ -n "$pin" ] || pin=-
        mapfile -t roles < <(jq -r '.roles[]? // empty' <<<"''${DEVENV_TASK_INPUT:-{\}}")
        if msg=$(integrity_check "$dir" "$pin" "''${roles[@]}" 2>&1); then emit '{"schema_version":1,"task":"guard:integrity","intact":true}'
        else emit "$(jq -cn --arg m "$msg" '{schema_version:1, task:"guard:integrity", intact:false, reason:$m}')"; exit 1; fi
      '';
    };
  };
}
