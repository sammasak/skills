# Coordinator role DAG: work:status joins live Herdr state (this host + saved machines) with GitHub
# evidence for agents whose title names OWNER/REPO#N; coord:brief renders it. Failed sources are
# reported as partial, never hidden.
{ lib, config, ... }:

let
  cfg = config.coordinator;
  handoffsKept = 50;
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
                   allowed_actions:($a.allowed_actions // []), authorized_by:$auth, task_ref:($a.task_ref // null),
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
            --json number,title,body,state,mergedAt,createdAt,url,headRefName,headRefOid,closingIssuesReferences,statusCheckRollup,comments,reviews > "$tmpd/p.json" 2>/dev/null || rc=$?
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
          -f ${./correlate.jq} > "$tmpd/corr.json" || fail 2 internal "work:status correlation failed" '{"task":"work:status"}'
        failed=$(jq -c --argjson e "$audit_err" '[(.hosts[] | select(.reachable == false) | {source:("herdr:inventory:" + .host), error})] + (if .machines_error != null then [{source:"herdr:machine-list", error:.machines_error}] else [] end)
          + (if $e != null then [{source:"coordinator:audit", error:$e}] else [] end)' <<<"$inv")
        emit "$(jq -c --arg at "$at" --argjson inv "$inv" --argjson f "$failed" --arg a "$audit" --argjson e "$audit_err" \
          '. as $c | {schema_version:1, task:"work:status", observed_at:$at, answered_hosts:($inv.answered_hosts // 0), hosts_total:($inv.hosts_total // 0), machines_configured:($inv.machines_configured // 0),
            failed_sources:$f, partial:(($f|length) > 0), items:$c.items, handoffs:$c.handoffs, handoffs_omitted:$c.handoffs_omitted, audit_path:$a, handoffs_error:$e}' "$tmpd/corr.json")"
      '';
    };

    "coord:brief" = {
      description = "Owner-facing brief: items needing input first, every agent with herdr_state and work_verdict, handoffs from the audit log, and the owner's portfolio (gh:repos, gh:work for active repos only).";
      after = [ "work:status@completed" "gh:repos@completed" ];
      exec = ''
        ${cfg.prelude}
        # the previous latest.md goes first: a run that fails before rendering leaves none, never a stale one to read
        dir="${cfg.stateDir}/brief"; mkdir -p "$dir"; rm -f "$dir/latest.md"
        ws=$(upstream "work:status")
        [ "$ws" != null ] || fail 2 missing "work:status produced no output" '{"task":"coord:brief"}'
        # portfolio: gh:repos names the owner's repositories; gh:work runs only for the active ones (an open PR or an
        # issue with an authorizing label), newest push first, at most portfolioActive of them; the rest are named, not
        # fetched. GitHub being down leaves the agent part of the brief whole: the portfolio carries its own error and
        # is not a failed source of the fleet picture
        repos=$(upstream "gh:repos"); portfolio_err="null"; active="[]"; skipped="[]"; ptotal=0; plisted=0; ptrunc=false
        if [ "$repos" = null ]; then portfolio_err='{"kind":"missing","message":"gh:repos produced no output"}'
        elif [ "$(jq -r '.error != null' <<<"$repos")" = true ]; then portfolio_err=$(jq -c .error <<<"$repos")
        else
          ptotal=$(jq -r '.total // 0' <<<"$repos"); plisted=$(jq -r '.listed // 0' <<<"$repos"); ptrunc=$(jq -r '.truncated // false' <<<"$repos")
          while IFS= read -r repo; do
            [ -n "$repo" ] || continue
            if [ "$(jq -r length <<<"$active")" -ge ${toString cfg.portfolioActive} ]; then skipped=$(jq -c --arg r "$repo" '. + [$r]' <<<"$skipped"); continue; fi
            w=$(gh_work_json "$repo")
            active=$(jq -c --argjson w "$w" --argjson labels ${lib.escapeShellArg (builtins.toJSON cfg.authorizingLabels)} --argjson r "$(jq -c --arg r "$repo" '[.repos[] | select(.repo == $r)] | first' <<<"$repos")" \
              '. + [$r + {error:$w.error, truncated:($w.truncated // false),
                          approved:([$w.issues[]? | select(any((.labels // [])[]; . as $l | ($labels | index($l)) != null)) | {number, title, url, labels}]),
                          open_pr_list:([$w.prs[]? | select(.state == "OPEN") | {number, title, url, review_decision, draft, checks}])}]' <<<"$active")
          done < <(jq -r '.repos[] | select(.active) | .repo' <<<"$repos")
        fi
        portfolio=$(jq -cn --arg o "${cfg.ghOwner}" --argjson labels ${lib.escapeShellArg (builtins.toJSON cfg.authorizingLabels)} --argjson t "$ptotal" --argjson l "$plisted" --argjson tr "$ptrunc" --argjson a "$active" --argjson s "$skipped" --argjson e "$portfolio_err" \
          '{owner:$o, authorizing_labels:$labels, repos_total:$t, repos_listed:$l, truncated:$tr, active:$a, skipped_active:$s, error:$e}')
        brief=$(jq -c --argjson p "$portfolio" '. + {task:"coord:brief", portfolio:$p}' <<<"$ws")
        printf '%s\n' "$brief" > "$dir/latest.json.tmp" && mv "$dir/latest.json.tmp" "$dir/latest.json"
        printf '%s\n' "$brief" > "''${DEVENV_TASK_OUTPUT_FILE:-/dev/null}"
        # the Markdown is the default read (latest.md): devenv's stdout carries every task's JSON, which the runbook's
        # default command sends to /dev/null; latest.json keeps the full record
        jq -r --arg f "$dir/latest.json" '
          "# Fleet brief (\(.observed_at))",
          "", "Hosts: this one" + (if .machines_configured > 0 then " + \(.machines_configured) saved herdr machine(s)" else " only (`herdr machine add` adds workers)" end) + "; \(.answered_hosts)/\(.hosts_total) answered",
          (if .partial then "", "**Partial:** " + ([.failed_sources[] | "\(.source): \(.error.kind) — \(.error.message)"] | join("; ")) else empty end),
          "", "## Needs you",
          (([.items[] | select(.needs_owner)] | if length == 0 then ["- nothing"] else (.[0:10] | map("- \(.host)/\(.agent_id) (\(.harness)) \(.task_ref // "no ref"): herdr=\(.herdr_state) → \(.reasons | join("; "))")) + (if length > 10 then ["… \(length - 10) more needing you in the JSON"] else [] end) end)[]),
          # compact by default: verified handoffs as one line per repo#ref (an open epic does not hide them), then each open
          # or unverified handoff with its stages; everything else is in the JSON
          (([.handoffs[] | select(.work_verdict == "verified")]) as $done | ([.handoffs[] | select(.work_verdict != "verified")]) as $open
          | def mark($k): "\($k) \(if .stages[$k] then "✓" else "–" end)";
          "", "## Handoffs (from the audit log): \((.handoffs|length) + (.handoffs_omitted // 0)) total, \($done|length) verified, \($open|length) open" + (if (.handoffs_omitted // 0) > 0 then " (the oldest \(.handoffs_omitted) not evaluated)" else "" end),
          (if .handoffs_error != null then "- unreadable: \(.handoffs_error.kind) — \(.handoffs_error.message)" elif (.handoffs|length) == 0 then "- none" else
            ($done | group_by([.repo, .task_ref])[] | "- verified \(.[0].repo)\(.[0].task_ref)\(if .[0].task_issue_open then " (still open)" else "" end): merged "
               + ([.[].stages.merged[]? | capture("/pull/(?<n>[0-9]+)$").n | tonumber] | unique | map("#\(.)") | join(" "))),
            ($open[-20:][] | "- \(.handoff_id) → \(.host)/\(.agent_id) \(.task_ref // "-") \(.repo // "no repo") | sent \(.sent_at) | \(.outcome) | "
               + ([mark("implemented"), mark("reviewed"), mark("merged"), mark("live")] | join(" ")) + " | work=\(.work_verdict)"
               + (if .stale then " | STALE" else "" end) + (if (.reasons|length) > 0 then " | " + (.reasons | join("; ")) else "" end)),
            (if ($open|length) > 20 then "… \(($open|length) - 20) more open handoffs in the JSON" else empty end) end)),
          "", "## Portfolio (\(.portfolio.owner): \(.portfolio.repos_listed) of \(.portfolio.repos_total) repos by recent push\(if .portfolio.truncated then ", truncated at the cap" else "" end); authorizing labels: \(.portfolio.authorizing_labels | join(", ")))",
          (if .portfolio.error != null then "- unavailable (agents above are unaffected): \(.portfolio.error.kind) — \(.portfolio.error.message)"
           elif (.portfolio.active|length) == 0 then "- no repo with an open PR or an approved issue"
           else (.portfolio.active[] | "- \(.repo): \(.open_prs) open PR(s), \(.approved_issues) approved issue(s)" + (if (.approved|length) > 0 then " → " + ([.approved[] | "#\(.number) \(.title)"] | join("; ")) else "" end) + (if .error != null then " (gh:work: \(.error.kind))" else "" end)) end),
          (if (.portfolio.skipped_active|length) > 0 then "- active but not expanded (cap \(.portfolio.active|length)): \(.portfolio.skipped_active | join(", "))" else empty end),
          "", "Full JSON: \($f)", "", "## Agents",
          (if (.items|length) == 0 then "- none observed" else (.items[0:30][] | "- \(.host)/\(.agent_id) \(.harness) \(.task_ref // "-") | herdr=\(.herdr_state) | work=\(.work_verdict)\(if .evidence_ref then " " + .evidence_ref else "" end)\(if (.reasons|length) > 0 and .correlation.by != "none" then " | " + (.reasons | join("; ")) else "" end)") end),
          (if (.items|length) > 30 then "… \((.items|length) - 30) more agents in the JSON" else empty end)
        ' <<<"$brief" > "$dir/latest.md.tmp" || { rm -f "$dir/latest.md.tmp"; fail 2 internal "coord:brief Markdown render failed" '{"task":"coord:brief"}'; }
        mv "$dir/latest.md.tmp" "$dir/latest.md" && cat "$dir/latest.md"
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
