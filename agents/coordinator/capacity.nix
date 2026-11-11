# coord:capacity (sammasak/skills#28 W1): the developer environments on each environment host. An environment is
# declared in the host's nixos-config (sam.workers.instances.<name>) and exists only through a deploy; it shows in the
# host's Herdr as an agent named <name>. Read-only, from herdr:inventory and the audit log: no ssh, no systemctl. The
# coordinator never creates or removes an environment; with none idle it reports the declaration and deploy to the owner.
{ lib, config, ... }:
let
  cfg = config.coordinator;
  hosts = builtins.fromJSON cfg.environmentHosts;
  okHost = h: builtins.isString h && builtins.match "[A-Za-z0-9_.-]+" h != null;
  hostsJSON = lib.throwIfNot (builtins.isList hosts && hosts != [ ] && lib.all okHost hosts)
    "coordinator.environmentHosts: a non-empty JSON list of saved Herdr machine labels" (builtins.toJSON hosts);
in
{
  imports = [ ../../task-modules/common.nix ];

  options.coordinator.environmentHosts = lib.mkOption {
    type = lib.types.str;
    # acer-swift (6G budget: one environment at the 3584M default) and msi-ms7758 (7G: two; up Mon-Fri 09:00-21:00
    # local only). lenovo is the control plane and has none.
    default = builtins.toJSON [ "acer-swift" "msi-ms7758" ];
    description = "JSON list of the hosts whose developer environments coord:capacity lists: each a saved Herdr machine label (matched case-insensitively).";
  };

  config.tasks."coord:capacity" = {
    description = "Read-only: per environment host (coordinator.environmentHosts) whether its Herdr answered and its developer environments (agents named after sam.workers.instances.<name>): name, agent_id, herdr_state, unavailable, last handoff, handoff_in_flight, available, and a /clear hint when next={repo,task_ref} is independent of its last handoff; never fails itself.";
    after = [ "herdr:inventory@completed" ];
    input = { next = null; };
    exec = ''
      ${cfg.prelude}
      inv=$(upstream "herdr:inventory")
      [ "$inv" != null ] || fail 2 missing "herdr:inventory produced no output" '{"task":"coord:capacity"}'
      next=$(jq -c 'if (.next | type) == "object" then .next | {repo:(.repo // null), task_ref:(.task_ref // null)} else null end' <<<"''${DEVENV_TASK_INPUT:-{\}}" 2>/dev/null) || next=null
      tmpd=$(mktemp -d); printf '%s\n' "$inv" > "$tmpd/inv.json"
      if [ -s "${cfg.stateDir}/audit.jsonl" ]; then jq -sc 'map(select(type == "object"))' "${cfg.stateDir}/audit.jsonl" > "$tmpd/audit.json" 2>/dev/null || echo '[]' > "$tmpd/audit.json"; else echo '[]' > "$tmpd/audit.json"; fi
      rc=0; out=$(jq -nc --slurpfile inv "$tmpd/inv.json" --slurpfile audit "$tmpd/audit.json" --argjson hosts ${lib.escapeShellArg hostsJSON} \
        --argjson next "''${next:-null}" --arg at "$(now_iso)" --argjson now "$(now_epoch)" -f ${./capacity.jq}) || rc=$?
      rm -rf "$tmpd"
      [ "$rc" -eq 0 ] || fail 2 internal "coord:capacity computation failed" '{"task":"coord:capacity"}'
      emit "$out"
    '';
  };
}
