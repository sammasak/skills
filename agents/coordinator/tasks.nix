# Coordinator role DAG: work:status joins live Herdr state (this host + saved machines) with GitHub
# evidence for agents whose title names OWNER/REPO#N; coord:brief renders it. Failed sources are
# reported as partial, never hidden.
{ lib, config, ... }:

let
  cfg = config.coordinator;
  handoffsKept = 50;
  feedbackTaxonomy = [ "auth_contradiction" "wrong_assignment" "review_deadlock" "repeated_build" "stale_lock_or_orphan" "false_success" "misleading_skill" "missing_tool" ];
  # shared by coord:report and coord:report:daily: fetch the PRs of the repos the audit window names (the same gh pr list
  # path work:status uses, only the fields report.jq reads) and run report.jq. Assumes $tmpd/audit.json, $since, $until,
  # $days, $at, $limit and $aggctx are set; leaves the aggregate in $rep. A failed or truncated list is data, not fatal.
  reportAggregate = ''
    : > "$tmpd/repos.jsonl"
    while IFS= read -r repo; do
      [ -n "$repo" ] || continue
      rc=0
      timeout -k 1 ${toString cfg.timeoutSeconds} ${cfg.ghCommand} pr list -R "$repo" --state all --limit "$limit" \
        --json number,state,mergedAt,createdAt,url,headRefOid,closingIssuesReferences,comments,reviews > "$tmpd/p.json" 2>/dev/null || rc=$?
      if [ "$rc" -ne 0 ]; then jq -cn --arg r "$repo" --arg e "gh exited $rc" '{repo:$r, error:$e}'
      else jq -cn --arg r "$repo" --slurpfile p "$tmpd/p.json" --argjson l "$limit" \
          'if ($p | length) == 1 and ($p[0] | type) == "array" then {repo:$r, error:null, limit:$l, prs:$p[0]} else error end' 2>/dev/null \
        || jq -cn --arg r "$repo" '{repo:$r, error:"gh returned unexpected JSON"}'; fi >> "$tmpd/repos.jsonl"
    done < <(jq -r '[.[]
        | (.authorized_by.issue_url // "" | [capture("^https://github\\.com/(?<r>[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/(issues|pull)/[0-9]+").r] | first // empty),
          (if (.phase == "gh" and (.repo // null) != null) then .repo else empty end)]
        | unique[] | select(test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"))' "$tmpd/audit.json")
    jq -sc 'INDEX(.repo)' "$tmpd/repos.jsonl" > "$tmpd/repos.json"
    rep=$(jq -nc -L ${./.} --slurpfile audit "$tmpd/audit.json" --slurpfile repos "$tmpd/repos.json" \
      --argjson window "$(jq -cn --arg s "$since" --arg u "$until" --argjson d "$days" '{since:$s, until:$u, days:$d}')" \
      --arg at "$at" -f ${./.}/report.jq) || fail 2 internal "report aggregation failed" "$aggctx"
  '';
in
{
  imports = [ ../../task-modules/common.nix ];

  tasks = {
    "work:status" = {
      description = "Per-agent herdr_state + evidence-derived work_verdict, and per-handoff stages (implemented, reviewed, merged, live): an agent with a delivered handoff on its current session is correlated by that handoff's task_ref and repo, otherwise by an OWNER/REPO#N title; partial on failed sources, never fails itself.";
      after = [ "herdr:inventory@completed" ];
      exec = ''
        ${cfg.prelude}
        at=$(now_iso)
        inv=$(upstream "herdr:inventory")
        [ "$inv" != null ] || fail 2 missing "herdr:inventory produced no output" '{"task":"work:status"}'
        tmpd=$(mktemp -d); trap 'rm -rf "$tmpd"' EXIT
        # handoffs come from the audit log alone (last attempt per handoff_id with its task_ref, and its outcome line), so a
        # fresh session rebuilds what was sent, to whom and whether it is verified from audit.jsonl; a log that is not JSON
        # lines is reported as a failed source, never shown as "no handoffs"
        audit="${cfg.stateDir}/audit.jsonl"; audit_err="null"
        no_handoffs() { printf '{"kept":${toString handoffsKept},"omitted":0,"handoffs":[],"omitted_last":[]}\n' > "$tmpd/handoffs.json"; }; no_handoffs
        if [ -s "$audit" ]; then
          jq -sc '
            map(select(type == "object")) as $all
            | (INDEX($all[] | select(.phase == "outcome"); .audit_id)) as $byid
            | [$all[] | select(.phase == "attempt" and (.handoff_id|type) == "string")]
            | group_by(.handoff_id) | map(last)
            | map(. as $a | ($byid[$a.audit_id | tostring] // null) as $o | (($a.authorized_by // {}) | {issue_url, label}) as $auth
                | {handoff_id:$a.handoff_id, audit_id:$a.audit_id, host:$a.host, machine:$a.machine, agent_id:$a.agent_id, session_id:($a.session_id // null), sent_at:$a.at,
                   outcome:($o.outcome // "interrupted"), delivered:(($o.outcome // "") == "delivered"),
                   allowed_actions:($a.allowed_actions // []), authorized_by:$auth, task_ref:($a.task_ref // null), review:($a.review // null),
                   repo:((($auth.issue_url // "") | [capture("^https://github\\.com/(?<r>[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/(issues|pull)/[0-9]+").r] | first) // $a.repo // null)})
            # a handoff owns the PRs opened from its send until the next handoff to the same pane (until); only the newest
            # ${toString handoffsKept} are evaluated and carried, so the record stays well under the environment size devenv passes it in
            | group_by(.host + "/" + .agent_id) | map(sort_by(.sent_at) | . as $g | [range(length) | $g[.] + {until:($g[. + 1].sent_at // null)}]) | add // [] | sort_by(.sent_at)
            # for the rest only the newest delivered one per pane is kept, so its agent reports "omitted", not a title guess
            | {kept:${toString handoffsKept}, omitted:([length - ${toString handoffsKept}, 0] | max), handoffs:.[-${toString handoffsKept}:],
               omitted_last:(.[:-${toString handoffsKept}] | map(select(.delivered)) | group_by(.host + "/" + .agent_id) | map(last | {handoff_id, host, agent_id, session_id, task_ref, sent_at}))}' "$audit" > "$tmpd/handoffs.json" 2>/dev/null \
            || { no_handoffs; audit_err=$(jq -cn --arg a "$audit" '{kind:"audit_corrupt", message:("audit log " + $a + " is not valid JSON lines; herdr:message refuses to send until the owner inspects it")}'); }
        fi
        # GitHub evidence: one bounded PR list (all states, comments and reviews) and one open-issue list per repo named by a
        # handoff or an OWNER/REPO#N title. No --search: GitHub's search index misses PRs it has not indexed, a plain list does not
        : > "$tmpd/repos.jsonl"
        while IFS= read -r repo; do
          [ -n "$repo" ] || continue
          rc=0
          timeout -k 1 ${toString cfg.timeoutSeconds} ${cfg.ghCommand} pr list -R "$repo" --state all --limit ${toString cfg.ghLimit} \
            --json number,title,body,state,mergedAt,createdAt,url,headRefName,headRefOid,closingIssuesReferences,statusCheckRollup,comments,reviews,commits > "$tmpd/p.json" 2>/dev/null || rc=$?
          [ "$rc" -ne 0 ] || timeout -k 1 ${toString cfg.timeoutSeconds} ${cfg.ghCommand} issue list -R "$repo" --state open --limit ${toString cfg.ghLimit} --json number,url > "$tmpd/i.json" 2>/dev/null || rc=$?
          if [ "$rc" -ne 0 ]; then jq -cn --arg r "$repo" --arg e "gh exited $rc" '{repo:$r, error:$e}'
          else jq -cn --arg r "$repo" --slurpfile p "$tmpd/p.json" --slurpfile i "$tmpd/i.json" --argjson l ${toString cfg.ghLimit} \
              'if ($p | length) == 1 and ($p[0] | type) == "array" and ($i | length) == 1 and ($i[0] | type) == "array" then {repo:$r, error:null, limit:$l, prs:$p[0], issues:$i[0]} else error end' 2>/dev/null \
            || jq -cn --arg r "$repo" '{repo:$r, error:"gh returned unexpected JSON"}'; fi >> "$tmpd/repos.jsonl"
        done < <(jq -rn --argjson inv "$inv" --slurpfile h "$tmpd/handoffs.json" '
          ([$h[0].handoffs[] | .repo // empty] + [$inv.hosts[]?.agents[]? | select(.task_ref != null) | (.title // "") | [capture("(^|[^A-Za-z0-9_./-])(?<r>[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)(#|\\s|$)").r] | first // empty])
          | unique[] | select(test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"))')
        jq -sc 'INDEX(.repo)' "$tmpd/repos.jsonl" > "$tmpd/repos.json"
        printf '%s\n' "$inv" > "$tmpd/inv.json"
        jq -nc --slurpfile inv "$tmpd/inv.json" --slurpfile handoffs "$tmpd/handoffs.json" --slurpfile repos "$tmpd/repos.json" --arg at "$at" \
          -L ${./.} -f ${./.}/correlate.jq > "$tmpd/corr.json" || fail 2 internal "work:status correlation failed" '{"task":"work:status"}'
        failed=$(jq -c --argjson e "$audit_err" '[(.hosts[] | select(.reachable == false) | {source:("herdr:inventory:" + .host), error})] + (if .machines_error != null then [{source:"herdr:machine-list", error:.machines_error}] else [] end)
          + (if $e != null then [{source:"coordinator:audit", error:$e}] else [] end)' <<<"$inv")
        emit "$(jq -c --arg at "$at" --argjson inv "$inv" --argjson f "$failed" --arg a "$audit" --argjson e "$audit_err" \
          '. as $c | {schema_version:1, task:"work:status", observed_at:$at, answered_hosts:($inv.answered_hosts // 0), hosts_total:($inv.hosts_total // 0), machines_configured:($inv.machines_configured // 0),
            failed_sources:$f, partial:(($f|length) > 0), items:$c.items, handoffs:$c.handoffs, handoffs_omitted:$c.handoffs_omitted, audit_path:$a, handoffs_error:$e}' "$tmpd/corr.json")"
      '';
    };

    "coord:brief" = {
      description = "Owner-facing brief: items needing input first, every agent with herdr_state and work_verdict, handoffs from the audit log, and the owner's portfolio (gh:repos, gh:work for active repos only; a failed issue search is named, since repos outside the page are then unchecked; under coordinator.mayApprove each active repo also lists its approvable issues).";
      after = [ "work:status@completed" "gh:repos@completed" ];
      exec = ''
        ${cfg.prelude}
        # the previous latest.md goes first: a run that fails before rendering leaves none, never a stale one to read
        dir="${cfg.stateDir}/brief"; mkdir -p "$dir"; rm -f "$dir/latest.md"
        ws=$(upstream "work:status")
        [ "$ws" != null ] || fail 2 missing "work:status produced no output" '{"task":"coord:brief"}'
        # state timeline (#85 M0b): each observed pane state, host/pane/state/at only, appended to states.jsonl so
        # coord:report can measure blocked and idle spans from the sparse brief snapshots. No title, task_ref, scope or
        # session text -- a pane identity and its herdr_state at an instant, nothing more. Best effort: a write failure
        # never fails the brief. Under its own lock so a concurrent brief does not interleave a half-written line.
        sdir="${cfg.stateDir}/herdr"; mkdir -p "$sdir"
        ( exec 8>>"$sdir/states.lock"; flock -w 5 8 2>/dev/null || true
          jq -c '.items[]? | {host, pane:.agent_id, state:(.herdr_state // null), at:(.observed_at // null)}
                 | select(.host != null and .pane != null)' <<<"$ws" >> "$sdir/states.jsonl" ) 2>/dev/null || true
        # portfolio: gh:repos names the owner's repositories; gh:work runs only for the active ones (an open PR or an
        # issue with an authorizing label), newest push first, at most portfolioActive of them; the rest are named, not
        # fetched. GitHub being down leaves the agent part of the brief whole: the portfolio carries its own error and
        # is not a failed source of the fleet picture
        repos=$(upstream "gh:repos"); portfolio_err="null"; search_err="null"; active="[]"; skipped="[]"; ptotal=0; plisted=0; ptrunc=false
        if [ "$repos" = null ]; then portfolio_err='{"kind":"missing","message":"gh:repos produced no output"}'
        elif [ "$(jq -r '.error != null' <<<"$repos")" = true ]; then portfolio_err=$(jq -c .error <<<"$repos")
        else
          ptotal=$(jq -r '.total // 0' <<<"$repos"); plisted=$(jq -r '.listed // 0' <<<"$repos"); ptrunc=$(jq -r '.truncated // false' <<<"$repos")
          # the issue search failing leaves repos pushed before the page unchecked: the brief says so (below), the page stands
          search_err=$(jq -c '.search.error // null' <<<"$repos")
          while IFS= read -r repo; do
            [ -n "$repo" ] || continue
            if [ "$(jq -r length <<<"$active")" -ge ${toString cfg.portfolioActive} ]; then skipped=$(jq -c --arg r "$repo" '. + [$r]' <<<"$skipped"); continue; fi
            w=$(gh_work_json "$repo")
            # the open PRs' heads with their notes, for each head's review state (skills#77); a failed call leaves it unknown
            prs_raw=$(timeout -k 1 ${toString cfg.timeoutSeconds} ${cfg.ghCommand} pr list -R "$repo" --state open --limit ${toString cfg.ghLimit} \
                --json number,title,body,url,headRefName,headRefOid,createdAt,closingIssuesReferences,comments,reviews 2>/dev/null) \
              && jq -e 'type == "array"' >/dev/null 2>&1 <<<"$prs_raw" || prs_raw=null
            active=$(jq -c -L ${./.} --argjson w "$w" --slurpfile rp <(printf '%s\n' "$prs_raw") --slurpfile WS <(printf '%s\n' "$ws") --argjson labels ${lib.escapeShellArg (builtins.toJSON cfg.authorizingLabels)} --argjson may ${lib.boolToString cfg.mayApprove} --arg o ${lib.escapeShellArg cfg.ghOwner} --argjson r "$(jq -c --arg r "$repo" '[.repos[] | select(.repo == $r)] | first' <<<"$repos")" \
              'include "evidence"; . + [$r + {error:$w.error, truncated:($w.truncated // false),
                          # open_prs: the open PRs naming the issue; one holds the item whether or not a handoff owns it. gh:work keeps the
                          # closes, branch and title of each PR (no body, to stay small), mapped back to the fields refs() reads
                          approved:([$w.issues[]? | select(any((.labels // [])[]; . as $l | ($labels | index($l)) != null)) | .number as $n
                                     | {number, title, url, labels, open_prs:[$w.prs[]? | select(.state == "OPEN")
                                         | select({title, closingIssuesReferences:((.closes // []) | map({number:.})), headRefName:(.branch // "")} | refs($n)) | .number]}]),
                          # under the delegation (coordinator.mayApprove): what gh:label may approve (open, the owner wrote it, no authorizing
                          # label, no hold; the task checks author and state again at approval time)
                          approvable:(if $may then [$w.issues[]? | select((.state // "OPEN") == "OPEN") | select((.author // "") == $o) | select(any((.labels // [])[]; . as $l | ($labels | index($l)) != null or (. == "needs-live" or . == "blocked" or . == "needs-decision" or . == "needs-triage")) | not) | {number, title, url, labels}] else [] end),
                          open_pr_list:([$w.prs[]? | select(.state == "OPEN") | {number, title, url, review_decision, draft, checks}]),
                          # the review state of each open PR head (skills#77): only unreviewed is a review to hand out; findings go back
                          # to the implementer it names, disputed is for the owner, in_review and passed are no work. A merged or closed PR
                          # is not listed. Implementer: a delivered non-review handoff for an issue the PR names, sent before it opened;
                          # in review: a review handoff for exactly this head whose agent is on it (same session, working or blocked), or
                          # out of sight (host unanswered, delivery unknown: never a duplicate); idle, done, gone or a new session with no
                          # grade frees the head, which is then offered once more (the recovery of a review that yielded nothing)
                          open_pr_reviews:(($r.repo) as $repo | ($WS[0].handoffs // []) as $hs
                            | if $rp[0] == null then null else [$rp[0][] | . as $pr
                              | ([$hs[] | select(.repo == $repo and .delivered and .review == null) | (.task_ref | num) as $n
                                  | select($n != null and ($pr | refs($n)) and ($pr.createdAt // "") >= (.sent_at // "")) | .host + "/" + .agent_id] | unique) as $impl
                              | ([$hs[] | select(.review != null and .review.pr == ($repo + "#" + ($pr.number | tostring)) and .review.head == ($pr.headRefOid // "") and .until == null)
                                  | (.herdr_state // "") as $hs_state
                                  | select((.delivered and .session_state == "same" and ((["working", "blocked"] | index($hs_state)) != null))
                                           or (.delivered and .session_state == "unobserved") or .hold == "unknown")
                                  | .host + "/" + .agent_id]) as $ir
                              | {number, url} + ($pr | review_state($impl; $ir))] end)}]' <<<"$active")
          # repos holding authorized work (an open PR or an authorizing label) are expanded first, delegation-only ones after,
          # newest push first within each group, so the cap never drops authorized work for unlabelled issues
          done < <(jq -r '[.repos[] | select(.active)] | sort_by(if .open_prs > 0 or .approved_issues > 0 then 0 else 1 end) | .[] | .repo' <<<"$repos")
        fi
        # each approved issue names its delivered handoffs: re-assignable only when every one is closed and no open PR names it;
        # an open or unknown handoff holds it (work:status's hold)
        active=$(jq -c --slurpfile W <(printf '%s\n' "$ws") 'map(.repo as $r | .approved |= map(.number as $n
            | [$W[0].handoffs[]? | select((.delivered or .hold == "unknown") and .repo == $r and .task_ref == "#\($n)")] as $hs
            | . + {open_handoffs:[$hs[] | select(.hold != "closed") | {handoff_id, agent:(.host + "/" + .agent_id), hold, unknown_reason}],
                   last_handoff:($hs | last | if . == null then null else {handoff_id, agent:(.host + "/" + .agent_id), hold, closed_reason} end),
                   reassignable:(all($hs[]; .hold == "closed") and ((.open_prs // []) | length) == 0)}))' <<<"$active") \
          || fail 2 internal "could not join approved issues with their handoffs" '{"task":"coord:brief"}'
        portfolio=$(jq -cn --arg o "${cfg.ghOwner}" --argjson labels ${lib.escapeShellArg (builtins.toJSON cfg.authorizingLabels)} --argjson may ${lib.boolToString cfg.mayApprove} --argjson t "$ptotal" --argjson l "$plisted" --argjson tr "$ptrunc" --argjson a "$active" --argjson s "$skipped" --argjson e "$portfolio_err" --argjson se "$search_err" \
          '{owner:$o, authorizing_labels:$labels, may_approve:$may, repos_total:$t, repos_listed:$l, truncated:$tr, active:$a, skipped_active:$s, error:$e, search_error:$se}')
        brief=$(jq -c --argjson p "$portfolio" --argjson g ${toString cfg.wakeMinGapSeconds} --argjson c ${toString cfg.wakeMaxPerHour} '. + {task:"coord:brief", portfolio:$p, wake_budget:{min_gap_seconds:$g, max_per_hour:$c}}' <<<"$ws")
        printf '%s\n' "$brief" > "$dir/latest.json.tmp" && mv "$dir/latest.json.tmp" "$dir/latest.json"
        printf '%s\n' "$brief" > "''${DEVENV_TASK_OUTPUT_FILE:-/dev/null}"
        # the Markdown is the default read (latest.md): devenv's stdout carries every task's JSON, which the runbook's
        # default command sends to /dev/null; latest.json keeps the full record
        jq -r --arg f "$dir/latest.json" '
          "# Fleet brief (\(.observed_at))",
          "", "Hosts: this one" + (if .machines_configured > 0 then " + \(.machines_configured) saved herdr machine(s)" else " only (`herdr machine add` adds workers)" end) + "; \(.answered_hosts)/\(.hosts_total) answered",
          "Wake budget: at most \(.wake_budget.max_per_hour) session(s) an hour, \(.wake_budget.min_gap_seconds) s apart (coordinator.wakeMaxPerHour, coordinator.wakeMinGapSeconds)",
          (if .partial then "", "**Partial:** " + ([.failed_sources[] | "\(.source): \(.error.kind) — \(.error.message)"] | join("; ")) else empty end),
          "", "## Needs you",
          (([.items[] | select(.needs_owner)] | if length == 0 then ["- nothing"] else (.[0:10] | map("- \(.host)/\(.agent_id) (\(.harness)) \(.task_ref // "no ref"): herdr=\(.herdr_state) → \(.reasons | join("; "))")) + (if length > 10 then ["… \(length - 10) more needing you in the JSON"] else [] end) end)[]),
          # compact by default: verified handoffs as one line per repo#ref (an open epic does not hide them), then each open
          # or unverified handoff with its stages; everything else is in the JSON
          # closed handoffs (settled without an open PR, stale, superseded, merged unreviewed) hold nothing: one line per item
          (([.handoffs[] | select(.work_verdict == "verified")]) as $done | ([.handoffs[] | select(.hold != "closed")]) as $open
          | ([.handoffs[] | select(.work_verdict != "verified" and .hold == "closed")]) as $closed
          | def mark($k): "\($k) \(if .stages[$k] then "✓" else "–" end)";
          "", "## Handoffs (from the audit log): \((.handoffs|length) + (.handoffs_omitted // 0)) total, \($done|length) verified, \([$open[] | select(.hold == "open")] | length) open, \([$open[] | select(.hold == "unknown")] | length) unknown, \($closed|length) closed" + (if (.handoffs_omitted // 0) > 0 then " (the oldest \(.handoffs_omitted) not evaluated)" else "" end),
          (if .handoffs_error != null then "- unreadable: \(.handoffs_error.kind) — \(.handoffs_error.message)" elif (.handoffs|length) == 0 then "- none" else
            ($done | group_by([.repo, .task_ref])[] | "- verified \(.[0].repo)\(.[0].task_ref)\(if .[0].task_issue_open then " (still open)" else "" end): merged "
               + ([.[].stages.merged[]? | capture("/pull/(?<n>[0-9]+)$").n | tonumber] | unique | map("#\(.)") | join(" "))),
            ($open[-20:][] | "- \(.handoff_id) → \(.host)/\(.agent_id) \(.task_ref // "-") \(.repo // "no repo") | sent \(.sent_at) | \(.outcome) | "
               + ([mark("implemented"), mark("reviewed"), mark("merged"), mark("live")] | join(" ")) + " | work=\(.work_verdict)"
               + (if .hold == "unknown" then " | HOLD UNKNOWN: \(.unknown_reason)" else "" end) + (if .stale then " | STALE" else "" end) + (if (.reasons|length) > 0 then " | " + (.reasons | join("; ")) else "" end)),
            (if ($open|length) > 20 then "… \(($open|length) - 20) more open handoffs in the JSON" else empty end),
            (if ($closed|length) > 0 then "- closed, nobody on it (the item can be handed out again; a merged PR without an independent review is reported for the owner, never reviewed after the merge): "
               + ([$closed | group_by([.repo, .task_ref])[] | "\(.[0].repo // "no repo")\(.[0].task_ref // "-") (" + ([.[] | "\(.handoff_id) \(.closed_reason)"] | join(", ")) + ")"] | join("; ")) else empty end) end)),
          "", "## Portfolio (\(.portfolio.owner): \(.portfolio.repos_listed) of \(.portfolio.repos_total) repos by recent push\(if .portfolio.truncated then ", truncated at the cap" else "" end); authorizing labels: \(.portfolio.authorizing_labels | join(", ")))",
          (if .portfolio.error != null then "- unavailable (agents above are unaffected): \(.portfolio.error.kind) — \(.portfolio.error.message)"
           elif (.portfolio.active|length) == 0 then "- no repo with an open PR or an approved issue" + (if .portfolio.may_approve then " or an approvable one" else "" end)
           else (.portfolio.active[] | "- \(.repo): \(.open_prs) open PR(s), \(.approved_issues) approved issue(s)" + (if (.approved|length) > 0 then " → " + ([.approved[] | "#\(.number) \(.title)"
               + (if (.open_handoffs|length) > 0 then " [held by handoff " + ([.open_handoffs[] | "\(.handoff_id) → \(.agent)" + (if .hold == "unknown" then " (unknown: \(.unknown_reason))" else "" end)] | join(", ")) + "]"
                  elif ((.open_prs // []) | length) > 0 then " [held by open PR " + ([.open_prs[] | "#\(.)"] | join(", ")) + "]"
                  elif .last_handoff != null then " [re-assignable: handoff \(.last_handoff.handoff_id) → \(.last_handoff.agent) \(.last_handoff.closed_reason)]" else "" end)] | join("; ")) else "" end)
               + (if .open_pr_reviews == null then " | PR review states unavailable (gh pr list failed)" elif (.open_pr_reviews | length) > 0 then " | PRs: " + ([.open_pr_reviews[] | "#\(.number)@\((.head // "")[0:7]) "
                   + (if .state == "unreviewed" then "to review (a worker other than \(if (.implementer | length) > 0 then .implementer | join("+") else "its author" end))"
                      elif .state == "findings" then "findings \([.grades[] | "\(.grade)/10 \(.by)"] | join(", ")) → back to \(if (.implementer | length) > 0 then .implementer | join("+") else "the author (implementer unknown)" end), not another review"
                      elif .state == "disputed" then "conflicting grades \([.grades[] | "\(.grade)/10 \(.by)"] | join(", ")): an owner decision"
                      elif .state == "in_review" then "in review (\(.in_review | join("+")))"
                      else "passed \([.grades[] | select(.grade >= 9) | "\(.grade)/10 \(.by)"] | join(", ")): its reviewer merges" end)] | join("; ")) else "" end)
               + (if .error != null then " (gh:work: \(.error.kind))" else "" end) + (if (.approvable|length) > 0 then " | approvable: " + ([.approvable[:8][] | "#\(.number) \(.title)"] | join("; ")) + (if (.approvable|length) > 8 then "; +\((.approvable|length) - 8) more" else "" end) else "" end)) end),
          (if (.portfolio.skipped_active|length) > 0 then "- active but not expanded (cap \(.portfolio.active|length)): \(.portfolio.skipped_active | join(", "))" else empty end),
          (if .portfolio.search_error != null then "- issue search unavailable: \(.portfolio.search_error.kind) — \(.portfolio.search_error.message); repos pushed before the page may hold authorized items" else empty end),
          "", "Full JSON: \($f)", "", "## Agents",
          (if (.items|length) == 0 then "- none observed" else (.items[0:30][] | "- \(.host)/\(.agent_id) \(.harness) \(.runtime_task_ref // .task_ref // "-")\(if .runtime_id != null then " | runtime=\(.host)/\(.runtime_id) tpl=\(.template // "unknown")" else "" end) | herdr=\(.herdr_state)\(if .unavailable != null then " | UNAVAILABLE (\(.unavailable.reason))" else "" end) | work=\(.work_verdict)\(if .evidence_ref then " " + .evidence_ref else "" end)\(if (.reasons|length) > 0 and .correlation.by != "none" then " | " + (.reasons | join("; ")) else "" end)") end),
          (if (.items|length) > 30 then "… \((.items|length) - 30) more agents in the JSON" else empty end)
        ' <<<"$brief" > "$dir/latest.md.tmp" || { rm -f "$dir/latest.md.tmp"; fail 2 internal "coord:brief Markdown render failed" '{"task":"coord:brief"}'; }
        mv "$dir/latest.md.tmp" "$dir/latest.md" && cat "$dir/latest.md"
        # the brief is the one task whose exit says something: no host answered (not even this one) is a failure
        [ "$(jq -r '((.items|length) > 0) or (.answered_hosts > 0)' <<<"$brief")" = true ] || exit 2
      '';
    };

    "coord:handoff" = {
      description = "Draft (never send) a bounded assignment brief for one agent, with the actions it may take; saves it under the state dir with a handoff_id.";
      input = { machine = null; agent_id = null; session_id = null; task_ref = null; scope = null; expected_evidence = null; acceptance = null; allowed_actions = null; pr_url = null; owner_input = ""; review = null; };
      exec = ''
        ${cfg.prelude}
        m=$(input .machine); host=$([ -n "$m" ] && printf '%s' "$m" || local_host); agent=$(input .agent_id); ses=$(input .session_id); ref=$(input .task_ref); scope=$(input .scope); ev=$(input .expected_evidence); acc=$(input .acceptance); pr=$(input .pr_url); need=$(input .owner_input); review=$(input .review)
        actions=$(jq -c '.allowed_actions // empty' <<<"''${DEVENV_TASK_INPUT:-{\}}")
        ctx=$(jq -cn --arg h "$host" --arg a "$agent" '{task:"coord:handoff",host:$h,agent_id:$a}')
        [ -z "$ses" ] || [[ "$ses" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || fail 3 invalid_input "session_id has unsafe characters" "$ctx"
        [ -n "$agent" ] && [ -n "$ref" ] && [ -n "$scope" ] && [ -n "$ev" ] && [ -n "$acc" ] && [ -n "$actions" ] \
          || fail 3 invalid_input "agent_id, task_ref, scope, expected_evidence, acceptance and allowed_actions are required (machine for a remote agent)" "$ctx"
        [ -z "$m" ] || valid_machine "$m" || fail 3 invalid_input "machine label has unsafe characters" "$ctx"
        valid_id "$agent" || fail 3 invalid_input "agent_id has unsafe characters" "$ctx"
        # never to the Coordinator itself: a handoff to its own pane made that pane a "worker" that is always working (skills#28)
        jq -e --arg t "$host/$agent" 'index($t) | not' <<<"$(coordinator_panes "${cfg.stateDir}/audit.jsonl")" >/dev/null \
          || fail 3 invalid_input "$host/$agent is a Coordinator pane (coordinator.panes, the pane running this task, or a past sender in the audit log); handoffs go to workers only" "$ctx"
        [[ "$ref" =~ ^#[0-9]+$ ]] || fail 3 invalid_input "task_ref must look like #N" "$ctx"
        # a review handoff names the PR and the exact head it reviews (skills#77): the line is part of the text the id hashes,
        # the attempt line carries it, and coord:changed and coord:brief then read that head as in review
        [ -z "$review" ] || [[ "$review" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+@[0-9a-f]{40}$ ]] || fail 3 invalid_input "review must be OWNER/REPO#N@<40-hex head sha>" "$ctx"
        for v in "$scope" "$ev" "$acc" "$need"; do [ "''${#v}" -le 4000 ] || fail 3 invalid_input "a field exceeds 4000 characters" "$ctx"; done
        # allowed_actions: a non-empty list (at most 8) of distinct actions the agent may take beyond reading, committing and
        # opening a PR, which are always implied; the owner's "do not merge, deploy or delete" is now spelled per handoff.
        # cleanup:tmp authorizes deletion, but only of the temporary review worktrees/clones, their cargo targets and
        # /tmp/devenv-* dirs the scope lists (skills#28); without it the footer still forbids all deletion.
        # deploy:none excludes deploy:<host>. Canonical order (merge, close, label, comment, cleanup:tmp, deploy:* by host) so
        # the same set always renders and hashes the same. \z, not $: in jq's regexes $ also matches before a trailing newline.
        actions=$(jq -c 'if type == "array" and length > 0 and length <= 8
            and all(.[]; type == "string" and test("^(merge|close|label|comment|cleanup:tmp|deploy:none|deploy:[A-Za-z0-9_][A-Za-z0-9_.-]{0,62})\\z") and ((ascii_downcase != "deploy:none") or (. == "deploy:none")))
            and (length == (unique | length)) and ((any(.[]; . == "deploy:none") | not) or ((map(select(startswith("deploy:"))) | length) == 1))
            then sort_by([(if . == "merge" then 0 elif . == "close" then 1 elif . == "label" then 2 elif . == "comment" then 3 elif . == "cleanup:tmp" then 4 else 5 end), .]) else empty end' <<<"$actions")
        [ -n "$actions" ] || fail 3 invalid_input "allowed_actions must be a non-empty list (at most 8) of distinct entries from: merge, close, label, comment, cleanup:tmp, deploy:none, deploy:<host> (deploy:none excludes deploy:<host>)" "$ctx"
        # #70: author-merge is enforced at herdr:message send by the authorship of the PR being merged, not the authorizing
        # item (implement, review and merge handoffs share the issue the owner labelled). The draft is composed freely (as a
        # review draft is); the send is the gate: it resolves the implementer from the PR the merge handoff names -- pr_url
        # (a .../pull/N URL) or the review field (OWNER/REPO#N@head, when the same handoff reviews and merges, skills#77) --
        # and a merge draft that names neither is refused there. Here only pr_url's shape is checked, and it is merge-only.
        if [ -n "$pr" ]; then
          [[ "$pr" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[1-9][0-9]*$ ]] || fail 3 invalid_input "pr_url must be https://github.com/OWNER/REPO/pull/N" "$ctx"
          jq -e 'index("merge")' <<<"$actions" >/dev/null || fail 3 invalid_input "pr_url is only for a merge handoff (allowed_actions must include merge)" "$ctx"
        fi
        actions_line=$(jq -r 'join(", ")' <<<"$actions")
        # The deletion clause of the footer is the only part cleanup:tmp changes (skills#28): with it, deleting is allowed, but
        # only for the temp paths the scope lists; without it the clause is byte-for-byte the long-standing "deleting included"
        # refusal, so a handoff that does not grant cleanup:tmp renders and hashes exactly as before.
        if jq -e 'any(.[]; . == "cleanup:tmp")' <<<"$actions" >/dev/null; then
          del_clause='anything else is not allowed, except that deleting is allowed only for the temporary review worktrees, clones, their cargo targets and /tmp/devenv-* dirs this scope lists'
        else
          del_clause='anything else, deleting included, is not allowed'
        fi
        at=$(now_iso)
        text=$(printf 'Assignment %s for %s/%s\n\nScope: %s\n\nExpected evidence: %s\n\nAcceptance: %s\n\nAllowed actions: %s. Reading, committing and opening a PR are always implied; %s.\n%s%s%s\nReply in this pane when done, naming the evidence above.\n' \
          "$ref" "$host" "$agent" "$scope" "$ev" "$acc" "$actions_line" "$del_clause" "$([ -n "$pr" ] && printf '\nMerge target: %s\n' "$pr")" "$([ -n "$review" ] && printf '\nReview of: %s at head %s\n' "''${review%@*}" "''${review##*@}")" "$([ -n "$need" ] && printf '\nOwner input still needed: %s\n' "$need")")
        id=$(printf '%s|%s|%s|%s|%s|%s|%s' "$host" "$m" "$agent" "$ses" "$ref" "$actions" "$text" | sha256sum | cut -c1-12)
        dir="${cfg.stateDir}/handoffs"; mkdir -p "$dir"
        rec=$(jq -cn --arg id "$id" --arg at "$at" --arg h "$host" --arg m "$m" --arg a "$agent" --arg ses "$ses" --arg r "$ref" --arg t "$text" --arg pr "$pr" --arg need "$need" --argjson acts "$actions" --arg rv "$review" \
          '{schema_version:1, task:"coord:handoff", handoff_id:$id, created_at:$at, host:$h, machine:(if $m == "" then null else $m end), agent_id:$a, session_id:(if $ses == "" then null else $ses end), task_ref:$r, allowed_actions:$acts, pr_url:(if $pr == "" then null else $pr end), text:$t,
            review:(if $rv == "" then null else {pr:($rv | split("@")[0]), head:($rv | split("@")[1])} end),
            owner_input: (if $need == "" then null else $need end), approval_required:true, error:null}')
        if [ ! -f "$dir/$id.json" ]; then
          [ -n "$rec" ] && printf '%s\n' "$rec" > "$dir/$id.json.tmp" && mv "$dir/$id.json.tmp" "$dir/$id.json" || fail 2 state_write_failed "could not write the draft under $dir" "$ctx"
        fi
        emit "$(jq -c '.' "$dir/$id.json")"
      '';
    };

    "coord:report" = {
      description = "Read-only engineering-effectiveness report (skills #85, M0a) over a window (default last 7 days) of the audit log and the GitHub PR record: issue→handoff→reviewed PR→merge correlation, verified deliveries per day/week (merged with a signed independent ≥9 on the merged head), authorization→merge lead time, review pass/rework/repeated counts, and blocked time by bounded reason. Every metric carries {value, coverage_pct, observed_from, unknown_reason}; aggregates and source refs only, never scope text, bodies, prompts or commands. Token, skill-invocation and runtime-resource metrics are marked unavailable in this slice.";
      input = { since = null; until = null; days = null; limit = null; };
      exec = ''
        ${cfg.prelude}
        at=$(now_iso)
        since=$(input .since); until=$(input .until); days=$(input .days); limit=$(input .limit)
        [ -n "$days" ] || days=7
        [[ "$days" =~ ^[0-9]+$ ]] || fail 3 invalid_input "days must be a non-negative integer" '{"task":"coord:report"}'
        [ -n "$limit" ] || limit=100
        [[ "$limit" =~ ^[0-9]+$ ]] && [ "$limit" -ge 1 ] && [ "$limit" -le 100 ] || fail 3 invalid_input "limit must be 1..100 (GitHub's page cap)" '{"task":"coord:report"}'
        [ -n "$until" ] || until="$at"
        [ -n "$since" ] || since=$(date -u -d "$days days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || fail 3 invalid_input "could not compute the window start" '{"task":"coord:report"}'
        # a since/until the owner passed must be ISO-8601 Z; a bad one is rejected, never silently widened
        for v in "$since" "$until"; do [[ "$v" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || fail 3 invalid_input "since/until must be YYYY-MM-DDTHH:MM:SSZ" '{"task":"coord:report"}'; done
        tmpd=$(mktemp -d); trap 'rm -rf "$tmpd"' EXIT
        # the audit window: object rows in [since, until). A log that is not JSON lines is a failed source, never "no evidence"
        audit="${cfg.stateDir}/audit.jsonl"; audit_err="null"
        printf '[]\n' > "$tmpd/audit.json"
        if [ -s "$audit" ]; then
          jq -s --arg s "$since" --arg u "$until" 'map(select(type == "object" and (.at // "") >= $s and (.at // "") < $u))' "$audit" > "$tmpd/audit.json" 2>/dev/null \
            || { printf '[]\n' > "$tmpd/audit.json"; audit_err=$(jq -cn --arg a "$audit" '{kind:"audit_corrupt", message:("audit log " + $a + " is not valid JSON lines")}'); }
        fi
        # repos the window names (a handoff's authorized_by.issue_url, or a gh:* row's repo); GitHub PRs fetched once each,
        # the same list path work:status uses. A failed or truncated list is recorded, not hidden. Only the fields report.jq
        # reads are requested, so a larger page does not blow GitHub's GraphQL node budget (shared with coord:report:daily).
        aggctx='{"task":"coord:report"}'
        ${reportAggregate}
        emit "$(jq -c --argjson e "$audit_err" '. + {audit_path:"'"$audit"'", handoffs_error:$e}' <<<"$rep")"
      '';
    };

    "coord:feedback" = {
      description = "Record one engineering-effectiveness feedback item (skills #85 M0b, Deliverable B) as a phase:\"feedback\" audit row: a bounded taxonomy kind (${lib.concatStringsSep ", " feedbackTaxonomy}) and evidence references only -- GitHub issue/PR URLs or 12-hex audit ids -- never scope text, bodies, prompts or commands. Surfaced in coord:report:weekly.";
      input = { taxonomy = null; evidence = null; host = null; };
      exec = ''
        ${cfg.prelude}
        ctx='{"task":"coord:feedback"}'
        tax=$(input .taxonomy); host=$(input .host)
        ev=$(jq -c '.evidence // []' <<<"''${DEVENV_TASK_INPUT:-{\}}")
        case "$tax" in ${lib.concatStringsSep "|" feedbackTaxonomy}) ;; *) fail 3 invalid_input "taxonomy must be one of ${lib.concatStringsSep ", " feedbackTaxonomy}" "$ctx" ;; esac
        jq -e 'type == "array" and length >= 1 and length <= 20 and all(.[]; type == "string" and (test("^https://github\\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/(issues|pull)/[1-9][0-9]*(#issuecomment-[0-9]+)?$") or test("^[a-f0-9]{12}$")))' <<<"$ev" >/dev/null 2>&1 \
          || fail 3 invalid_input "evidence must be a non-empty list (at most 20) of GitHub issue/PR URLs or 12-hex audit ids; nothing else, so no scope text can enter" "$ctx"
        [ -z "$host" ] || valid_machine "$host" || fail 3 invalid_input "host has unsafe characters" "$ctx"
        audit="${cfg.stateDir}/audit.jsonl"; mkdir -p "${cfg.stateDir}"; touch "$audit"
        exec 9>"$audit.lock"; flock -w 10 9 || fail 2 busy "another act holds the audit lock" "$ctx"
        aid=$(printf 'feedback|%s|%s' "$(now_iso)" "$RANDOM$RANDOM" | sha256sum | cut -c1-12); at=$(now_iso)
        row=$(jq -cn --arg a "$aid" --arg t "$tax" --argjson e "$ev" --arg h "$host" --arg at "$at" \
          '{audit_id:$a, phase:"feedback", task:"coord:feedback", taxonomy:$t, evidence_refs:$e, host:(if $h == "" then null else $h end), at:$at}')
        printf '%s\n' "$row" >> "$audit" || fail 2 audit_failed "could not write the feedback row" "$ctx"
        emit "$(jq -cn --argjson r "$row" '{schema_version:1} + $r + {error:null}')"
      '';
    };

    "coord:report:daily" = {
      description = "Write ${cfg.stateDir}/report/daily/YYYY-MM-DD.json: coord:report's aggregates for one UTC day ([date,date+1)), recomputed from the sources and overwritten each run so a re-run over unchanged sources yields an identical file (observed_at is pinned to the day, not the wall clock). A sources.audit block records the matching audit line range and a sha256 of exactly those lines, so a partial or changed input is visible. Aggregates and source refs only.";
      input = { date = null; limit = null; };
      exec = ''
        ${cfg.prelude}
        at=$(now_iso)
        date=$(input .date); limit=$(input .limit)
        [ -n "$date" ] || date=$(date -u -d "yesterday" +%Y-%m-%d 2>/dev/null) || fail 3 invalid_input "could not compute yesterday's date" '{"task":"coord:report:daily"}'
        [[ "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || fail 3 invalid_input "date must be YYYY-MM-DD" '{"task":"coord:report:daily"}'
        [ -n "$limit" ] || limit=100
        [[ "$limit" =~ ^[0-9]+$ ]] && [ "$limit" -ge 1 ] && [ "$limit" -le 100 ] || fail 3 invalid_input "limit must be 1..100 (GitHub's page cap)" '{"task":"coord:report:daily"}'
        since="''${date}T00:00:00Z"; days=1
        until=$(date -u -d "$date +1 day" +%Y-%m-%dT00:00:00Z 2>/dev/null) || fail 3 invalid_input "could not compute the day end from $date" '{"task":"coord:report:daily"}'
        tmpd=$(mktemp -d); trap 'rm -rf "$tmpd"' EXIT
        audit="${cfg.stateDir}/audit.jsonl"; audit_err="null"
        printf '[]\n' > "$tmpd/audit.json"
        # line provenance: the file's total lines, and the 1-based line numbers of the object rows whose .at falls in the
        # window, with a sha256 over exactly those raw lines (file order). A changed or partially-written log changes the hash.
        lines_total=0; line_first=null; line_last=null; sha=""; rows_in_window=0
        if [ -s "$audit" ]; then
          lines_total=$(wc -l < "$audit" | tr -d ' ')
          jq -s --arg s "$since" --arg u "$until" 'map(select(type == "object" and (.at // "") >= $s and (.at // "") < $u))' "$audit" > "$tmpd/audit.json" 2>/dev/null \
            || { printf '[]\n' > "$tmpd/audit.json"; audit_err=$(jq -cn --arg a "$audit" '{kind:"audit_corrupt", message:("audit log " + $a + " is not valid JSON lines")}'); }
          if [ "$audit_err" = null ]; then
            jq -rc --arg s "$since" --arg u "$until" 'select(type == "object" and (.at // "") >= $s and (.at // "") < $u) | input_line_number' "$audit" > "$tmpd/lines" 2>/dev/null || : > "$tmpd/lines"
            rows_in_window=$(grep -c . "$tmpd/lines" || true)
            if [ "''${rows_in_window:-0}" -gt 0 ]; then
              line_first=$(head -1 "$tmpd/lines"); line_last=$(tail -1 "$tmpd/lines")
              sha=$(awk 'NR==FNR{want[$1]=1;next} (FNR in want)' "$tmpd/lines" "$audit" | sha256sum | cut -d' ' -f1)
            fi
          fi
        fi
        src_audit=$(jq -cn --arg p "$audit" --argjson lt "''${lines_total:-0}" --argjson rw "''${rows_in_window:-0}" --argjson lf "''${line_first:-null}" --argjson ll "''${line_last:-null}" --arg sha "$sha" \
          '{path:$p, present:($lt > 0), lines_total:$lt, rows_in_window:$rw, line_first:$lf, line_last:$ll, sha256:(if $sha == "" then null else $sha end)}')
        aggctx='{"task":"coord:report:daily"}'
        ${reportAggregate}
        daily="${cfg.stateDir}/report/daily"; mkdir -p "$daily"
        # pin observed_at to the day and fold the line provenance into sources.audit, so a re-run over unchanged sources is
        # byte-identical; carry audit_err and the daily path as refs
        out=$(jq -c --argjson sa "$src_audit" --argjson e "$audit_err" --arg d "$date" --arg a "$audit" \
          '.task = "coord:report:daily" | .observed_at = ($d + "T00:00:00Z") | .generated_for = $d
           | .sources.audit = (.sources.audit + $sa) | . + {audit_path:$a, handoffs_error:$e, daily_path:"'"$daily"'/'"$date"'.json"}' <<<"$rep") \
          || fail 2 internal "coord:report:daily could not assemble the daily record" "$aggctx"
        printf '%s\n' "$out" > "$daily/$date.json.tmp" && mv "$daily/$date.json.tmp" "$daily/$date.json" \
          || fail 2 write_failed "could not write $daily/$date.json" "$aggctx"
        emit "$out"
      '';
    };

    "coord:report:weekly" = {
      description = "Render ${cfg.stateDir}/report/weekly/<ISO-week>.md from the dailies of the ISO week containing the anchor date (default today): delivered and verified, review stats, blocked/waste (parks, blocked spans, refusals), recurring failures and the feedback taxonomy, three ranked improvements with their evidence, and one experiment with a measurable success criterion. Reads daily files and the feedback rows of the audit; aggregates and source refs only, never scope text.";
      input = { anchor = null; };
      exec = ''
        ${cfg.prelude}
        ctx='{"task":"coord:report:weekly"}'
        anchor=$(input .anchor); [ -n "$anchor" ] || anchor=$(date -u +%Y-%m-%d)
        [[ "$anchor" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || fail 3 invalid_input "anchor must be YYYY-MM-DD" "$ctx"
        isoweek=$(date -u -d "$anchor" +%G-W%V 2>/dev/null) || fail 3 invalid_input "could not parse anchor $anchor" "$ctx"
        dow=$(date -u -d "$anchor" +%u); monday=$(date -u -d "$anchor -$((dow-1)) days" +%Y-%m-%d)
        sunday=$(date -u -d "$monday +6 days" +%Y-%m-%d); weekend=$(date -u -d "$monday +7 days" +%Y-%m-%dT00:00:00Z)
        since="''${monday}T00:00:00Z"
        daily="${cfg.stateDir}/report/daily"; tmpd=$(mktemp -d); trap 'rm -rf "$tmpd"' EXIT
        # gather the dailies present for the seven days; a missing day is a coverage gap, never a zero
        : > "$tmpd/days.jsonl"
        for i in 0 1 2 3 4 5 6; do
          d=$(date -u -d "$monday +$i days" +%Y-%m-%d); f="$daily/$d.json"
          if [ -r "$f" ] && jq -e 'type == "object"' "$f" >/dev/null 2>&1; then jq -c --arg d "$d" '{date:$d, present:true, report:.}' "$f"
          else jq -cn --arg d "$d" '{date:$d, present:false, report:null}'; fi >> "$tmpd/days.jsonl"
        done
        # feedback rows of the week, from the audit (phase:"feedback"); evidence refs only
        audit="${cfg.stateDir}/audit.jsonl"; printf '[]\n' > "$tmpd/fb.json"
        [ ! -s "$audit" ] || jq -s --arg s "$since" --arg u "$weekend" 'map(select(type == "object" and .phase == "feedback" and (.at // "") >= $s and (.at // "") < $u) | {taxonomy, evidence_refs, host, at})' "$audit" > "$tmpd/fb.json" 2>/dev/null || printf '[]\n' > "$tmpd/fb.json"
        weekly="${cfg.stateDir}/report/weekly"; mkdir -p "$weekly"; md="$weekly/$isoweek.md"
        # a static taxonomy -> remediation map (engineering judgement, not leaked data) so the ranked improvements read as
        # actions; the ranking is by observed frequency, the evidence is each taxonomy's own feedback refs
        remedy=$(jq -cn '{
          auth_contradiction:"Make the authorization/merge rule single-sourced and self-checking so an item cannot both authorize and be refused.",
          wrong_assignment:"Tighten coord:handoff target selection (capability + current state) so a handoff cannot reach the wrong pane.",
          review_deadlock:"Add a review-recovery path that re-offers a head when a review yields no grade, so a PR cannot stall unreviewed.",
          repeated_build:"Cache or gate heavy builds (one per changed tree) so the same closure is not rebuilt across sessions.",
          stale_lock_or_orphan:"Bound and sweep scratch dirs and stale flocks (age-based cleanup) so orphans cannot fill a disk or hold a lock.",
          false_success:"Require independent evidence (exit code + head sha) before a delivery counts, so a worker-asserted pass cannot stand alone.",
          misleading_skill:"Pin and test skill commands against the installed binary so a stale skill command is caught, not followed.",
          missing_tool:"Make a suite skip with a named reason when its environment is absent, and count the run as unsupported_environment, not a failure."}')
        jq -rn --slurpfile days "$tmpd/days.jsonl" --slurpfile fb "$tmpd/fb.json" --argjson remedy "$remedy" \
          --arg week "$isoweek" --arg monday "$monday" --arg sunday "$sunday" --arg at "$(now_iso)" '
          ($days) as $days | ($fb[0] // []) as $fb
          | [ $days[] | select(.present) | .report ] as $present
          | ([ $days[] | select(.present | not) | .date ]) as $missing
          | def msum(path): [ $present[] | (path // 0) ] | add // 0;
          # delivery and review summed across the present dailies; a metric is counted only where coverage was full that day
          ($present | map(.metrics.verified_deliveries) | map(select(.value != null)) ) as $vd
          | ($present | map(.metrics.review) | map(select(.value != null)) ) as $rv
          | ($present | map(.metrics.blocked_time.value) | map(select(. != null)) ) as $bt
          | ($present | map(.metrics.refusals.value) | map(select(. != null)) ) as $rf
          | { verified_total:([ $vd[].value.total ] | add // 0),
              per_day:(reduce ($present[] | {k:(.generated_for // .window.since[0:10]), v:(.metrics.verified_deliveries.value.total // 0)}) as $x ({}; .[$x.k] = $x.v)),
              reviewed:([ $rv[].value.prs_reviewed ] | add // 0), passes:([ $rv[].value.passes ] | add // 0),
              rework:([ $rv[].value.rework_rounds ] | add // 0), repeated:([ $rv[].value.repeated_reviews ] | add // 0),
              parked:([ $bt[].parked_events ] | add // 0),
              blocked_seconds:([ $bt[] | (.by_reason | to_entries[] | .value.seconds // 0) ] | add // 0),
              refused_total:([ $rf[].total ] | add // 0),
              refused_by_kind:(reduce ($rf[] | .by_kind | to_entries[]) as $e ({}; .[$e.key] = ((.[$e.key] // 0) + $e.value))) } as $agg
          | ([ $fb[] | .taxonomy ] | group_by(.) | map({kind:.[0], n:length}) | sort_by(-.n)) as $fb_ranked
          | ([ $fb_ranked[] | .kind as $k | {kind:$k, n, remedy:($remedy[$k] // $k), evidence:([ $fb[] | select(.taxonomy == $k) | .evidence_refs[] ] | unique)} ]) as $improvements_fb
          # pad to at least three with standing engineering-backlog improvements (coverage-driven), so the report always ranks three
          | ([ {kind:"authorization_join_coverage", n:0, remedy:"Widen the authorization->merge join so lead time covers most deliveries, not the few whose handoff names the delivered issue (M0a reported ~2% coverage).", evidence:["https://github.com/sammasak/skills/issues/85"]},
               {kind:"deploy_m0b_instrumentation", n:0, remedy:"Deploy the M0b refused/state instrumentation fleet-wide so refusals and idle/blocked spans are observed, not inferred.", evidence:["https://github.com/sammasak/skills/issues/85"]},
               {kind:"token_runtime_coverage", n:0, remedy:"Project harness-session message.usage and export run.log peaks so token and runtime metrics stop reading unavailable.", evidence:["https://github.com/sammasak/skills/issues/85"]} ]) as $backlog
          | (($improvements_fb + $backlog)[0:3]) as $top3
          | ($fb_ranked[0].kind // "stale_lock_or_orphan") as $exp_kind
          | ("# Engineering-effectiveness weekly — \($week)\n"
            + "\nWindow: \($monday) .. \($sunday) (UTC, ISO week \($week)). Generated \($at). Aggregates and source refs only.\n"
            + "\n## Coverage\n"
            + "- Dailies present: \(($days | map(select(.present)) | length))/7"
            + (if ($missing | length) > 0 then "; missing (gap, not zero): \($missing | join(", "))" else "" end) + "\n"
            + "\n## Delivery\n- Verified deliveries: **\($agg.verified_total)**\n"
            + (($agg.per_day | to_entries | sort_by(.key) | map("  - \(.key): \(.value)") | join("\n")) + "\n")
            + "\n## Review\n- PRs reviewed: \($agg.reviewed); passes: \($agg.passes); rework rounds: \($agg.rework); repeated reviews: \($agg.repeated)\n"
            + "\n## Waste / retries\n- Parked (agent_busy) events: \($agg.parked)\n- Blocked span seconds (needs-decision/blocked/needs-live): \($agg.blocked_seconds)\n- Refused sends + failed lifts: \($agg.refused_total)"
            + (($agg.refused_by_kind | to_entries | map(select(.value > 0)) | map("\(.key)=\(.value)")) as $rk | if ($rk | length) > 0 then " (" + ($rk | join(", ")) + ")" else "" end) + "\n"
            + "\n## Recurring failures (feedback taxonomy)\n"
            + (if ($fb_ranked | length) == 0 then "- none recorded this week\n" else (($fb_ranked | map("- \(.kind): \(.n)") | join("\n")) + "\n") end)
            + "\n## Feedback records (evidence refs only)\n"
            + (if ($fb | length) == 0 then "- none\n" else (($fb | map("- \(.taxonomy)\(if .host then " [" + .host + "]" else "" end): \(.evidence_refs | join(", "))") | join("\n")) + "\n") end)
            + "\n## Three improvements (ranked by expected engineering impact)\n"
            + ([ range(0; ($top3 | length)) as $i | "\($i + 1). **\($top3[$i].kind)** — \($top3[$i].remedy) Evidence: \($top3[$i].evidence | join(", "))" ] | join("\n")) + "\n"
            + "\n## Experiment (one, measurable)\n"
            + "- Hypothesis: acting on **\($exp_kind)** reduces its recurrence. Intervention: apply the ranked-#1 remedy for one week.\n"
            + "- Success criterion (paired: a hand-entered count AND an observed signal, so it cannot be met by simply not recording): the \($exp_kind) feedback count for the following ISO week drops by >=50%, AND the observed waste signal (parked + refused events that week, read from the audit by coord:report, not hand-entered) does not rise, at the same or higher verified-delivery total; measured by coord:report:weekly over that next week.\n")
          ' > "$tmpd/md" || fail 2 internal "coord:report:weekly render failed" "$ctx"
        mv "$tmpd/md" "$md"
        emit "$(jq -cn --arg w "$isoweek" --arg p "$md" --slurpfile days "$tmpd/days.jsonl" --slurpfile fb "$tmpd/fb.json" \
          '{schema_version:1, task:"coord:report:weekly", iso_week:$w, weekly_path:$p,
            dailies_present:([ $days[] | select(.present) ] | length), dailies_missing:([ $days[] | select(.present | not) | .date ]),
            feedback_records:($fb[0] | length), error:null}')"
        cat "$md"
      '';
    };
  };
}
