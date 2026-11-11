# Worker pool and tiers (sammasak/skills#28 W1): coord:capacity reads, per host, how many workers there are, which
# are idle or busy, the heavy-job slots left and which assignment kinds fit, with a /clear or /compact hint per
# worker; coord:spawn starts one new Claude Code worker in its own Herdr workspace (`workspace create` +
# `agent start`), only for an owner-labelled item, only when that host's capacity allows, audit-logged like a send;
# on an nspawn host it starts an ephemeral worker container (its hook opens the claude in the host's Herdr), coord:reap stops one.
# No scheduler, queue or store: the fleet is herdr:inventory plus the container units, the history is audit.jsonl.
{ lib, config, ... }:
let
  cfg = config.coordinator;
  t = toString cfg.timeoutSeconds;
  # the per-host worker kind, checked at eval. "host": a claude in a pane of the host's own Herdr, limited by max_workers.
  # "nspawn": the host is no worker itself; its workers are its stock NixOS containers (containers.worker-<n>, ephemeral,
  # not running until started). slots lists them by name; starting container@<name> makes the host's hook open a Herdr
  # workspace labelled <name> with claude running inside the container, stopping it closes that workspace. Its worker
  # limit is the number of slots, so it takes no max_workers, and heavy_jobs may not exceed the slots.
  capFor = name: c:
    let
      w = c.worker or "host"; at = "coordinator.capacity.${name}";
      okSlot = s: builtins.isString s && builtins.match "[a-z0-9][a-z0-9-]{0,62}" s != null;
    in
    if w == "host" then
      lib.throwIf (c ? slots) "${at}: a host worker takes max_workers, not slots (slots are nspawn containers)" (c // { worker = "host"; })
    else if w == "nspawn" then
      lib.throwIfNot (builtins.isList (c.slots or null) && c.slots != [ ] && lib.all okSlot c.slots) "${at}: worker nspawn needs slots, a non-empty list of container names (\"worker-<n>\")"
        (lib.throwIf (c ? max_workers) "${at}: an nspawn host takes slots, not max_workers (its workers are its containers)"
          (lib.throwIfNot (lib.length (lib.unique c.slots) == lib.length c.slots) "${at}: a container is named twice in slots"
            (lib.throwIf ((c.heavy_jobs or 0) > lib.length c.slots) "${at}: heavy_jobs ${toString c.heavy_jobs} exceeds its ${toString (lib.length c.slots)} slots"
              (c // { max_workers = lib.length c.slots; slots = map (s: { container = s; unit = "container@${s}"; }) c.slots; }))))
    else throw "${at}: worker must be \"host\" or \"nspawn\", not ${builtins.toJSON w}";
  capJSON = builtins.toJSON (lib.mapAttrs capFor (builtins.fromJSON cfg.capacity));
  # nspawn workers over ssh (units) and the host's Herdr (their workspaces), shared by coord:capacity, coord:spawn, coord:reap
  workerFns = ''
    capj=${lib.escapeShellArg capJSON}
    ssh_at() { local tmo="$1"; shift; timeout -k 1 "$tmo" ${cfg.sshCommand} -o BatchMode=yes -o ConnectTimeout=5 "$@" 9>&-; }
    # slots_probe [host]: {"<host>": {reachable, error, units:{"<unit>": state}, workspaces:{"<label>": "<workspace_id>"}}}
    # for every nspawn host (or the one named): one `systemctl is-active` over ssh (it exits 3 when a unit is inactive;
    # ssh's own failure is 255) and one `workspace list` on the host's saved Herdr machine
    slots_probe() { local out='{}' h units raw rc wsl
      while IFS=$'\t' read -r h units; do
        [ -z "''${1:-}" ] || [ "''${h,,}" = "''${1,,}" ] || continue
        rc=0; raw=$(ssh_at ${t} "$h" systemctl is-active $units 2>/dev/null) || rc=$?
        if [ "$rc" -eq 255 ] || [ "$rc" -eq 124 ] || [ "$(grep -c . <<<"$raw")" -ne "$(wc -w <<<"$units")" ]; then
          out=$(jq -c --arg h "$h" --arg e "ssh $h systemctl is-active: exit $rc" '. + {($h): {reachable:false, error:$e, units:{}, workspaces:{}}}' <<<"$out"); continue
        fi
        wsl=$(herdr_at ${t} "$h" workspace list 2>/dev/null 9>&- | jq -c '[.result.workspaces[]? | select((.label | type) == "string" and (.workspace_id | type) == "string") | {key:.label, value:.workspace_id}] | from_entries' 2>/dev/null) || wsl='{}'
        out=$(jq -c --arg h "$h" --arg u "$units" --arg r "$raw" --argjson w "''${wsl:-{\}}" '($u | split(" ")) as $us | ($r | split("\n")) as $rs
          | . + {($h): {reachable:true, error:null, units:([range($us | length)] | map({key:$us[.], value:$rs[.]}) | from_entries), workspaces:$w}}' <<<"$out")
      done < <(jq -r 'to_entries[] | select(.value.worker == "nspawn") | [.key, (.value.slots | map(.unit) | join(" "))] | @tsv' <<<"$capj")
      printf '%s\n' "$out"; }
    # worker_agent <host> <container>: the agent list record of the claude in the container's workspace, or nothing
    worker_agent() { local wsid al
      wsid=$(herdr_at ${t} "$1" workspace list 2>/dev/null 9>&- | jq -r --arg l "$2" 'first(.result.workspaces[]? | select(.label == $l) | .workspace_id | strings) // empty' 2>/dev/null) || return 0
      [ -n "$wsid" ] || return 0
      al=$(herdr_at ${t} "$1" agent list 2>/dev/null 9>&-) || return 0
      jq -c --arg w "$wsid" 'first(.result.agents[]? | select(.workspace_id == $w and .agent == "claude")) // empty' <<<"$al" 2>/dev/null || true; }
    # worker_stop <host> <unit>: stop the unit (its hook closes the workspace, the container's contents are gone) and check
    worker_stop() { local st
      ssh_at 60 "$1" systemctl stop "$2" >/dev/null 2>&1 || true
      st=$(ssh_at ${t} "$1" systemctl is-active "$2" 2>/dev/null) || true
      jq -cn --arg s "$st" '{unit_stopped:($s == "inactive" or $s == "failed"), unit_state:(if $s == "" then null else $s end)}'; }
  '';
  # the shared capacity computation: herdr:inventory (upstream) + limits + the slot units + the audit log + context sizes
  capacity = ''
    ${workerFns}
    capacity_json() { # <next-json-or-null> [nousage] -> the coord:capacity record on stdout ($inv, $locks and $slots set)
      local tmpd; tmpd=$(mktemp -d)
      printf '%s\n' "$inv" > "$tmpd/inv.json"
      # the lock lanes per host (host:locks, upstream); absent when the observation did not run
      printf '%s\n' "''${locks:-null}" > "$tmpd/locks.json"
      printf '%s\n' "''${slots:-{\}}" > "$tmpd/slots.json"
      if [ -s "${cfg.stateDir}/audit.jsonl" ]; then jq -sc 'map(select(type == "object"))' "${cfg.stateDir}/audit.jsonl" > "$tmpd/audit.json" 2>/dev/null || echo '[]' > "$tmpd/audit.json"; else echo '[]' > "$tmpd/audit.json"; fi
      # context size of each idle local Claude session: the last assistant turn's input + cache tokens in its own JSONL
      # (remote session stores, nspawn workers' included, are not readable from here: their size stays null)
      : > "$tmpd/usage.jsonl"
      [ "''${2:-}" = nousage ] || while IFS=$'\t' read -r a sid cwd; do
        [[ "$sid" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] && [[ "$cwd" =~ ^/[A-Za-z0-9_./-]*$ ]] || continue
        f="${cfg.claudeProjectsDir}/$(printf '%s' "$cwd" | sed -E 's/[^A-Za-z0-9]/-/g')/$sid.jsonl"; [ -r "$f" ] || continue
        tail -n 400 "$f" | jq -Rc 'fromjson? // empty' 2>/dev/null | jq -sc --arg k "$(local_host)/$a" \
          '[.[] | select(type == "object" and .message.role? == "assistant" and (.message.usage | type) == "object") | .message.usage] | last
           | if . == null then empty else {($k): ((.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0))} end' >> "$tmpd/usage.jsonl" 2>/dev/null || true
      done < <(jq -r --arg h "$(local_host)" '.hosts[]? | select(.host == $h and .machine == null) | .agents[]? | select(.harness == "claude" and .session_id != null and .cwd != null) | [.agent_id, .session_id, .cwd] | @tsv' <<<"$inv")
      jq -sc 'add // {}' "$tmpd/usage.jsonl" > "$tmpd/usage.json"
      jq -nc --slurpfile inv "$tmpd/inv.json" --slurpfile audit "$tmpd/audit.json" --slurpfile usage "$tmpd/usage.json" --slurpfile locks "$tmpd/locks.json" --slurpfile slots "$tmpd/slots.json" \
        --argjson cap "$capj" --argjson kinds ${lib.escapeShellArg (builtins.toJSON cfg.kinds)} \
        --argjson next "$1" --argjson threshold ${toString cfg.hygieneContextTokens} --arg at "$(now_iso)" --argjson now "$(now_epoch)" -f ${./capacity.jq}
      local rc=$?; rm -rf "$tmpd"; return $rc; }
  '';
in
{
  imports = [ ../../task-modules/common.nix ];

  options.coordinator.capacity = lib.mkOption {
    type = lib.types.str;
    # lenovo is the control plane: no spawning and no heavy gates (nixos-config#109, two platform:verify runs killed at
    # 98 % swap). acer-swift and msi-ms7758 are no worker hosts themselves: their workers are ephemeral nspawn containers
    # (nixos-config modules/workers): acer one (6G), msi two (3584M each). msi is only up Mon-Fri 09:00-21:00 local.
    # A host not named here has no capacity and is refused.
    default = builtins.toJSON {
      "acer-swift" = { worker = "nspawn"; slots = [ "worker-1" ]; heavy_jobs = 1; spawn = true; heavy_gates = true; };
      "msi-ms7758" = { worker = "nspawn"; slots = [ "worker-1" "worker-2" ]; heavy_jobs = 1; spawn = true; heavy_gates = true; };
      "lenovo-21CB001PMX" = { worker = "host"; heavy_jobs = 1; max_workers = 2; spawn = false; heavy_gates = false; };
    };
    description = "JSON object: per host (its saved Herdr machine label, also its ssh name; matched case-insensitively) {worker, heavy_jobs, max_workers | slots, spawn, heavy_gates}. worker is \"host\" (default: a claude in the host's own Herdr, limited by max_workers) or \"nspawn\" (slots: the host's container names, e.g. [\"worker-1\"]; container@<name> starts one worker in a host Herdr workspace labelled <name>; limited by the slots, max_workers is rejected and heavy_jobs may not exceed them). heavy_gates defaults true; false refuses heavy-gate assignments (review, implementation) on that host and leaves it light work only (finding 6: lenovo is the control plane).";
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
  options.coordinator.workerBootSeconds = lib.mkOption {
    type = lib.types.ints.positive;
    default = 120;
    description = "How long coord:spawn waits, after starting an nspawn worker's unit, for an idle claude in its host Herdr workspace before it stops the unit again.";
  };
  options.coordinator.hygieneContextTokens = lib.mkOption {
    type = lib.types.ints.positive;
    default = 150000;
    description = "An idle worker whose context is at least this many tokens is flagged for /compact (or /clear when the next assignment is independent).";
  };

  config.tasks."coord:capacity" = {
    description = "Read-only worker pool: per host the workers (idle/busy/unknown), heavy-job slots and worker slots left (an nspawn host's slots in use are its active container units, asked over ssh), whether a light or heavy spawn is allowed, which assignment kinds fit a spawn or an idle worker, the nspawn workers ready to reap, and a /clear or /compact hint per idle worker (optional input next={repo,task_ref}); never fails itself.";
    after = [ "herdr:inventory@completed" "host:locks@completed" ];
    input = { next = null; };
    exec = ''
      ${cfg.prelude}
      ${capacity}
      inv=$(upstream "herdr:inventory"); locks=$(upstream "host:locks")
      [ "$inv" != null ] || fail 2 missing "herdr:inventory produced no output" '{"task":"coord:capacity"}'
      slots=$(slots_probe) || slots='{}'
      next=$(jq -c 'if (.next | type) == "object" then .next | {repo:(.repo // null), task_ref:(.task_ref // null)} else null end' <<<"''${DEVENV_TASK_INPUT:-{\}}" 2>/dev/null) || next=null
      out=$(capacity_json "''${next:-null}") || fail 2 internal "coord:capacity computation failed" '{"task":"coord:capacity"}'
      emit "$out"
    '';
  };

  config.tasks."coord:spawn" = {
    description = "ACT: start one Claude Code worker for an owner-labelled item (authorized_by) on a host (machine, or this one), refused (and audited) when the label is missing or the host's capacity does not allow it, never on a host whose spawn is off. On a worker = host host: a new Herdr workspace (cwd) with the kind's model. On a worker = nspawn host: starts the first free container unit over ssh and waits for the idle claude its hook opens in the host Herdr workspace named after the container (no cwd; model_applied false); any failure after the start stops the unit again.";
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
      worker=$(jq -r --arg h "$host" 'with_entries(.key |= ascii_downcase) | .[$h | ascii_downcase].worker // "host"' <<<"$capj")
      if [ "$worker" = nspawn ]; then
        # a fresh worker has an empty home: its claude starts there and the handoff tells it what to clone
        [ -z "$cwd" ] || fail 3 invalid_input "cwd is not accepted on $host: its workers are fresh containers that start in their home (the handoff names the repo to clone)" "$ctx"
        [ -n "$m" ] || fail 3 invalid_input "an nspawn host is reached as its saved machine: give machine" "$ctx"
      else # an absolute path only: herdr takes --cwd literally (no ~ expansion), on whichever host runs the pane
        [[ "$cwd" =~ ^/[A-Za-z0-9_./-]*$ ]] && [[ "$cwd" != *..* ]] || fail 3 invalid_input "cwd must be an absolute path with safe characters" "$ctx"
      fi
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
      # under the audit lock: the audit check, a fresh read of the target host's agents (or its slot units), the capacity
      # decision and the attempt line (which reserves the slot for an in-flight spawn); the lock is released before the
      # herdr and ssh calls and taken again only to append the outcome, so other acts never wait out a worker start
      exec 9>"$audit.lock"; flock -w 10 9 || fail 2 busy "another act (herdr:message, coord:spawn, gh:label, gh:comment) holds the audit lock" "$ctx"
      [ ! -s "$audit" ] || jq -n -e 'all(inputs; type == "object" and (.audit_id|type) == "string" and (.phase|type) == "string")' "$audit" >/dev/null 2>&1 \
        || fail 2 audit_corrupt "audit log is not valid JSON lines; refusing to spawn until the owner inspects $audit" "$ctx"
      aid=$(printf 'spawn|%s|%s|%s' "$host" "$(now_iso)" "$RANDOM$RANDOM" | sha256sum | cut -c1-12); attempted=false
      unit=""; slot=""; booted=false
      # the attempt line, then an outcome line on any exit. Outcomes are a closed set: started, refused, agent_not_ready,
      # failed, and interrupted when the task dies without one; herdr's own error code stays under error_code. A started
      # nspawn unit whose worker did not come up is stopped first, and the outcome says so under cleanup
      attempt() { "$attempted" && return 0; attempted=true
        jq -cn --arg a "$aid" --arg h "$host" --arg m "$m" --arg n "$name" --arg k "$kind" --arg mo "$model" --argjson hv "$heavy" --arg r "$ref" --arg c "$cwd" --arg at "$(now_iso)" --argjson auth "$auth" \
          --arg w "$worker" --arg s "$slot" --arg u "$unit" '{audit_id:$a, phase:"spawn", stage:"attempt", host:$h, machine:(if $m == "" then null else $m end), worker:$w, name:$n, kind:$k, model:$mo, heavy:$hv, task_ref:$r, cwd:(if $c == "" then null else $c end), at:$at, authorized_by:$auth}
            + (if $w == "nspawn" then {slot:(if $s == "" then null else $s end), unit:(if $u == "" then null else $u end)} else {} end)' >> "$audit" \
          || fail 2 audit_failed "could not write the spawn attempt; not spawning" "$ctx"
        outcome=interrupted; detail='{}'
        trap finish EXIT; }
      finish() {
        if "$booted" && [ "$outcome" != started ]; then
          detail=$(jq -c --argjson c "$(worker_stop "$host" "$unit")" '. + {cleanup:$c}' <<<"$detail" 2>/dev/null) || detail='{"cleanup":null}'; fi
        exec 9>>"$audit.lock"; flock -w 30 9 || true
        jq -cn --arg a "$aid" --arg at "$(now_iso)" --arg o "$outcome" --argjson d "$detail" '{audit_id:$a, phase:"outcome", at:$at, outcome:$o} + $d' >> "$audit"; }
      refuse() { attempt; outcome=refused; detail=$(jq -cn --arg k "$1" --arg msg "$2" '{reason:{kind:$k, message:$msg}}'); fail "''${3:-2}" "$1" "$2" "$(jq -c --arg a "$aid" '. + {audit_id:$a}' <<<"$ctx")"; }
      [ -z "$refusal" ] || refuse "$(jq -r .kind <<<"$refusal")" "$(jq -r .message <<<"$refusal")" "$(jq -r '.exit // 2' <<<"$refusal")"
      # a host configured with spawning off is refused on its configuration, before it has to be in the inventory (lenovo,
      # the control plane, is no saved machine on the worker it would be asked from)
      [ "$(jq -r --arg h "$host" 'with_entries(.key |= ascii_downcase) | .[$h | ascii_downcase] | if . == null then "unset" else (.spawn == true | tostring) end' <<<"$capj")" != false ] \
        || refuse capacity "no spawn on $host: spawning is off for this host (coordinator.capacity)"
      [ "$(jq -r --arg h "$host" 'any(.hosts[]?; (.host | ascii_downcase) == ($h | ascii_downcase))' <<<"$inv")" = true ] \
        || refuse host_unknown "host $host is not in the inventory (a saved herdr machine, or this host)"
      if [ "$worker" = nspawn ]; then
        # the slots in use are the units active now (asked under the lock) plus the spawns in flight (their attempt lines)
        slots=$(slots_probe "$host")
        [ "$(jq -r 'to_entries | first.value.reachable // false' <<<"$slots")" = true ] \
          || refuse host_unreachable "host $host did not answer over ssh ($(jq -r 'to_entries | first.value.error // "not probed"' <<<"$slots")); not spawning"
      else
        # the inventory is from before the lock: re-read this host's agents now, so two spawns never decide on one snapshot
        # (a spawn still in flight holds its slots through its attempt line, see capacity.jq)
        rc=0; fresh=$(herdr_at ${t} "$m" agent list 2>/dev/null 9>&-) || rc=$?
        [ "$rc" -eq 0 ] || refuse host_unreachable "host $host did not answer (herdr agent list exit $rc); not spawning"
        inv=$(jq -c --arg h "$host" --argjson f "$fresh" '.hosts |= map(if (.host | ascii_downcase) == ($h | ascii_downcase) then
                .agents = [$f.result.agents[]? | select(type == "object" and (.pane_id | type) == "string")
                           | {host:$h, agent_id:.pane_id, harness:(.agent // "unknown"), session_id:(.agent_session.value? // null), cwd:(.cwd // null), observed_state:(.agent_status // "unknown")}]
                | .reachable = true
              else . end)' <<<"$inv" 2>/dev/null) || refuse host_unreachable "host $host returned an unreadable agent list; not spawning"
      fi
      cap=$(capacity_json null nousage) || refuse internal "capacity could not be computed"
      hc=$(jq -c --arg h "$host" '[.hosts[] | select((.host | ascii_downcase) == ($h | ascii_downcase))] | first' <<<"$cap")
      [ "$hc" != null ] || refuse host_unknown "host $host is not in the inventory (a saved herdr machine, or this host)"
      [ "$(jq -r .reachable <<<"$hc")" = true ] || refuse host_unreachable "host $host did not answer; not spawning"
      if [ "$heavy" = true ]; then want=heavy; else want=light; fi
      [ "$(jq -r --arg w "$want" '.spawn_ok[$w]' <<<"$hc")" = true ] || refuse capacity "no $want spawn on $host: $(jq -r '.reasons | join("; ")' <<<"$hc")"
      if [ "$worker" = nspawn ]; then
        IFS=$'\t' read -r slot unit < <(jq -r '.free_slot | [.container, .unit] | @tsv' <<<"$hc") || true
        [ -n "$unit" ] || refuse capacity "no free worker slot on $host"
      fi
      attempt
      exec 9>&-
      errf=$(mktemp); rc=0
      if [ "$worker" = nspawn ]; then
        # start the container (polkit lets lukas start exactly these units); the host's hook opens a Herdr workspace
        # labelled after it with claude running inside. Ready when that claude is idle; from here every failure stops the unit
        booted=true
        ssh_at 60 "$host" systemctl start "$unit" >/dev/null 2>"$errf" || rc=$?
        if [ "$rc" -ne 0 ]; then
          outcome=failed; detail=$(jq -cn --arg e "$(head -c 300 "$errf" | tr -d '\000-\037')" --arg u "$unit" '{error_code:"unit_start_failed", error:("systemctl start " + $u + ": " + $e)}'); rm -f "$errf"
          fail 2 failed "could not start $unit on $host (exit $rc); it was stopped again" "$(jq -c --arg a "$aid" '. + {audit_id:$a}' <<<"$ctx")"; fi
        rm -f "$errf"; st=""; deadline=$(( $(now_epoch) + ${toString cfg.workerBootSeconds} ))
        while :; do
          st=$(worker_agent "$host" "$slot")
          [ -n "$st" ] && [ "$(jq -r '.agent_status // ""' <<<"$st")" = idle ] && break
          [ "$(now_epoch)" -lt "$deadline" ] || break
          sleep 2
        done
        if [ -z "$st" ] || [ "$(jq -r '.agent_status // ""' <<<"$st")" != idle ]; then
          if [ -z "$st" ]; then outcome=failed; code=worker_not_found; else outcome=agent_not_ready; code=agent_not_ready; fi
          detail=$(jq -cn --arg c "$code" --arg s "$(jq -r '.agent_status // "none"' <<<"''${st:-{\}}" 2>/dev/null)" '{error_code:$c, error:("no idle claude in workspace '"$slot"' within ${toString cfg.workerBootSeconds} s"), agent_status:$s}')
          fail 2 "$outcome" "worker $slot on $host did not become an idle claude within ${toString cfg.workerBootSeconds} s ($code); its unit was stopped again" "$(jq -c --arg a "$aid" '. + {audit_id:$a}' <<<"$ctx")"; fi
        pane=$(jq -r '.pane_id // empty' <<<"$st"); wsid=$(jq -r '.workspace_id // empty' <<<"$st")
        if ! valid_id "$pane" || ! valid_id "$wsid"; then
          outcome=failed; detail=$(jq -cn --arg p "$pane" '{error_code:"unsafe_id", error:"the worker agent has an unsafe pane id", returned_pane:($p | .[0:80])}')
          fail 2 failed "worker $slot on $host has an unsafe pane id; its unit was stopped again" "$ctx"; fi
        # the hook chooses the model; until it can read the kind's, the worker runs its default (model_applied false)
        detail=$(jq -cn --arg p "$pane" --arg w "$wsid" --arg s "$slot" --arg u "$unit" '{agent_id:$p, workspace_id:$w, worker:"nspawn", slot:$s, unit:$u, model_applied:false}')
        ses=$(jq -r '.agent_session.value // empty' <<<"$st" 2>/dev/null || true)
      else
        # spawn: a workspace of its own (never a split of the coordinator's pane), then the agent in its root pane
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
        detail=$(jq -cn --arg p "$pane" --arg w "$wsid" '{agent_id:$p, workspace_id:(if $w == "" then null else $w end), worker:"host", model_applied:true}')
        # --dangerously-skip-permissions runs unattended only where user settings carry skipDangerousModePermissionPrompt and
        # cwd's trust dialog was accepted (Home Manager pre-trusts $HOME only); elsewhere agent start says agent_not_ready
        st=$(herdr_at 70 "$m" agent start "$name" --kind claude --pane "$pane" --timeout 60000 -- --dangerously-skip-permissions --model "$model" 2>"$errf") || rc=$?
        code=$(jq -rs 'map(.error.code? // empty | strings) | first // empty' "$errf" 2>/dev/null | tr -cd 'A-Za-z0-9_' || true)
        if [ "$rc" -ne 0 ]; then
          if [ "$code" = agent_not_ready ]; then outcome=agent_not_ready; else outcome=failed; fi
          detail=$(jq -c --arg c "$code" --arg e "$(head -c 300 "$errf" | tr -d '\000-\037')" '. + {error_code:(if $c == "" then null else $c end), error:$e}' <<<"$detail"); rm -f "$errf"
          fail 2 "$outcome" "herdr agent start failed on $host/$pane (exit $rc''${code:+, $code}; the workspace stays for inspection)" "$(jq -c --arg a "$aid" --arg p "$pane" '. + {audit_id:$a, agent_id:$p}' <<<"$ctx")"; fi
        rm -f "$errf"
        ses=$(jq -r '.result.agent.agent_session.value // empty' <<<"$st" 2>/dev/null || true)
      fi
      outcome=started; detail=$(jq -c --arg s "$ses" --argjson auth "$auth" '. + {session_id:(if $s == "" then null else $s end), authorized_by:$auth}' <<<"$detail")
      emit "$(jq -cn --arg a "$aid" --arg h "$host" --arg m "$m" --arg n "$name" --arg k "$kind" --arg mo "$model" --argjson hv "$heavy" --arg r "$ref" --argjson d "$detail" \
        '{schema_version:1, task:"coord:spawn", audit_id:$a, host:$h, machine:(if $m == "" then null else $m end), name:$n, kind:$k, model:$mo, heavy:$hv, task_ref:$r, outcome:"started"} + $d + {error:null}')"
    '';
  };

  config.tasks."coord:reap" = {
    description = "ACT: end one nspawn worker by stopping its container unit (its host Herdr workspace closes, everything in it is gone), given machine=<host> and slot=<container>, or audit_id=<the coord:spawn that started it>; refused while its claude is working or blocked unless force=true; audited (phase reap). coord:capacity lists the workers ready for it under reapable.";
    input = { machine = null; slot = null; audit_id = null; force = false; };
    exec = ''
      ${cfg.prelude}
      ${workerFns}
      host=$(input .machine); slot=$(input .slot); said=$(input .audit_id); force=$(jq -r '.force == true' <<<"''${DEVENV_TASK_INPUT:-{\}}")
      ctx=$(jq -cn --arg h "$host" --arg s "$slot" --arg a "$said" '{task:"coord:reap", host:(if $h == "" then null else $h end), slot:(if $s == "" then null else $s end), spawn_audit_id:(if $a == "" then null else $a end)}')
      audit="${cfg.stateDir}/audit.jsonl"; mkdir -p "${cfg.stateDir}"; touch "$audit"
      if [ -n "$said" ]; then
        [[ "$said" =~ ^[a-f0-9]{12}$ ]] || fail 3 invalid_input "audit_id must be the 12-hex id of a coord:spawn" "$ctx"
        hs=$(jq -r --arg a "$said" 'select(type == "object" and .audit_id == $a and .phase == "spawn" and .worker == "nspawn" and (.slot | type) == "string") | [.host, .slot] | @tsv' "$audit" 2>/dev/null | tail -n 1)
        [ -n "$hs" ] || fail 3 invalid_input "no nspawn coord:spawn with audit_id $said in the audit log" "$ctx"
        IFS=$'\t' read -r h2 s2 <<<"$hs"
        { [ -z "$host" ] || [ "''${host,,}" = "''${h2,,}" ]; } && { [ -z "$slot" ] || [ "$slot" = "$s2" ]; } || fail 3 invalid_input "machine/slot is not what spawn $said started ($h2 $s2)" "$ctx"
        host="$h2"; slot="$s2"
      fi
      [ -n "$host" ] && [ -n "$slot" ] || fail 3 invalid_input "machine and slot (a container of an nspawn host in coordinator.capacity) or audit_id are required" "$ctx"
      valid_machine "$host" && valid_machine "$slot" || fail 3 invalid_input "machine or slot has unsafe characters" "$ctx"
      IFS=$'\t' read -r host unit < <(jq -r --arg h "$host" --arg s "$slot" 'to_entries[] | select(.value.worker == "nspawn" and (.key | ascii_downcase) == ($h | ascii_downcase)) | .key as $k | .value.slots[] | select(.container == $s) | [$k, .unit] | @tsv' <<<"$capj" | head -n 1) || true
      [ -n "''${unit:-}" ] || fail 3 invalid_input "$slot is not a worker slot of an nspawn host in coordinator.capacity" "$ctx"
      ctx=$(jq -c --arg h "$host" --arg s "$slot" --arg u "$unit" '. + {host:$h, slot:$s, unit:$u}' <<<"$ctx")
      aid=$(printf 'reap|%s|%s|%s|%s' "$host" "$slot" "$(now_iso)" "$RANDOM$RANDOM" | sha256sum | cut -c1-12)
      record() { # <outcome> <detail-json>: one audit line per reap
        exec 9>>"$audit.lock"; flock -w 30 9 || true
        jq -cn --arg a "$aid" --arg h "$host" --arg s "$slot" --arg u "$unit" --arg sa "$said" --arg at "$(now_iso)" --arg o "$1" --argjson f "$force" --argjson d "$2" \
          '{audit_id:$a, phase:"reap", host:$h, slot:$s, unit:$u, spawn_audit_id:(if $sa == "" then null else $sa end), at:$at, outcome:$o, forced:$f} + $d' >> "$audit"
        exec 9>&-; }
      # what runs there now: a working or blocked claude is not reaped without force
      st=$(worker_agent "$host" "$slot"); state=$(jq -r '.agent_status // "none"' <<<"''${st:-{\}}" 2>/dev/null || echo none)
      if [ "$force" != true ] && { [ "$state" = working ] || [ "$state" = blocked ]; }; then
        record refused "$(jq -cn --arg s "$state" '{agent_status:$s, reason:{kind:"busy", message:"its claude is working or blocked"}}')"
        fail 2 busy "$host/$slot has a $state claude; reap it after its handoff completes, or force=true" "$(jq -c --arg a "$aid" '. + {audit_id:$a}' <<<"$ctx")"
      fi
      res=$(worker_stop "$host" "$unit")
      if jq -e '.unit_stopped' <<<"$res" >/dev/null; then o=reaped; else o=failed; fi
      record "$o" "$(jq -c --arg s "$state" '{agent_status:$s} + .' <<<"$res")"
      out=$(jq -c --arg a "$aid" --arg o "$o" --argjson r "$res" '{schema_version:1} + . + {audit_id:$a, outcome:$o} + $r' <<<"$ctx")
      [ "$o" = reaped ] || fail 2 failed "$unit on $host did not stop: $(jq -c . <<<"$res")" "$out"
      emit "$(jq -c '. + {error:null}' <<<"$out")"
    '';
  };
}
