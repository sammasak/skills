# Coordinator role DAG: work:status joins live Herdr state with durable GitHub/git
# evidence per agent; coord:brief renders it. Both depend on every source with
# @completed, so one failed source is reported as partial, never hidden.
{ lib, config, ... }:

let
  cfg = config.coordinator;
in
{
  imports = [ ../../task-modules/fleet.nix ];

  tasks = {
    "work:status" = {
      description = "Per-agent herdr_state + evidence-derived work_verdict; partial on failed sources.";
      after = [ "herdr:inventory@completed" "gh:work@completed" "git:recent@completed" ];
      exec = ''
        set -uo pipefail
        . ${cfg.lib}
        at=$(now_iso)
        inv=$(upstream "herdr:inventory"); gh=$(upstream "gh:work"); git=$(upstream "git:recent")
        out=$(jq -cn --arg at "$at" --argjson inv "$inv" --argjson gh "$gh" --argjson git "$git" '
          def failed(name; src): if src == null then [{source:name, error:{kind:"missing", message:"task produced no output"}}]
                                 else ((src.failed_sources // []) | map({source:(name + ":" + (.repo // .host // "?")), error}))
                                      + ((src.hosts // []) | map(select(.reachable == false) | {source:(name + ":" + .host), error})) end;
          ($gh.repos // [] | map(.prs[]) ) as $prs
          | ($gh.repos // [] | map(.issues[])) as $issues
          | ($git.repos // []) as $checkouts
          | def refnum: if . == null then null else (ltrimstr("#") | tonumber? // null) end;
          def evidence_for($ref): ($ref | refnum) as $n
            | if $n == null then {verdict:"unknown", refs:[], reasons:["no task reference (#N) on the agent"]}
              else ([$prs[] | select((.closes | index($n)) != null or (.title | test("#\($n)\\b")) or (.branch | test("\($n)")))]) as $ps
              | ([$issues[] | select(.number == $n)]) as $is
              | if any($ps[]; .merged_at != null) then {verdict:"verified", refs:[$ps[] | select(.merged_at != null) | .url], reasons:["merged PR closes or names #\($n)"]}
                elif any($ps[]; .state == "OPEN") then {verdict:"unverified", refs:[$ps[] | select(.state=="OPEN") | .url],
                       reasons:(["open PR for #\($n), not merged"] + [$ps[] | select(.state=="OPEN") | select(any(.checks[]?; . != "SUCCESS")) | "PR #\(.number) has non-green checks"])}
                elif ($is | length) > 0 then {verdict:"unverified", refs:[$is[].url], reasons:["issue #\($n) open, no PR found"]}
                else {verdict:"unknown", refs:[], reasons:["#\($n) not found in fleet repos"]} end end;
          {schema_version:1, task:"work:status", observed_at:$at,
           failed_sources: (failed("herdr:inventory"; $inv) + failed("gh:work"; $gh) + failed("git:recent"; $git)),
           items: [($inv.hosts // [])[] | .host as $h | .agents[] | . as $a
             | (evidence_for($a.task_ref)) as $e
             | ([$checkouts[] | select(.checkout == $a.cwd)] | first) as $co
             | {host:$h, agent_id:$a.agent_id, harness:$a.harness, session_id:$a.session_id, title:$a.title, task_ref:$a.task_ref,
                herdr_state:$a.observed_state, state_age_s:$a.state_age_s, stale:$a.stale, observed_at:$a.observed_at,
                work_verdict: (if $a.observed_state == "blocked" then "blocked" else $e.verdict end),
                needs_owner: ($a.observed_state == "blocked" or $a.approval_required == true),
                evidence_ref: ($e.refs | first // null),
                reasons: ($e.reasons + (if $co != null and $co.dirty_files > 0 then ["checkout has \($co.dirty_files) uncommitted file(s)"] else [] end)
                                     + (if $co != null and ($co.unpushed|length) > 0 then ["\($co.unpushed|length) unpushed commit(s)"] else [] end)
                                     + (if $a.stale then ["Herdr state is from a snapshot (\($a.snapshot_age_s // "?")s old)"] else [] end)),
                sources: ([{task:"herdr:inventory", observed_at:$a.observed_at}] + (if $gh != null then [{task:"gh:work", observed_at:$gh.observed_at}] else [] end)
                          + (if $git != null then [{task:"git:recent", observed_at:$git.observed_at}] else [] end))}]}
          | .partial = ((.failed_sources | length) > 0)')
        emit "$out"
        [ "$inv" != null ] || exit 2
      '';
    };

    "coord:brief" = {
      description = "Owner-facing brief: items needing input first, then every agent with herdr_state and work_verdict.";
      after = [ "work:status@completed" ];
      exec = ''
        set -uo pipefail
        . ${cfg.lib}
        ws=$(upstream "work:status")
        [ "$ws" != null ] || fail 2 missing "work:status produced no output" '{"task":"coord:brief"}'
        emit "$(jq -c '. + {task:"coord:brief"}' <<<"$ws")"
        jq -r '
          "# Fleet brief (\(.observed_at))",
          (if .partial then "", "**Partial:** " + ([.failed_sources[] | "\(.source): \(.error.kind) — \(.error.message)"] | join("; ")) else empty end),
          "", "## Needs you",
          (([.items[] | select(.needs_owner)] | if length == 0 then ["- nothing"] else map("- \(.host)/\(.agent_id) (\(.harness)) \(.task_ref // "no ref"): herdr=\(.herdr_state) → \(.reasons | join("; "))") end)[]),
          "", "## Agents",
          (if (.items|length) == 0 then "- none observed" else (.items[] | "- \(.host)/\(.agent_id) \(.harness) \(.task_ref // "-") | herdr=\(.herdr_state) (\(.state_age_s)s\(if .stale then ", stale" else "" end)) | work=\(.work_verdict)\(if .evidence_ref then " " + .evidence_ref else "" end)\(if (.reasons|length) > 0 then " | " + (.reasons | join("; ")) else "" end)") end)
        ' <<<"$ws" >&2
      '';
    };

    "coord:handoff" = import ../../task-modules/pending.nix "coord:handoff";
  };
}
