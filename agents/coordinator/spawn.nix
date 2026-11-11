# Worker pool and tiers (sammasak/skills#28 W1): coord:capacity reads, per host, how many workers there are, which
# are idle or busy, the heavy-job slots left and which assignment kinds fit, with a /clear or /compact hint per
# worker; coord:spawn starts one new Claude Code worker in its own Herdr workspace (`workspace create` +
# `agent start`), only for an owner-labelled item, only when that host's capacity allows, audit-logged like a send.
# No scheduler, queue or store: the fleet is herdr:inventory, the history is audit.jsonl.
{ lib, config, ... }:
let
  cfg = config.coordinator;
  t = toString cfg.timeoutSeconds;
  # the shared capacity computation: herdr:inventory (upstream) + limits + the audit log + local context sizes
  capacity = ''
    capacity_json() { # <next-json-or-null> -> the coord:capacity record on stdout
      local tmpd; tmpd=$(mktemp -d)
      printf '%s\n' "$inv" > "$tmpd/inv.json"
      # the lock lanes per host (host:locks, upstream); absent when the observation did not run
      printf '%s\n' "''${locks:-null}" > "$tmpd/locks.json"
      if [ -s "${cfg.stateDir}/audit.jsonl" ]; then jq -sc 'map(select(type == "object"))' "${cfg.stateDir}/audit.jsonl" > "$tmpd/audit.json" 2>/dev/null || echo '[]' > "$tmpd/audit.json"; else echo '[]' > "$tmpd/audit.json"; fi
      # context size of each idle local Claude session: the last assistant turn's input + cache tokens in its own JSONL
      # (remote session stores are not readable from here: their size stays null)
      : > "$tmpd/usage.jsonl"
      while IFS=$'\t' read -r a sid cwd; do
        [[ "$sid" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] && [[ "$cwd" =~ ^/[A-Za-z0-9_./-]*$ ]] || continue
        f="${cfg.claudeProjectsDir}/$(printf '%s' "$cwd" | sed -E 's/[^A-Za-z0-9]/-/g')/$sid.jsonl"; [ -r "$f" ] || continue
        tail -n 400 "$f" | jq -Rc 'fromjson? // empty' 2>/dev/null | jq -sc --arg k "$(local_host)/$a" \
          '[.[] | select(type == "object" and .message.role? == "assistant" and (.message.usage | type) == "object") | .message.usage] | last
           | if . == null then empty else {($k): ((.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0))} end' >> "$tmpd/usage.jsonl" 2>/dev/null || true
      done < <(jq -r --arg h "$(local_host)" '.hosts[]? | select(.host == $h and .machine == null) | .agents[]? | select(.harness == "claude" and .session_id != null and .cwd != null) | [.agent_id, .session_id, .cwd] | @tsv' <<<"$inv")
      jq -sc 'add // {}' "$tmpd/usage.jsonl" > "$tmpd/usage.json"
      jq -nc --slurpfile inv "$tmpd/inv.json" --slurpfile audit "$tmpd/audit.json" --slurpfile usage "$tmpd/usage.json" --slurpfile locks "$tmpd/locks.json" \
        --argjson cap ${lib.escapeShellArg cfg.capacity} --argjson kinds ${lib.escapeShellArg (builtins.toJSON cfg.kinds)} \
        --argjson next "$1" --argjson threshold ${toString cfg.hygieneContextTokens} --arg at "$(now_iso)" --argjson now "$(now_epoch)" -f ${./capacity.jq}
      local rc=$?; rm -rf "$tmpd"; return $rc; }
  '';
in
{
  imports = [ ../../task-modules/common.nix ];

  options.coordinator.capacity = lib.mkOption {
    type = lib.types.str;
    # lenovo is the control plane: no spawning and no heavy gates (nixos-config#109, two platform:verify runs killed at
    # 98 % swap); acer-swift is the worker (two heavy jobs). msi-ms7758 (8 cores, 15 GiB) is a smaller worker. Its
    # sam.agentRuntime.host.reserve (2 CPU / 8192 MiB) is capacity kept FREE of nspawn instances, not what they use, so
    # instances may take up to ~7 GiB; the headroom the host-side Herdr worker, a heavy gate and k3s share is UNMEASURED
    # (nixos-config says to measure it). One heavy job and two workers is a conservative proposal; no spawn
    # because sam.herdr.worker is deliberately off there (nixos-config: no bypass-permission launcher, no trustedDirs), and
    # it is only up Mon-Fri 09:00-21:00 local. A host not named here has no capacity and is refused.
    default = builtins.toJSON {
      "acer-swift" = { heavy_jobs = 2; max_workers = 3; spawn = true; heavy_gates = true; };
      "msi-ms7758" = { heavy_jobs = 1; max_workers = 2; spawn = false; heavy_gates = true; };
      "lenovo-21CB001PMX" = { heavy_jobs = 1; max_workers = 2; spawn = false; heavy_gates = false; };
    };
    description = "JSON object: per Herdr host label (matched case-insensitively) {heavy_jobs, max_workers, spawn, heavy_gates}. heavy_gates defaults true; false refuses heavy-gate assignments (review, implementation) on that host and leaves it light work only (finding 6: lenovo is the control plane).";
  };
  options.coordinator.kinds = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule { options = {
      tier = lib.mkOption { type = lib.types.enum [ "opus" "sonnet" "haiku" ]; };
      model = lib.mkOption { type = lib.types.str; };
      heavy = lib.mkOption { type = lib.types.bool; description = "Runs heavy gates (nix builds, cargo, full test suites)."; };
    }; });
    default = {
      planning = { tier = "opus"; model = "claude-opus-5-5"; heavy = false; };
      review = { tier = "opus"; model = "claude-opus-5-5"; heavy = true; };
      implementation = { tier = "sonnet"; model = "claude-sonnet-5-5"; heavy = true; };
      mechanical = { tier = "haiku"; model = "claude-haiku-5-5"; heavy = false; };
    };
    description = "Assignment kinds: the model tier each one runs on and whether it takes a heavy-job slot. coord:spawn takes the model from here, never from the caller.";
  };
  options.coordinator.hygieneContextTokens = lib.mkOption {
    type = lib.types.ints.positive;
    default = 150000;
    description = "An idle worker whose context is at least this many tokens is flagged for /compact (or /clear when the next assignment is independent).";
  };

  config.tasks."coord:capacity" = {
    description = "Read-only worker pool: per host the workers (idle/busy/unknown), heavy-job slots and worker slots left, whether a light or heavy spawn is allowed, which assignment kinds fit a spawn or an idle worker, and a /clear or /compact hint per idle worker (optional input next={repo,task_ref}); never fails itself.";
    after = [ "herdr:inventory@completed" "host:locks@completed" ];
    input = { next = null; };
    exec = ''
      ${cfg.prelude}
      ${capacity}
      inv=$(upstream "herdr:inventory"); locks=$(upstream "host:locks")
      [ "$inv" != null ] || fail 2 missing "herdr:inventory produced no output" '{"task":"coord:capacity"}'
      next=$(jq -c 'if (.next | type) == "object" then .next | {repo:(.repo // null), task_ref:(.task_ref // null)} else null end' <<<"''${DEVENV_TASK_INPUT:-{\}}" 2>/dev/null) || next=null
      out=$(capacity_json "''${next:-null}") || fail 2 internal "coord:capacity computation failed" '{"task":"coord:capacity"}'
      emit "$out"
    '';
  };

  config.tasks."coord:spawn" = {
    description = "ACT: start one Claude Code worker in a new Herdr workspace on a host (machine, or this one), for an owner-labelled item (authorized_by), with the model of its kind; refused (and audited) when the label is missing or the host's capacity does not allow it; never on a host whose spawn is off.";
    after = [ "herdr:inventory@completed" "host:locks@completed" ];
    input = { machine = null; kind = null; task_ref = null; cwd = null; authorized_by = null; };
    exec = ''
      ${cfg.prelude}
      ${capacity}
      m=$(input .machine); kind=$(input .kind); ref=$(input .task_ref); cwd=$(input .cwd)
      host=$([ -n "$m" ] && printf '%s' "$m" || local_host)
      auth=$(auth_shape "$(jq -c '.authorized_by // null' <<<"''${DEVENV_TASK_INPUT:-{\}}")")
      ctx=$(jq -cn --arg h "$host" --arg k "$kind" --arg r "$ref" '{task:"coord:spawn",host:$h,kind:$k,task_ref:$r}')
      kinds=${lib.escapeShellArg (builtins.toJSON cfg.kinds)}
      [ -z "$m" ] || valid_machine "$m" || fail 3 invalid_input "machine label has unsafe characters" "$ctx"
      model=$(jq -r --arg k "$kind" '.[$k].model // empty' <<<"$kinds"); heavy=$(jq -r --arg k "$kind" '.[$k].heavy // false' <<<"$kinds")
      [ -n "$model" ] || fail 3 invalid_input "kind must be one of: ${lib.concatStringsSep ", " (lib.attrNames cfg.kinds)}" "$ctx"
      [[ "$ref" =~ ^#([1-9][0-9]*)$ ]] || fail 3 invalid_input "task_ref must look like #N" "$ctx"
      num="''${BASH_REMATCH[1]}"; name="$kind-$num"
      # an absolute path only: herdr takes --cwd literally (no ~ expansion), on whichever host runs the pane
      [[ "$cwd" =~ ^/[A-Za-z0-9_./-]*$ ]] && [[ "$cwd" != *..* ]] || fail 3 invalid_input "cwd must be an absolute path with safe characters" "$ctx"
      [ -n "$auth" ] || fail 3 invalid_input "authorized_by is required: {\"issue_url\":\"https://github.com/OWNER/REPO/issues/N\",\"label\":\"<label the owner applied>\"}" "$ctx"
      inv=$(upstream "herdr:inventory"); locks=$(upstream "host:locks")
      [ "$inv" != null ] || fail 2 missing "herdr:inventory produced no output" "$ctx"
      audit="${cfg.stateDir}/audit.jsonl"; mkdir -p "${cfg.stateDir}"; touch "$audit"
      # the GitHub gate runs before the lock (as in herdr:message); its verdict is audited below either way. A spawn is
      # authorized only by the item it serves (the issue in issue_url is task_ref's) and only by a label the owner applied
      refusal=""
      if ! [[ "$(jq -r .issue_url <<<"$auth")" =~ /(issues|pull)/$num$ ]]; then
        refusal=$(jq -cn --arg u "$(jq -r .issue_url <<<"$auth")" --arg r "$ref" '{kind:"authorization_missing", message:("authorized_by.issue_url " + $u + " is not the item " + $r + "; a label authorizes only its own item")}')
      elif ! gh_authorize spawn spawning spawn; then
        refusal=$(jq -cn --arg k "$AUTH_KIND" --arg msg "$AUTH_MSG" --argjson x "$AUTH_EXIT" '{kind:$k, message:$msg, exit:$x}')
      elif [ "$(jq -r '.labeled_by // ""' <<<"$auth")" != ${lib.escapeShellArg cfg.ghOwner} ]; then
        refusal=$(jq -cn --arg l "$(jq -r .label <<<"$auth")" --arg b "$(jq -r '.labeled_by // "unknown"' <<<"$auth")" \
          '{kind:"authorization_missing", message:("label " + $l + " was applied by " + $b + ", not ${cfg.ghOwner}; only the owner'"'"'s label authorizes a spawn")}')
      fi
      # under the audit lock: the audit check, a fresh read of the target host's agents, the capacity decision and the
      # attempt line (which reserves the slot for an in-flight spawn); the lock is released before the herdr calls and
      # taken again only to append the outcome, so herdr:message and the gh acts never wait out a 60 s agent start
      exec 9>"$audit.lock"; flock -w 10 9 || fail 2 busy "another act (herdr:message, coord:spawn, gh:label, gh:comment) holds the audit lock" "$ctx"
      [ ! -s "$audit" ] || jq -n -e 'all(inputs; type == "object" and (.audit_id|type) == "string" and (.phase|type) == "string")' "$audit" >/dev/null 2>&1 \
        || fail 2 audit_corrupt "audit log is not valid JSON lines; refusing to spawn until the owner inspects $audit" "$ctx"
      aid=$(printf 'spawn|%s|%s|%s' "$host" "$(now_iso)" "$RANDOM$RANDOM" | sha256sum | cut -c1-12); attempted=false
      # the attempt line, then an outcome line on any exit. Outcomes are a closed set: started, refused, agent_not_ready,
      # failed, and interrupted when the task dies without one; herdr's own error code stays under error_code
      attempt() { "$attempted" && return 0; attempted=true
        jq -cn --arg a "$aid" --arg h "$host" --arg m "$m" --arg n "$name" --arg k "$kind" --arg mo "$model" --argjson hv "$heavy" --arg r "$ref" --arg c "$cwd" --arg at "$(now_iso)" --argjson auth "$auth" \
          '{audit_id:$a, phase:"spawn", stage:"attempt", host:$h, machine:(if $m == "" then null else $m end), name:$n, kind:$k, model:$mo, heavy:$hv, task_ref:$r, cwd:$c, at:$at, authorized_by:$auth}' >> "$audit" \
          || fail 2 audit_failed "could not write the spawn attempt; not spawning" "$ctx"
        outcome=interrupted; detail='{}'
        trap 'exec 9>>"$audit.lock"; flock -w 30 9 || true; jq -cn --arg a "$aid" --arg at "$(now_iso)" --arg o "$outcome" --argjson d "$detail" "{audit_id:\$a, phase:\"outcome\", at:\$at, outcome:\$o} + \$d" >> "$audit"' EXIT; }
      refuse() { attempt; outcome=refused; detail=$(jq -cn --arg k "$1" --arg msg "$2" '{reason:{kind:$k, message:$msg}}'); fail "''${3:-2}" "$1" "$2" "$(jq -c --arg a "$aid" '. + {audit_id:$a}' <<<"$ctx")"; }
      [ -z "$refusal" ] || refuse "$(jq -r .kind <<<"$refusal")" "$(jq -r .message <<<"$refusal")" "$(jq -r '.exit // 2' <<<"$refusal")"
      # a host configured with spawning off is refused on its configuration, before it has to be in the inventory (lenovo,
      # the control plane, is no saved machine on the worker it would be asked from)
      [ "$(jq -r --arg h "$host" 'with_entries(.key |= ascii_downcase) | .[$h | ascii_downcase] | if . == null then "unset" else (.spawn == true | tostring) end' <<<${lib.escapeShellArg cfg.capacity})" != false ] \
        || refuse capacity "no spawn on $host: spawning is off for this host (coordinator.capacity)"
      # the inventory is from before the lock: re-read this host's agents now, so two spawns never decide on one snapshot
      # (a spawn still in flight holds its slots through its attempt line, see capacity.jq)
      [ "$(jq -r --arg h "$host" 'any(.hosts[]?; (.host | ascii_downcase) == ($h | ascii_downcase))' <<<"$inv")" = true ] \
        || refuse host_unknown "host $host is not in the inventory (a saved herdr machine, or this host)"
      rc=0; fresh=$(herdr_at ${t} "$m" agent list 2>/dev/null 9>&-) || rc=$?
      [ "$rc" -eq 0 ] || refuse host_unreachable "host $host did not answer (herdr agent list exit $rc); not spawning"
      inv=$(jq -c --arg h "$host" --argjson f "$fresh" '.hosts |= map(if (.host | ascii_downcase) == ($h | ascii_downcase) then
              .agents = [$f.result.agents[]? | select(type == "object" and (.pane_id | type) == "string")
                         | {host:$h, agent_id:.pane_id, harness:(.agent // "unknown"), session_id:(.agent_session.value? // null), cwd:(.cwd // null), observed_state:(.agent_status // "unknown")}]
              | .reachable = true
            else . end)' <<<"$inv" 2>/dev/null) || refuse host_unreachable "host $host returned an unreadable agent list; not spawning"
      cap=$(capacity_json null) || refuse internal "capacity could not be computed"
      hc=$(jq -c --arg h "$host" '[.hosts[] | select((.host | ascii_downcase) == ($h | ascii_downcase))] | first' <<<"$cap")
      [ "$hc" != null ] || refuse host_unknown "host $host is not in the inventory (a saved herdr machine, or this host)"
      [ "$(jq -r .reachable <<<"$hc")" = true ] || refuse host_unreachable "host $host did not answer; not spawning"
      if [ "$heavy" = true ]; then want=heavy; else want=light; fi
      [ "$(jq -r --arg w "$want" '.spawn_ok[$w]' <<<"$hc")" = true ] || refuse capacity "no $want spawn on $host: $(jq -r '.reasons | join("; ")' <<<"$hc")"
      attempt
      exec 9>&-
      # spawn: a workspace of its own (never a split of the coordinator's pane), then the agent in its root pane
      errf=$(mktemp); rc=0
      ws=$(herdr_at ${t} "$m" workspace create --cwd "$cwd" --label "$name" --no-focus 2>"$errf") || rc=$?
      pane=$(jq -r '.result.root_pane.pane_id // .result.root_pane // empty | strings' <<<"$ws" 2>/dev/null || true)
      wsid=$(jq -r '.result.workspace.workspace_id // empty | strings' <<<"$ws" 2>/dev/null || true)
      if [ "$rc" -ne 0 ] || [ -z "$pane" ]; then
        outcome=failed; detail=$(jq -cn --arg e "$(head -c 300 "$errf" | tr -d '\000-\037')" '{error:("workspace create: " + $e)}'); rm -f "$errf"
        fail 2 herdr_error "herdr workspace create failed on $host (exit $rc)" "$ctx"; fi
      if ! valid_id "$pane" || { [ -n "$wsid" ] && ! valid_id "$wsid"; }; then
        outcome=failed; detail=$(jq -cn --arg p "$pane" '{error:"workspace create returned an unsafe pane id", returned_pane:($p | .[0:80])}'); rm -f "$errf"
        fail 2 herdr_error "herdr workspace create on $host returned an unsafe pane id; not starting an agent there" "$ctx"; fi
      rc=0
      # --dangerously-skip-permissions runs unattended only where user settings carry skipDangerousModePermissionPrompt and
      # cwd's trust dialog was accepted (Home Manager pre-trusts $HOME only); elsewhere agent start says agent_not_ready
      st=$(herdr_at 70 "$m" agent start "$name" --kind claude --pane "$pane" --timeout 60000 -- --dangerously-skip-permissions --model "$model" 2>"$errf") || rc=$?
      code=$(jq -rs 'map(.error.code? // empty | strings) | first // empty' "$errf" 2>/dev/null | tr -cd 'A-Za-z0-9_' || true)
      detail=$(jq -cn --arg p "$pane" --arg w "$wsid" '{agent_id:$p, workspace_id:(if $w == "" then null else $w end)}')
      if [ "$rc" -ne 0 ]; then
        if [ "$code" = agent_not_ready ]; then outcome=agent_not_ready; else outcome=failed; fi
        detail=$(jq -c --arg c "$code" --arg e "$(head -c 300 "$errf" | tr -d '\000-\037')" '. + {error_code:(if $c == "" then null else $c end), error:$e}' <<<"$detail"); rm -f "$errf"
        fail 2 "$outcome" "herdr agent start failed on $host/$pane (exit $rc''${code:+, $code}; the workspace stays for inspection)" "$(jq -c --arg a "$aid" --arg p "$pane" '. + {audit_id:$a, agent_id:$p}' <<<"$ctx")"; fi
      rm -f "$errf"
      ses=$(jq -r '.result.agent.agent_session.value // empty' <<<"$st" 2>/dev/null || true)
      outcome=started; detail=$(jq -c --arg s "$ses" --argjson auth "$auth" '. + {session_id:(if $s == "" then null else $s end), authorized_by:$auth}' <<<"$detail")
      emit "$(jq -cn --arg a "$aid" --arg h "$host" --arg m "$m" --arg n "$name" --arg k "$kind" --arg mo "$model" --argjson hv "$heavy" --arg r "$ref" --argjson d "$detail" \
        '{schema_version:1, task:"coord:spawn", audit_id:$a, host:$h, machine:(if $m == "" then null else $m end), name:$n, kind:$k, model:$mo, heavy:$hv, task_ref:$r, outcome:"started"} + $d + {error:null}')"
    '';
  };
}
