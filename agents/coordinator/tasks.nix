# Coordinator role DAG: work:status joins live Herdr state (this host + saved machines) with GitHub
# evidence for agents whose title names OWNER/REPO#N; coord:brief renders it. Failed sources are
# reported as partial, never hidden.
{ lib, config, ... }:

let
  cfg = config.coordinator;
in
{
  imports = [ ../../task-modules/common.nix ];

  tasks = {
    "work:status" = {
      description = "Per-agent herdr_state + evidence-derived work_verdict: when an agent's title names OWNER/REPO and #N, gh is asked about that PR/issue; partial on failed sources, never fails itself.";
      after = [ "herdr:inventory@completed" ];
      exec = ''
        ${cfg.prelude}
        at=$(now_iso)
        inv=$(upstream "herdr:inventory")
        [ "$inv" != null ] || fail 2 missing "herdr:inventory produced no output" '{"task":"work:status"}'
        # evidence per (repo, #N) named in a title: one bounded gh query each, cached for this run
        declare -A EV=()
        evidence() { # <owner/repo> <N> -> json {verdict, refs, reasons}
          local key="$1#$2"; [ -n "''${EV[$key]:-}" ] && { printf '%s' "''${EV[$key]}"; return; }
          local prs issues rc=0 out
          prs=$(timeout -k 1 ${toString cfg.timeoutSeconds} ${cfg.ghCommand} pr list -R "$1" --state all --search "$2" --limit ${toString cfg.ghLimit} --json number,title,state,mergedAt,url,closingIssuesReferences,statusCheckRollup 2>/dev/null) || rc=$?
          issues=$(timeout -k 1 ${toString cfg.timeoutSeconds} ${cfg.ghCommand} issue list -R "$1" --state open --limit ${toString cfg.ghLimit} --json number,url 2>/dev/null) || rc=$?
          if [ "$rc" -ne 0 ]; then out='{"verdict":"unknown","refs":[],"reasons":["GitHub evidence unavailable (gh exited '"$rc"')"]}'
          else out=$(jq -cn --argjson p "$prs" --argjson i "$issues" --argjson n "$2" --arg repo "$1" '
            ([$p[] | select(((.closingIssuesReferences // []) | map(.number) | index($n)) != null or ((.title // "") | test("(^|[^0-9])#\($n)([^0-9]|$)")))]) as $ps
            | ([$i[] | select(.number == $n)]) as $is
            | (any($ps[]; .mergedAt != null)) as $merged | (any($ps[]; .state == "OPEN")) as $open
            | if $merged and ($open | not) and ($is | length) == 0 then {verdict:"verified", refs:[$ps[] | select(.mergedAt != null) | .url], reasons:["merged PR closes #\($n) in \($repo), no open issue or PR left"]}
              elif $merged and ($open | not) then {verdict:"unverified", refs:[$ps[] | select(.mergedAt != null) | .url], reasons:["merged PR names #\($n) but issue #\($n) is still open in \($repo)"]}
              elif $open then {verdict:"unverified", refs:[$ps[] | select(.state=="OPEN") | .url], reasons:(["open PR for #\($n) in \($repo), not merged"] + [$ps[] | select(.state=="OPEN") | select(any((.statusCheckRollup // [])[]; (.conclusion // .state // "") != "SUCCESS")) | "PR #\(.number) has non-green checks"])}
              elif ($is | length) > 0 then {verdict:"unverified", refs:[$is[].url], reasons:["issue #\($n) open in \($repo), no PR found"]}
              else {verdict:"unknown", refs:[], reasons:["#\($n) not found in \($repo)"]} end' 2>/dev/null) || out='{"verdict":"unknown","refs":[],"reasons":["gh returned unexpected JSON"]}'
          fi
          EV[$key]="$out"; printf '%s' "$out"
        }
        items="[]"
        while IFS= read -r line; do
          [ -n "$line" ] || continue
          host=$(jq -r .h <<<"$line"); machine=$(jq -r .m <<<"$line"); agent_id=$(jq -r .a <<<"$line"); title=$(jq -r .t <<<"$line"); ref=$(jq -r .r <<<"$line"); state=$(jq -r .s <<<"$line"); rest=$(jq -c .rest <<<"$line")
          n=""; repo=""
          [[ "$ref" =~ ^#([0-9]+)$ ]] && n="''${BASH_REMATCH[1]}"
          [[ "$title" =~ (^|[^A-Za-z0-9_./-])([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)(#|[[:space:]]|$) ]] && repo="''${BASH_REMATCH[2]}"
          if [ -z "$n" ]; then e='{"verdict":"unknown","refs":[],"reasons":["no task reference (#N) in the agent title"]}'
          elif [ -z "$repo" ]; then e="$(jq -cn --arg n "$n" '{verdict:"unknown", refs:[], reasons:["title names #" + $n + " but no OWNER/REPO; run gh:work for the repo to check it"]}')"
          else e=$(evidence "$repo" "$n"); fi
          items=$(jq -c --arg h "$host" --arg m "$machine" --arg a "$agent_id" --arg t "$title" --arg r "$ref" --arg s "$state" --arg at "$at" --argjson rest "$rest" --argjson e "$e" '
            . + [{host:$h, machine:(if $m == "" then null else $m end), agent_id:$a, harness:$rest.harness, session_id:$rest.session_id, title:$t, task_ref:(if $r == "" then null else $r end),
                  herdr_state:$s, state_change_seq:$rest.state_change_seq, observed_at:$at,
                  work_verdict:(if $s == "blocked" then "blocked" else $e.verdict end), needs_owner:($s == "blocked"),
                  evidence_ref:(if $s != "blocked" and $e.verdict == "verified" then ($e.refs | first // null) else null end), refs:$e.refs,
                  reasons:$e.reasons, sources:[{task:"herdr:inventory", observed_at:$at}]}]' <<<"$items")
        done < <(jq -c '.hosts[] | .host as $h | (.machine // "") as $m | .agents[] | {h:$h, m:$m, a:.agent_id, t:(.title // ""), r:(.task_ref // ""), s:(.observed_state // "unknown"), rest:{harness, session_id, state_change_seq}}' <<<"$inv")
        failed=$(jq -c '[(.hosts[] | select(.reachable == false) | {source:("herdr:inventory:" + .host), error})] + (if .machines_error != null then [{source:"herdr:machine-list", error:.machines_error}] else [] end)' <<<"$inv")
        emit "$(jq -cn --arg at "$at" --argjson inv "$inv" --argjson items "$items" --argjson f "$failed" \
          '{schema_version:1, task:"work:status", observed_at:$at, answered_hosts:($inv.answered_hosts // 0), hosts_total:($inv.hosts_total // 0), machines_configured:($inv.machines_configured // 0),
            failed_sources:$f, partial:(($f|length) > 0), items:$items}')"
      '';
    };

    "coord:brief" = {
      description = "Owner-facing brief: items needing input first, every agent with herdr_state and work_verdict, handoffs from the audit log, and the owner's portfolio (gh:repos, gh:work for active repos only).";
      after = [ "work:status@completed" "gh:repos@completed" ];
      exec = ''
        ${cfg.prelude}
        ws=$(upstream "work:status")
        [ "$ws" != null ] || fail 2 missing "work:status produced no output" '{"task":"coord:brief"}'
        dir="${cfg.stateDir}/brief"; mkdir -p "$dir"
        # handoffs come from the audit log alone (last attempt per handoff_id with its task_ref, and its outcome line), so a
        # fresh session rebuilds what was sent, to whom and whether it is verified from this file plus audit.jsonl; a log
        # that is not JSON lines is reported as a failed source, never shown as "no handoffs"
        audit="${cfg.stateDir}/audit.jsonl"; handoffs="[]"; audit_err="null"
        if [ -s "$audit" ]; then
          handoffs=$(jq -sc --argjson items "$(jq -c '.items // []' <<<"$ws")" '
            map(select(type == "object")) as $all
            | ($all | map(select(.phase == "outcome"))) as $outs
            | [$all[] | select(.phase == "attempt" and (.handoff_id|type) == "string")]
            | group_by(.handoff_id) | map(last)
            | map(. as $a | ($outs | map(select(.audit_id == $a.audit_id)) | last) as $o
                | ($items | map(select(.host == $a.host and .agent_id == $a.agent_id)) | first) as $it
                | {handoff_id:$a.handoff_id, audit_id:$a.audit_id, host:$a.host, machine:$a.machine, agent_id:$a.agent_id, sent_at:$a.at,
                   outcome:($o.outcome // "interrupted"), delivered:(($o.outcome // "") == "delivered"),
                   allowed_actions:($a.allowed_actions // []), authorized_by:(($a.authorized_by // {}) | {issue_url, label}),
                   task_ref:($a.task_ref // null), herdr_state:($it.herdr_state // null), work_verdict:($it.work_verdict // "unknown"), evidence_ref:($it.evidence_ref // null)})
            | sort_by(.sent_at)' "$audit" 2>/dev/null) \
            || { handoffs="[]"; audit_err=$(jq -cn --arg a "$audit" '{kind:"audit_corrupt", message:("audit log " + $a + " is not valid JSON lines; herdr:message refuses to send until the owner inspects it")}'); }
        fi
        # portfolio: gh:repos names the owner's repositories; gh:work runs only for the active ones (an open PR or an
        # approved-label issue), newest push first, at most portfolioActive of them; the rest are named, not fetched
        repos=$(upstream "gh:repos"); portfolio_err="null"; active="[]"; skipped="[]"; ptotal=0; plisted=0; ptrunc=false
        if [ "$repos" = null ]; then portfolio_err='{"kind":"missing","message":"gh:repos produced no output"}'
        elif [ "$(jq -r '.error != null' <<<"$repos")" = true ]; then portfolio_err=$(jq -c .error <<<"$repos")
        else
          ptotal=$(jq -r '.total // 0' <<<"$repos"); plisted=$(jq -r '.listed // 0' <<<"$repos"); ptrunc=$(jq -r '.truncated // false' <<<"$repos")
          while IFS= read -r repo; do
            [ -n "$repo" ] || continue
            if [ "$(jq -r length <<<"$active")" -ge ${toString cfg.portfolioActive} ]; then skipped=$(jq -c --arg r "$repo" '. + [$r]' <<<"$skipped"); continue; fi
            w=$(gh_work_json "$repo")
            active=$(jq -c --argjson w "$w" --argjson r "$(jq -c --arg r "$repo" '[.repos[] | select(.repo == $r)] | first' <<<"$repos")" \
              '. + [$r + {error:$w.error, truncated:($w.truncated // false),
                          approved:([$w.issues[]? | select((.labels // []) | index("approved")) | {number, title, url}]),
                          open_pr_list:([$w.prs[]? | select(.state == "OPEN") | {number, title, url, review_decision, draft, checks}])}]' <<<"$active")
          done < <(jq -r '.repos[] | select(.active) | .repo' <<<"$repos")
        fi
        portfolio=$(jq -cn --arg o "${cfg.ghOwner}" --argjson t "$ptotal" --argjson l "$plisted" --argjson tr "$ptrunc" --argjson a "$active" --argjson s "$skipped" --argjson e "$portfolio_err" \
          '{owner:$o, repos_total:$t, repos_listed:$l, truncated:$tr, active:$a, skipped_active:$s, error:$e}')
        brief=$(jq -c --argjson h "$handoffs" --arg a "$audit" --argjson e "$audit_err" --argjson p "$portfolio" \
          '. + {task:"coord:brief", handoffs:$h, audit_path:$a, handoffs_error:$e, portfolio:$p}
           | if $e != null then .partial = true | .failed_sources += [{source:"coordinator:audit", error:$e}] else . end
           | if $p.error != null then .partial = true | .failed_sources += [{source:"gh:repos", error:$p.error}] else . end' <<<"$ws")
        printf '%s\n' "$brief" > "$dir/latest.json.tmp" && mv "$dir/latest.json.tmp" "$dir/latest.json"
        printf '%s\n' "$brief" > "''${DEVENV_TASK_OUTPUT_FILE:-/dev/null}"
        jq -r --arg f "$dir/latest.json" '
          "# Fleet brief (\(.observed_at))",
          "", "Hosts: this one" + (if .machines_configured > 0 then " + \(.machines_configured) saved herdr machine(s)" else " only (no saved herdr machines: `herdr machine add <ssh-target> --label <name>` on the coordinator host adds workers)" end) + "; \(.answered_hosts)/\(.hosts_total) answered",
          (if .partial then "", "**Partial:** " + ([.failed_sources[] | "\(.source): \(.error.kind) — \(.error.message)"] | join("; ")) else empty end),
          "", "## Needs you",
          (([.items[] | select(.needs_owner)] | if length == 0 then ["- nothing"] else (.[0:10] | map("- \(.host)/\(.agent_id) (\(.harness)) \(.task_ref // "no ref"): herdr=\(.herdr_state) → \(.reasons | join("; "))")) + (if length > 10 then ["… \(length - 10) more needing you in the JSON"] else [] end) end)[]),
          "", "## Handoffs (from the audit log)",
          (if .handoffs_error != null then "- unreadable: \(.handoffs_error.kind) — \(.handoffs_error.message)" elif (.handoffs|length) == 0 then "- none" else (.handoffs[-20:][] | "- \(.handoff_id) → \(.host)/\(.agent_id) \(.task_ref // "-") | sent \(.sent_at) | \(.outcome) | work=\(.work_verdict)") end),
          "", "## Portfolio (\(.portfolio.owner): \(.portfolio.repos_listed) of \(.portfolio.repos_total) repos by recent push\(if .portfolio.truncated then ", truncated at the cap" else "" end))",
          (if .portfolio.error != null then "- unavailable: \(.portfolio.error.kind) — \(.portfolio.error.message)"
           elif (.portfolio.active|length) == 0 then "- no repo with an open PR or an approved issue"
           else (.portfolio.active[] | "- \(.repo): \(.open_prs) open PR(s), \(.approved_issues) approved issue(s)" + (if (.approved|length) > 0 then " → " + ([.approved[] | "#\(.number) \(.title)"] | join("; ")) else "" end) + (if .error != null then " (gh:work: \(.error.kind))" else "" end)) end),
          (if (.portfolio.skipped_active|length) > 0 then "- active but not expanded (cap \(.portfolio.active|length)): \(.portfolio.skipped_active | join(", "))" else empty end),
          "", "Full JSON: \($f)", "", "## Agents",
          (if (.items|length) == 0 then "- none observed" else (.items[0:30][] | "- \(.host)/\(.agent_id) \(.harness) \(.task_ref // "-") | herdr=\(.herdr_state) | work=\(.work_verdict)\(if .evidence_ref then " " + .evidence_ref else "" end)\(if (.reasons|length) > 0 then " | " + (.reasons | join("; ")) else "" end)") end),
          (if (.items|length) > 30 then "… \((.items|length) - 30) more agents in the JSON" else empty end)
        ' <<<"$brief"
        # the brief is the one task whose exit says something: no host answered (not even this one) is a failure
        [ "$(jq -r '((.items|length) > 0) or (.answered_hosts > 0)' <<<"$brief")" = true ] || exit 2
      '';
    };

    "coord:handoff" = {
      description = "Draft (never send) a bounded assignment brief for one agent, with the actions it may take; saves it under the state dir with a handoff_id.";
      input = { machine = null; agent_id = null; session_id = null; task_ref = null; scope = null; expected_evidence = null; acceptance = null; allowed_actions = null; owner_input = ""; };
      exec = ''
        ${cfg.prelude}
        m=$(input .machine); host=$([ -n "$m" ] && printf '%s' "$m" || local_host); agent=$(input .agent_id); ses=$(input .session_id); ref=$(input .task_ref); scope=$(input .scope); ev=$(input .expected_evidence); acc=$(input .acceptance); need=$(input .owner_input)
        actions=$(jq -c '.allowed_actions // empty' <<<"''${DEVENV_TASK_INPUT:-{\}}")
        ctx=$(jq -cn --arg h "$host" --arg a "$agent" '{task:"coord:handoff",host:$h,agent_id:$a}')
        [ -z "$ses" ] || [[ "$ses" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || fail 3 invalid_input "session_id has unsafe characters" "$ctx"
        [ -n "$agent" ] && [ -n "$ref" ] && [ -n "$scope" ] && [ -n "$ev" ] && [ -n "$acc" ] && [ -n "$actions" ] \
          || fail 3 invalid_input "agent_id, task_ref, scope, expected_evidence, acceptance and allowed_actions are required (machine for a remote agent)" "$ctx"
        [ -z "$m" ] || valid_machine "$m" || fail 3 invalid_input "machine label has unsafe characters" "$ctx"
        valid_id "$agent" || fail 3 invalid_input "agent_id has unsafe characters" "$ctx"
        [[ "$ref" =~ ^#[0-9]+$ ]] || fail 3 invalid_input "task_ref must look like #N" "$ctx"
        for v in "$scope" "$ev" "$acc" "$need"; do [ "''${#v}" -le 4000 ] || fail 3 invalid_input "a field exceeds 4000 characters" "$ctx"; done
        # allowed_actions: a non-empty list (at most 8) of distinct actions the agent may take beyond reading, committing and
        # opening a PR, which are always implied; the owner's "do not merge, deploy or delete" is now spelled per handoff.
        # deploy:none excludes deploy:<host>. Canonical order (merge, close, label, comment, deploy:* by host) so the same
        # set always renders and hashes the same. \z, not $: in jq's regexes $ also matches before a trailing newline.
        actions=$(jq -c 'if type == "array" and length > 0 and length <= 8
            and all(.[]; type == "string" and test("^(merge|close|label|comment|deploy:none|deploy:[A-Za-z0-9_][A-Za-z0-9_.-]{0,62})\\z") and ((ascii_downcase != "deploy:none") or (. == "deploy:none")))
            and (length == (unique | length)) and ((any(.[]; . == "deploy:none") | not) or ((map(select(startswith("deploy:"))) | length) == 1))
            then sort_by([(if . == "merge" then 0 elif . == "close" then 1 elif . == "label" then 2 elif . == "comment" then 3 else 4 end), .]) else empty end' <<<"$actions")
        [ -n "$actions" ] || fail 3 invalid_input "allowed_actions must be a non-empty list (at most 8) of distinct entries from: merge, close, label, comment, deploy:none, deploy:<host> (deploy:none excludes deploy:<host>)" "$ctx"
        actions_line=$(jq -r 'join(", ")' <<<"$actions")
        at=$(now_iso)
        text=$(printf 'Assignment %s for %s/%s\n\nScope: %s\n\nExpected evidence: %s\n\nAcceptance: %s\n\nAllowed actions: %s. Reading, committing and opening a PR are always implied; anything else, deleting included, is not allowed.\n%s\nReply in this pane when done, naming the evidence above.\n' \
          "$ref" "$host" "$agent" "$scope" "$ev" "$acc" "$actions_line" "$([ -n "$need" ] && printf '\nOwner input still needed: %s\n' "$need")")
        id=$(printf '%s|%s|%s|%s|%s|%s|%s' "$host" "$m" "$agent" "$ses" "$ref" "$actions" "$text" | sha256sum | cut -c1-12)
        dir="${cfg.stateDir}/handoffs"; mkdir -p "$dir"
        rec=$(jq -cn --arg id "$id" --arg at "$at" --arg h "$host" --arg m "$m" --arg a "$agent" --arg ses "$ses" --arg r "$ref" --arg t "$text" --arg need "$need" --argjson acts "$actions" \
          '{schema_version:1, task:"coord:handoff", handoff_id:$id, created_at:$at, host:$h, machine:(if $m == "" then null else $m end), agent_id:$a, session_id:(if $ses == "" then null else $ses end), task_ref:$r, allowed_actions:$acts, text:$t,
            owner_input: (if $need == "" then null else $need end), approval_required:true, error:null}')
        if [ ! -f "$dir/$id.json" ]; then
          [ -n "$rec" ] && printf '%s\n' "$rec" > "$dir/$id.json.tmp" && mv "$dir/$id.json.tmp" "$dir/$id.json" || fail 2 state_write_failed "could not write the draft under $dir" "$ctx"
        fi
        emit "$(jq -c '.' "$dir/$id.json")"
      '';
    };
  };
}
