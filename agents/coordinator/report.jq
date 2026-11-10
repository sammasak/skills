# coord:report M0a (skills #85): read-only aggregation over a window of the coordinator audit log and the GitHub PR
# record. Inputs (jq -n): $audit (array of audit.jsonl rows in [since,until)), $repos ({"OWNER/REPO":{prs,error,limit}}
# from the same gh pr list path work:status uses), $window ({since,until,days}), $at.
#
# Evidence rules are reused from evidence.jq (refs, grade, signer, own_grade, notes, passes). PR->issue ownership and the
# "a grade on the PR's head by its own implementer does not count" independence rule mirror correlate.jq. Every metric is
# {value, coverage_pct, observed_from, unknown_reason}; value is null (never 0) when a source is absent, 0 only when the
# source was read and observed none. The output carries aggregates and source refs (audit_id, handoff_id, PR url, issue
# number) ONLY -- never scope text, bodies, prompts or commands (docs/measurement.md, "Privacy").

include "evidence";

$audit[0] as $audit | $repos[0] as $repos | $window as $w | $at as $now

# --- repo coverage: which repos the window names, and which GitHub answered for ---------------------------------------
| ([ $audit[]
     | (.authorized_by.issue_url // "" | [capture("^https://github\\.com/(?<r>[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/(issues|pull)/(?<n>[0-9]+)")] | first) as $iss
     | ( if $iss != null then $iss.r else empty end ),
       ( if (.phase == "gh" and (.repo // null) != null) then .repo else empty end ) ]
   | unique) as $repos_named
# a repo's window is fully covered when GitHub answered and the list was not cut inside the window: either it did not hit
# the fetch limit, or the oldest PR it returned was created before the window start (so any older ones are out of range).
| ($repos_named | map(. as $r | ($repos[$r] // null) as $d
    | (($d.prs // []) | length) as $n
    | ($n >= ($d.limit // 1e9)) as $trunc
    | ([ ($d.prs // [])[].createdAt ] | min) as $oldest
    | {repo:$r, error:(if $d == null then "not fetched" else $d.error end), ok:($d != null and $d.error == null),
       prs_fetched:$n, limit:($d.limit // null),
       truncated:($d != null and $d.error == null and $trunc),
       window_covered:($d != null and $d.error == null and ((($trunc | not)) or ($oldest != null and $oldest <= $w.since)))})) as $repo_cov
| (($repo_cov | map(select(.ok)) | length)) as $repos_ok
| (($repo_cov | map(select(.window_covered)) | length)) as $repos_covered
| (($repo_cov | length)) as $repos_total
| (if $repos_total == 0 then 0 else (($repos_covered * 100 / $repos_total) | floor) end) as $repo_cov_pct

# --- authorization times from the audit, per repo#number -------------------------------------------------------------
# earliest "gh:label add approved" attempt row for an issue, else the earliest handoff attempt whose authorized_by names
# it (labeled_at when present, else the send time). Keyed "OWNER/REPO#N".
| ([ $audit[]
     | if (.phase == "gh" and .task == "gh:label" and .action == "add" and .label == "approved" and .stage == "attempt" and (.repo // null) != null and (.number // null) != null)
       then {key:"\(.repo)#\(.number)", at:.at, from:"gh_label"}
       else ( (.authorized_by.issue_url // "" | [capture("^https://github\\.com/(?<r>[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/(issues|pull)/(?<n>[0-9]+)")] | first) as $iss
              | if ($iss != null and .phase == "attempt") then {key:"\($iss.r)#\($iss.n)", at:(.authorized_by.labeled_at // .at), from:"handoff_label"} else empty end ) end ]
   | group_by(.key) | map({key:.[0].key, at:(min_by(.at).at), from:(min_by(.at).from)}) | INDEX(.key)) as $auth_by_issue

# --- per-PR evidence, over every fetched repo ------------------------------------------------------------------------
# implementers of an issue (to enforce review independence) = the host/agent of every handoff whose authorized_by names
# that issue; a grade signed by one of them is not an independent pass.
| ([ $audit[] | select(.phase == "attempt")
     | (.authorized_by.issue_url // "" | [capture("^https://github\\.com/(?<r>[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/(issues|pull)/(?<n>[0-9]+)")] | first) as $iss
     | if $iss != null then {key:"\($iss.r)#\($iss.n)", impl:"\(.host)/\(.agent_id)"} else empty end ]
   | group_by(.key) | map({key:.[0].key, impl:([.[].impl] | unique)}) | INDEX(.key)) as $impl_by_issue

# a grade note's head token = the first 7-40 hex sha in its body (the reviewer convention stamps the graded head), or the
# PR's current head when the note cites it and names no sha; used to split rounds across heads without historical fetches.
| def head_token($cur): (.body | [scan("(?<![0-9a-f])[0-9a-f]{7,40}(?![0-9a-f])")] | first) as $sha
    | if $sha != null then $sha elif ($cur != "" and (.body | contains($cur[0:7]))) then $cur else "unknown" end;

([ $repos_named[] | . as $r | ($repos[$r] // null) as $d
    | if ($d == null or $d.error != null) then empty
      else $d.prs[]
        | (.headRefOid // "") as $head
        | (.closingIssuesReferences // []) as $cir
        | ([ $cir[].number ] | first) as $closes
        | "\($r)#\($closes)" as $issue_key
        | ($impl_by_issue[$issue_key].impl // []) as $impl
        | [ notes[] | select(.grade != null and .by != null) ] as $gnotes
        | ([ $gnotes[] | . + {head:head_token($head)} ] | group_by(.head)) as $rounds
        | (passes | map(select(.by as $b | $impl | index($b) | not))) as $indep_pass
        | {repo:$r, number:.number, url:.url, head:(if $head == "" then null else $head end),
           state:.state, merged_at:.mergedAt, created_at:.createdAt, closes:$closes,
           graded:(($gnotes | length) > 0),
           independent_pass:(($indep_pass | length) > 0),
           rounds:($rounds | length),
           rework_rounds:([ $rounds[] | select(any(.[]; .grade < 9)) ] | length),
           repeated_rounds:([ $rounds[] | select(length >= 2) ] | length)}
      end ]) as $prs

# --- verified deliveries: merged in window, independent >=9 on the merged head, de-duped by closed issue (first merge) --
| ([ $prs[] | select(.merged_at != null and .merged_at >= $w.since and .merged_at < $w.until and .independent_pass) ]) as $verified_prs
| ($verified_prs | group_by(.closes // .url) | map(min_by(.merged_at))) as $verified
| ([ $prs[] | select(.merged_at != null and .merged_at >= $w.since and .merged_at < $w.until) ]) as $merged_in_window
| (def bucket(f): $verified | map(.merged_at | f) | group_by(.) | map({key:.[0], value:length}) | from_entries;
   { total:($verified | length),
     per_day:(bucket(.[0:10])),
     per_week:(bucket(fromdateiso8601 | strftime("%G-W%V"))) }) as $deliv_val

# --- authorization -> merge lead time, for the verified deliveries we have an authorization time for --------------------
| ([ $verified[] | ($auth_by_issue["\(.repo)#\(.closes)"] // null) as $a
     | if $a != null then ((.merged_at | fromdateiso8601) - ($a.at | fromdateiso8601)) else empty end ]) as $leads
| (($leads | length)) as $lead_n
| (if $lead_n == 0 then null
   else ($leads | sort) as $s
     | {n:$lead_n, median_seconds:($s[($lead_n/2|floor)]), min_seconds:$s[0], max_seconds:$s[-1]} end) as $lead_val

# --- review pass / rework / repeated, over PRs graded in the window ---------------------------------------------------
| ([ $prs[] | select(.graded and ((.merged_at != null and .merged_at >= $w.since and .merged_at < $w.until)
                                   or (.created_at >= $w.since and .created_at < $w.until))) ]) as $reviewed
| ({ prs_reviewed:($reviewed | length),
     passes:([ $reviewed[] | select(.independent_pass) ] | length),
     rework_rounds:([ $reviewed[] | .rework_rounds ] | add // 0),
     repeated_reviews:([ $reviewed[] | .repeated_rounds ] | add // 0) }) as $review_val

# --- blocked time by bounded reason ----------------------------------------------------------------------------------
# parked(agent_busy): each park is one observation of a pane held off; we report the count and, when a later delivered
# outcome for the same pane exists, the summed wait to it. needs-decision/blocked/needs-live: span from a gh:label add to
# its matching remove (else still open at window end).
| (["agent_busy","needs-decision","blocked","needs-live"]) as $reasons
| ([ $audit[] | select(.phase == "gh" and .task == "gh:label" and .stage == "attempt" and (.label | IN($reasons[])))
     | {reason:.label, action:.action, at:.at, key:"\(.repo)#\(.number)"} ]) as $label_events
| ([ $label_events[] | select(.action == "add") | . as $add
     | ([ $label_events[] | select(.action == "remove" and .reason == $add.reason and .key == $add.key and .at > $add.at) ] | map(.at) | min) as $rm
     | { reason:$add.reason,
         seconds:(if $rm != null then (($rm | fromdateiso8601) - ($add.at | fromdateiso8601)) else null end) } ]) as $label_spans
| ([ $audit[] | select(.phase == "parked" and .reason == "agent_busy") ]) as $parks
| ({ by_reason:(reduce $reasons[] as $r ({}; .[$r] =
       ( if $r == "agent_busy"
         then { count:($parks | length), seconds:null }
         else { count:([ $label_spans[] | select(.reason == $r) ] | length),
                seconds:([ $label_spans[] | select(.reason == $r and .seconds != null) | .seconds ] | if length == 0 then 0 else add end),
                open_spans:([ $label_spans[] | select(.reason == $r and .seconds == null) ] | length) } end))),
     parked_events:($parks | length) }) as $blocked_val

# --- assemble, with honest coverage ----------------------------------------------------------------------------------
| ($repo_cov_pct) as $cov
| (if $repos_total == 0 then "the window names no repository with GitHub evidence"
   elif $repos_ok < $repos_total then "GitHub evidence missing for: " + ([ $repo_cov[] | select(.ok | not) | .repo ] | join(", "))
   elif $repos_covered < $repos_total then "PR lists truncated inside the window (raise limit) for: " + ([ $repo_cov[] | select(.ok and (.window_covered | not)) | .repo ] | join(", "))
   else null end) as $cov_reason
| def metric($v; $pct; $from; $reason): {value:$v, coverage_pct:$pct, observed_from:$from, unknown_reason:(if $v == null then $reason else (if $pct < 100 then $reason else null end) end)};
def na($reason): {value:null, coverage_pct:0, observed_from:null, unknown_reason:$reason};

# a metric over GitHub evidence is UNKNOWN (null), not 0, when no repo the window names could be read: observing none is
# only honest once at least one repo answered.
(if $repos_total == 0 then "the window names no repository to read the GitHub record from"
 elif $repos_ok == 0 then "GitHub evidence unavailable for every repository the window names: " + ([ $repo_cov[] | .repo ] | join(", "))
 else null end) as $gh_unknown
| { schema_version:1, task:"coord:report", observed_at:$now,
    window:$w,
    sources:{ audit:{ rows_in_window:($audit | length),
                      handoffs_attempted:([ $audit[] | select(.phase == "attempt") ] | length) },
              repos:$repo_cov,
              repos_named:$repos_total, repos_observed:$repos_ok },
    metrics:{
      verified_deliveries:((if $gh_unknown != null then na($gh_unknown) else metric($deliv_val; $cov; "github:merged_prs+evidence.jq passes"; $cov_reason) end)
        + {refs:[ $verified[] | {issue:.closes, url:.url, merged_at:.merged_at} ]}),
      authorization_to_merge:(if $lead_val == null
        then na("no verified delivery in the window had an authorization row in the audit (gh:label add approved or a handoff's labeled_at)")
        else metric($lead_val; (if ($verified | length) == 0 then 0 else (($lead_n * 100 / ($verified | length)) | floor) end);
                    "audit:gh:label add approved / handoff labeled_at -> github:merged_at";
                    "lead time only for verified deliveries with an authorization row; others omitted") end),
      review:(if $gh_unknown != null then na($gh_unknown) else metric($review_val; $cov; "github:pr comments+reviews via evidence.jq grade/signer/head"; $cov_reason) end),
      blocked_time:(metric($blocked_val; $cov;
                    "audit:parked(agent_busy) counts + gh:label add/remove spans for needs-decision|blocked|needs-live";
                    "agent_busy is a park count, not a measured wait, in M0a; label spans still open at window end are counted separately")),
      tokens:na("out of M0a scope; local harness-session message.usage lands in a later slice (#85 deliverable 1.7); gateway tokens unavailable (llm-gateway #69)"),
      skill_invocations:na("out of M0a scope; tool_use counts from harness sessions land in a later slice (#85 deliverable 1.8)"),
      runtime_resources:na("out of M0a scope; export run.log peaks/failure-class need the runtime-host field audit (#85 deliverable 1.9)")
    } }
