# herdr:* tasks: live pane state over the installed herdr CLI (local or ssh <host> herdr ...).
# Inputs arrive as $DEVENV_TASK_INPUT JSON (override: devenv tasks run <task> --input-json '{...}').
{ lib, ... }:

let
  bin = toString ./bin;
  pending = import ./pending.nix;
in
{
  tasks = {
    "herdr:inventory" = {
      description = "Every agent on every fleet host (read-only, bounded, record schema v1).";
      input = { host = null; timeout_s = 8; max_age_s = 120; };
      exec = ''
        set -euo pipefail
        args=()
        host=$(jq -r '.host // empty' <<<"$DEVENV_TASK_INPUT"); [ -z "$host" ] || args+=(--host "$host")
        args+=(--timeout-s "$(jq -r '.timeout_s // 8' <<<"$DEVENV_TASK_INPUT")")
        args+=(--max-age-s "$(jq -r '.max_age_s // 120' <<<"$DEVENV_TASK_INPUT")")
        exec ${bin}/herdr-inventory "''${args[@]}"
      '';
    };
  } // lib.genAttrs [ "herdr:inspect" "herdr:message" "herdr:await" ] pending;
}
