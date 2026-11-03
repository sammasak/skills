# work:status correlation (skills #28 slice D). Inputs (slurped): $inv (herdr:inventory), $handoffs (last attempt per handoff_id
# from audit.jsonl, with its outcome and repo), $repos ({"OWNER/REPO": {prs, issues, error, limit}} from gh), $at.
# A handoff is matched to its PRs by task_ref and time window, never by the pane title; an agent with a delivered
# handoff on its current session takes that handoff's verdict, and only an agent without one falls back to its title.

$inv[0] as $inv | $handoffs[0].omitted as $omitted | $handoffs[0].handoffs as $handoffs | $repos[0] as $repos
| def num: if type == "string" and test("^#[0-9]+$") then ltrimstr("#") | tonumber else null end;
def title_repo: [capture("(^|[^A-Za-z0-9_./-])(?<r>[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)(#|\\s|$)").r] | first;
# a PR refers to #N when it closes it, names it in title or body (not OWNER/REPO#N, which is another repo), or its branch
# carries N as a path or dash segment
def refs($n): ((.closingIssuesReferences // []) | any(.number == $n))
  or (((.title // "") + "\n" + (.body // "")) | test("(^|[^A-Za-z0-9_./#-])#\($n)([^0-9]|$)"))
  or ((.headRefName // "") | test("(^|[/_-])\($n)([/_-]|$)"));
def grade: [capture("(?<![0-9.])(?<g>10|[0-9])/10(?![0-9])").g] | first | if . == null then null else tonumber end;
# reviews are signed "(<host> <agent>, …" or "-- <host> <agent>" (one GitHub account for every agent)
def signer: [capture("(\\(|-- )(?<h>[A-Za-z0-9][A-Za-z0-9.-]*) (?<a>[A-Za-z0-9_]+:[A-Za-z0-9_]+)") | "\(.h)/\(.a)"] | first;
def notes: . as $p
  | [((.comments // [])[] | {body:(.body // ""), url:(.url // $p.url), oid:null}),
     ((.reviews // [])[] | {body:(.body // ""), url:$p.url, oid:(.commit.oid? // null)})]
  | map(. + {grade:(.body | grade), by:(.body | signer)});

# per-PR stages; reviewed = a signed grade >= 9 on the PR's head (the review's commit, or the head's short sha in the
# comment); passed_by names its signers, so a handoff never counts its own agent's grade (see the windows below);
# live = a comment with a "Live acceptance:" line
def pr_view: (.headRefOid // "") as $head
  | [notes[] | select(.grade != null and .grade >= 9 and .by != null and $head != "" and (.oid == $head or (.body | contains($head[0:7]))))] as $passes
  | ([notes[] | select(.body | test("(^|\\n)[*_> ]*live acceptance:"; "i"))] | last) as $live
  | {number, url, state, head:(if $head == "" then null else $head end), created_at:.createdAt,
     stages:{implemented:{url, opened_at:.createdAt},
             reviewed:($passes | last | if . then {grade, by, head:$head, url} else null end),
             merged:(if .mergedAt then {url, merged_at:.mergedAt} else null end),
             live:(if $live then {url:$live.url} else null end)},
     passed_by:[$passes[].by] | unique};

def agent_at($h; $a): [$inv.hosts[]? | select(.host == $h) | .agents[]? | select(.agent_id == $a)] | first;
def host_answered($h): any($inv.hosts[]?; .host == $h and .reachable != false);

# a handoff owns the PRs naming its task_ref opened in its window [sent_at, until), except a PR its own agent passed
# (a >= 9 grade on the head): that agent reviewed it, a concurrent handoff implemented it
($handoffs
 | map(. as $h | ($h.task_ref | num) as $n | ($repos[$h.repo // ""] // null) as $d | "\($h.host)/\($h.agent_id)" as $impl
   | agent_at($h.host; $h.agent_id) as $now
   | (if $now == null then (if host_answered($h.host) then "gone" else "unobserved" end)
      elif $h.session_id != null and $now.session_id != null and $h.session_id != $now.session_id then "session_changed" else "same" end) as $sess
   | (if $d != null and $d.error == null and $n != null then
        [$d.prs[] | select(refs($n)) | select(.number == $n or (.createdAt >= $h.sent_at and ($h.until == null or .createdAt < $h.until)))
         | pr_view | select(.passed_by | index($impl) | not) | del(.passed_by)] | sort_by(.number)
      else [] end) as $prs
   | [$prs[] | select(.state != "CLOSED" or .stages.merged != null)] as $live_prs
   | (reduce ("implemented", "reviewed", "merged", "live") as $k ({};
        .[$k] = (if ($live_prs | length) > 0 and all($live_prs[]; .stages[$k] != null)
                 then [$live_prs[] | .stages[$k] | if $k == "reviewed" then {url, grade, by, head} else .url end] else null end))) as $st
   | (if ($h.delivered | not) then {v:"unknown", r:["not delivered (outcome \($h.outcome))"]}
      elif $h.repo == null then {v:"unknown", r:["the handoff names no repo (authorized_by.issue_url)"]}
      elif $d == null or $d.error != null then {v:"unknown", r:["GitHub evidence unavailable for \($h.repo)" + (if $d.error then " (\($d.error))" else "" end)]}
      elif ($live_prs | length) == 0 then {v:"unknown", r:["no PR in \($h.repo) references \($h.task_ref) since the handoff"]}
      elif $st.merged != null then {v:"verified", r:[]}
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

# agents: the latest delivered handoff to this pane on its current session wins over the title
| [$inv.hosts[]? | .host as $host | (.machine // null) as $m | .agents[]? | . as $a
   | ([$hs[] | select(.host == $host and .agent_id == $a.agent_id and .delivered and (.session_id == null or $a.session_id == null or .session_id == $a.session_id))] | last) as $h
   | ($a.observed_state // "unknown") as $s
   | (if $h != null then
        {by:"handoff", task_ref:$h.task_ref, repo:$h.repo, verdict:$h.work_verdict, refs:[$h.prs[].url], evidence_ref:$h.evidence_ref,
         reasons:($h.reasons + (if $a.task_ref != null and $a.task_ref != $h.task_ref then ["title names \($a.task_ref); correlated by handoff \($h.handoff_id) to \($h.task_ref)"] else [] end))}
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
      correlation:{by:$c.by, handoff_id:($h.handoff_id // null)},
      herdr_state:$s, state_change_seq:$a.state_change_seq, observed_at:$at,
      work_verdict:(if $s == "blocked" then "blocked" else $c.verdict end), needs_owner:($s == "blocked"),
      evidence_ref:(if $s != "blocked" then $c.evidence_ref // null else null end), refs:$c.refs,
      reasons:$c.reasons, sources:[{task:"herdr:inventory", observed_at:$at}]}] as $items
| {items:$items, handoffs:$hs, handoffs_omitted:$omitted}
