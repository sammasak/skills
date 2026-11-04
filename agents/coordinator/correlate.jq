# work:status correlation (skills #28 slice D). Inputs (slurped): $inv (herdr:inventory), $handoffs (last attempt per handoff_id
# from audit.jsonl, with its outcome and repo), $repos ({"OWNER/REPO": {prs, issues, error, limit}} from gh), $at.
# Evidence rules (refs, grade, signer, passes) live in evidence.jq.
# A handoff is matched to its PRs by task_ref and time window, never by the pane title; an agent with a delivered
# handoff on its current session takes that handoff's verdict, and only an agent without one falls back to its title.

include "evidence";
$inv[0] as $inv | $handoffs[0] as $log | $log.omitted as $omitted | $log.handoffs as $handoffs | $repos[0] as $repos
| def title_repo: [capture("(^|[^A-Za-z0-9_./-])(?<r>[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)(#|\\s|$)").r] | first;

# per-PR stages; reviewed = a signed grade >= 9 on the PR's head (the review's commit, or the head's short sha in the
# comment); graded_by names the signers of any grade, so a handoff never counts a PR its own agent graded (see below);
# live = a comment with a "Live acceptance:" line
def pr_view: (.headRefOid // "") as $head
  | passes as $passes
  | ([notes[] | select(.body | test("(^|\\n)[*_> ]*live acceptance:"; "i"))] | last) as $live
  | {number, url, state, head:(if $head == "" then null else $head end), created_at:.createdAt,
     stages:{implemented:{url, opened_at:.createdAt},
             reviewed:($passes | last | if . then {grade, by, head:$head, url} else null end),
             merged:(if .mergedAt then {url, merged_at:.mergedAt} else null end),
             live:(if $live then {url:$live.url} else null end)},
     graded_by:[notes[] | select(.grade != null and .by != null) | .by] | unique};

def agent_at($h; $a): [$inv.hosts[]? | select(.host == $h) | .agents[]? | select(.agent_id == $a)] | first;
def host_answered($h): any($inv.hosts[]?; .host == $h and .reachable != false);

# a handoff owns the PRs naming its task_ref opened, or given commits, in its window [sent_at, until), except a PR its own agent
# graded (at any grade, on any head): that agent reviewed it, a concurrent handoff implemented it
($handoffs
 | map(. as $h | ($h.task_ref | num) as $n | ($repos[$h.repo // ""] // null) as $d | "\($h.host)/\($h.agent_id)" as $impl
   | agent_at($h.host; $h.agent_id) as $now
   | (if $now == null then (if host_answered($h.host) then "gone" else "unobserved" end)
      elif $h.session_id != null and $now.session_id != null and $h.session_id != $now.session_id then "session_changed" else "same" end) as $sess
   | (if $d != null and $d.error == null and $n != null then
        # owned: the PR is the task_ref itself, was opened in the window, or got commits in the window (a fix-up round on an
        # existing PR, its review findings handed back as a new handoff)
        def in_window: . != null and . >= $h.sent_at and ($h.until == null or . < $h.until);
        [$d.prs[] | select(refs($n)) | select(.number == $n or (.createdAt | in_window) or any((.commits // [])[]; .committedDate | in_window))
         | pr_view | select(.graded_by | index($impl) | not) | del(.graded_by)] | sort_by(.number)
      else [] end) as $prs
   | [$prs[] | select(.state != "CLOSED" or .stages.merged != null)] as $live_prs
   | (reduce ("implemented", "reviewed", "merged", "live") as $k ({};
        .[$k] = (if ($live_prs | length) > 0 and all($live_prs[]; .stages[$k] != null)
                 then [$live_prs[] | .stages[$k] | if $k == "reviewed" then {url, grade, by, head} else .url end] else null end))) as $st
   | (if ($h.delivered | not) then {v:"unknown", r:["not delivered (outcome \($h.outcome))"]}
      elif $h.repo == null then {v:"unknown", r:["the handoff names no repo (authorized_by.issue_url)"]}
      elif $d == null or $d.error != null then {v:"unknown", r:["GitHub evidence unavailable for \($h.repo)" + (if $d.error then " (\($d.error))" else "" end)]}
      elif ($live_prs | length) == 0 then {v:"unknown", r:["no PR in \($h.repo) references \($h.task_ref) since the handoff"]}
      elif $st.merged != null and $st.reviewed != null then {v:"verified", r:[]}
      elif $st.merged != null then {v:"unverified", r:[$live_prs[] | select(.stages.reviewed == null) | "PR #\(.number) merged without an independent 9/10 on its head"]}
      else {v:"unverified", r:[$live_prs[] | select(.stages.merged == null) | "PR #\(.number) open, not merged"]} end) as $verdict
   | ([$d.prs[]?.createdAt] | min) as $oldest
   | $h + {prs:$prs, stages:$st, work_verdict:$verdict.v,
       evidence_ref:(if $verdict.v == "verified" then $st.merged[0] else null end),
       task_issue_open:(if $d != null and $d.error == null and $n != null then any($d.issues[]; .number == $n) else null end),
       session_state:$sess, herdr_state:($now.observed_state // null),
       stale:($verdict.v != "verified" and ($sess == "gone" or $sess == "session_changed" or ($h.until != null and ($prs | length) == 0))),
       reasons:($verdict.r
         + (if $sess == "gone" then ["agent \($impl) is no longer listed"] elif $sess == "session_changed" then ["pane \($impl) now runs another session"] else [] end)
         + (if $h.until != null and ($prs | length) == 0 then ["superseded by a later handoff to \($impl) with no PR"] else [] end)
         + (if $d != null and (($d.prs | length) >= $d.limit) and $oldest != null and $oldest > $h.sent_at then ["PR list cut at \($d.limit); PRs opened before \($oldest) not checked"] else [] end))})
) as $hs

# agents: the latest delivered handoff to this pane on its current session wins over the title; one beyond the evaluated
# window is reported as omitted (unknown), never replaced by a title guess
| [$inv.hosts[]? | .host as $host | (.machine // null) as $m | .agents[]? | . as $a
   | def mine: select(.host == $host and .agent_id == $a.agent_id and (.session_id == null or $a.session_id == null or .session_id == $a.session_id));
     ([$hs[] | select(.delivered) | mine] | last) as $h
   | (if $h == null then [$log.omitted_last[] | mine] | last else null end) as $old
   | ($a.observed_state // "unknown") as $s
   | (if $h != null then
        {by:"handoff", task_ref:$h.task_ref, repo:$h.repo, verdict:$h.work_verdict, refs:[$h.prs[].url], evidence_ref:$h.evidence_ref,
         reasons:($h.reasons + (if $a.task_ref != null and $a.task_ref != $h.task_ref then ["title names \($a.task_ref); correlated by handoff \($h.handoff_id) to \($h.task_ref)"] else [] end))}
      elif $old != null then
        {by:"omitted", task_ref:$old.task_ref, repo:null, verdict:"unknown", refs:[], evidence_ref:null,
         reasons:["its handoff \($old.handoff_id) (\($old.task_ref // "no ref"), sent \($old.sent_at)) is older than the \($log.kept) newest evaluated; not judged by its title"]}
      else ($a.task_ref | num) as $n | (($a.title // "") | title_repo) as $repo | ($repos[$repo // ""] // null) as $d
        | {by:(if $n != null then "title" else "none" end), task_ref:$a.task_ref, repo:$repo}
        + (if $n == null then {verdict:"unknown", refs:[], reasons:["no task reference (#N) in the agent title"]}
           elif $repo == null then {verdict:"unknown", refs:[], reasons:["title names #\($n) but no OWNER/REPO; run gh:work for the repo to check it"]}
           elif $d == null or $d.error != null then {verdict:"unknown", refs:[], reasons:["GitHub evidence unavailable (\($d.error // "not fetched"))"]}
           else ([$d.prs[] | select(refs($n))]) as $ps | ([$d.issues[] | select(.number == $n)]) as $is
             | (any($ps[]; .mergedAt != null)) as $merged | (any($ps[]; .state == "OPEN")) as $open
             | if $merged and ($open | not) and ($is | length) == 0 then {verdict:"verified", refs:[$ps[] | select(.mergedAt != null) | .url], reasons:["merged PR closes #\($n) in \($repo), no open issue or PR left"]}
               elif $merged and ($open | not) then {verdict:"unverified", refs:[$ps[] | select(.mergedAt != null) | .url], reasons:["merged PR names #\($n) but issue #\($n) is still open in \($repo)"]}
               elif $open then {verdict:"unverified", refs:[$ps[] | select(.state == "OPEN") | .url], reasons:(["open PR for #\($n) in \($repo), not merged"] + [$ps[] | select(.state == "OPEN") | select(any((.statusCheckRollup // [])[]; (.conclusion // .state // "") != "SUCCESS")) | "PR #\(.number) has non-green checks"])}
               elif ($is | length) > 0 then {verdict:"unverified", refs:[$is[].url], reasons:["issue #\($n) open in \($repo), no PR found"]}
               else {verdict:"unknown", refs:[], reasons:["#\($n) not found in \($repo)" + (if ($d.prs | length) >= $d.limit then " (only the newest \($d.limit) PRs checked)" else "" end)]} end
             | .evidence_ref = (if .verdict == "verified" then .refs[0] else null end) end) end) as $c
   | {host:$host, machine:$m, agent_id:$a.agent_id, harness:$a.harness, session_id:$a.session_id, title:($a.title // ""), task_ref:$c.task_ref, title_ref:$a.task_ref, repo:$c.repo,
      correlation:{by:$c.by, handoff_id:($h.handoff_id // $old.handoff_id // null)},
      herdr_state:$s, state_change_seq:$a.state_change_seq, observed_at:$at,
      work_verdict:(if $s == "blocked" then "blocked" else $c.verdict end), needs_owner:($s == "blocked"),
      evidence_ref:(if $s != "blocked" then $c.evidence_ref // null else null end), refs:$c.refs,
      reasons:$c.reasons, sources:[{task:"herdr:inventory", observed_at:$at}]}] as $items
| {items:$items, handoffs:$hs, handoffs_omitted:$omitted}
