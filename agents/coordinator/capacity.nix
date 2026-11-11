# coord:capacity (sammasak/skills#28 W1): the developer environments on each environment host. An environment is
# declared in the host's nixos-config (sam.workers.instances.<name>) and exists only through a deploy; it shows in the
# host's Herdr as an agent named <name>. Read-only, from herdr:inventory, the audit log and, for each idle environment,
# the tail of its newest Claude transcript over ssh (context_tokens, for the /compact hint): no systemctl. The
# coordinator never creates or removes an environment; with none idle it reports the declaration and deploy to the owner.
{ lib, config, ... }:
let
  cfg = config.coordinator;
  hosts = builtins.fromJSON cfg.environmentHosts;
  suffixes = builtins.fromJSON cfg.environmentSsh;
  okHost = h: builtins.isString h && builtins.match "[A-Za-z0-9_.-]+" h != null;
  suffixJSON = lib.throwIfNot (lib.isAttrs suffixes && lib.all okHost (lib.attrValues suffixes))
    "coordinator.environmentSsh: a JSON object of host label to ssh domain suffix" (builtins.toJSON suffixes);
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

  options.coordinator.environmentSsh = lib.mkOption {
    type = lib.types.str;
    default = builtins.toJSON { acer-swift = "acer"; msi-ms7758 = "msi"; };
    description = "JSON object: environment host label to the ssh domain suffix that reaches its environments as <name>.<suffix> from the coordinator host.";
  };
  options.coordinator.compactTokens = lib.mkOption {
    type = lib.types.ints.positive;
    default = 150000;
    description = "Context size (tokens) at which an idle environment's hygiene advice becomes /compact.";
  };

  config.tasks."coord:capacity" = {
    description = "Read-only: per environment host (coordinator.environmentHosts) whether its Herdr answered and its developer environments (agents named after sam.workers.instances.<name>): name, agent_id, herdr_state, unavailable, last handoff, handoff_in_flight, available, and context_tokens (idle environments, read over ssh), and a /clear hint when next={repo,task_ref} is independent of its last handoff or a /compact hint when the context is at coordinator.compactTokens; a failed read is null and listed in failed_sources; never fails itself.";
    after = [ "herdr:inventory@completed" ];
    input = { next = null; };
    exec = ''
      ${cfg.prelude}
      inv=$(upstream "herdr:inventory")
      [ "$inv" != null ] || fail 2 missing "herdr:inventory produced no output" '{"task":"coord:capacity"}'
      next=$(jq -c 'if (.next | type) == "object" then .next | {repo:(.repo // null), task_ref:(.task_ref // null)} else null end' <<<"''${DEVENV_TASK_INPUT:-{\}}" 2>/dev/null) || next=null
      tmpd=$(mktemp -d); printf '%s\n' "$inv" > "$tmpd/inv.json"
      if [ -s "${cfg.stateDir}/audit.jsonl" ]; then jq -sc 'map(select(type == "object"))' "${cfg.stateDir}/audit.jsonl" > "$tmpd/audit.json" 2>/dev/null || echo '[]' > "$tmpd/audit.json"; else echo '[]' > "$tmpd/audit.json"; fi
      # context_tokens of each idle environment: the last assistant turn's input + cache tokens in the tail of its newest
      # transcript (the environment's own home, reached as <name>.<suffix>); a failed read stays null and is listed
      sfx=${lib.escapeShellArg suffixJSON}; : > "$tmpd/ctx.tsv"; : > "$tmpd/ctxerr.tsv"
      while IFS=$'\t' read -r h name; do
        s=$(jq -r --arg h "$h" '.[$h] // empty' <<<"$sfx")
        valid_machine "$name" && valid_machine "$s" || continue
        rc=0; tail=$(timeout -k 1 ${toString cfg.timeoutSeconds} ${cfg.sshCommand} -o BatchMode=yes -o ConnectTimeout=5 "$name.$s" \
          'f=$(ls -t "$HOME"/.claude/projects/-home-lukas/*.jsonl 2>/dev/null | head -n 1); [ -n "$f" ] && tail -n 400 "$f"' 9>&- </dev/null 2>/dev/null) || rc=$?
        tok=$(printf '%s\n' "$tail" | jq -Rs 'split("\n") | map(fromjson? | select(type == "object" and .type == "assistant" and (.message.usage | type) == "object") | .message.usage)
          | last | if . == null then "" else (.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0) end' -r 2>/dev/null)
        if [ "$rc" -eq 0 ] && [[ "$tok" =~ ^[0-9]+$ ]]; then printf '%s/%s\t%s\n' "$h" "$name" "$tok" >> "$tmpd/ctx.tsv"
        else printf '%s/%s\t%s\n' "$h" "$name" "ssh $name.$s transcript read: $([ "$rc" -ne 0 ] && echo "exit $rc" || echo "no usage found")" >> "$tmpd/ctxerr.tsv"; fi
      done < <(jq -r --argjson hosts ${lib.escapeShellArg hostsJSON} '.hosts[]? | select(.reachable == true and ((.host | ascii_downcase) as $n | $hosts | map(ascii_downcase) | index($n)))
        | .host as $h | (.agents // [])[] | select((.name | type) == "string" and (.observed_state == "idle" or .observed_state == "done")) | [$h, .name] | @tsv' "$tmpd/inv.json")
      jq -Rn '[inputs | split("\t") | {key:.[0], value:(.[1] | tonumber)}] | from_entries' "$tmpd/ctx.tsv" > "$tmpd/ctx.json"
      jq -Rn '[inputs | split("\t") | {source:("context:" + .[0]), error:.[1]}]' "$tmpd/ctxerr.tsv" > "$tmpd/ctxerr.json"
      rc=0; out=$(jq -nc --slurpfile inv "$tmpd/inv.json" --slurpfile ctx "$tmpd/ctx.json" --slurpfile ctxerr "$tmpd/ctxerr.json" --argjson threshold ${toString cfg.compactTokens} --slurpfile audit "$tmpd/audit.json" --argjson hosts ${lib.escapeShellArg hostsJSON} \
        --argjson next "''${next:-null}" --arg at "$(now_iso)" --argjson now "$(now_epoch)" -f ${./capacity.jq}) || rc=$?
      rm -rf "$tmpd"
      [ "$rc" -eq 0 ] || fail 2 internal "coord:capacity computation failed" '{"task":"coord:capacity"}'
      emit "$out"
    '';
  };
}
