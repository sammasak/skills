# GitHub evidence rules shared by work:status (correlate.jq) and coord:changed (idle.jq): which issue a PR refers to,
# how a grade and its signer are read from a note, and which notes pass a PR's head.
def num: if type == "string" and test("^#[0-9]+$") then ltrimstr("#") | tonumber else null end;
# a PR refers to #N when it closes it, names it in title or body (not OWNER/REPO#N, which is another repo), or its branch
# carries N as a path or dash segment
def refs($n): ((.closingIssuesReferences // []) | any(.number == $n))
  or (((.title // "") + "\n" + (.body // "")) | test("(^|[^A-Za-z0-9_./#-])#\($n)([^0-9]|$)"))
  or ((.headRefName // "") | test("(^|[/_-])\($n)([/_-]|$)"));
def grade: [capture("(?<![0-9.])(?<g>10|[0-9])/10(?![0-9])").g] | first | if . == null then null else tonumber end;
# reviews are signed "-- <host> <agent>" (the last sign-off wins over any pane the note mentions before it),
# "Reviewer <host> <agent>" / "Reviewed by <host> <agent>", or "(<host> <agent>, …" (one GitHub account for every agent)
def host_agent: "(?<h>[A-Za-z0-9][A-Za-z0-9.-]*) (?<a>[A-Za-z0-9_]+:[A-Za-z0-9_]+)";
def signer: (([capture("-- " + host_agent; "g")] | last)
  // ([capture("(?i)review(er:?|ed by) " + host_agent; "g")] | first)
  // ([capture("\\(" + host_agent; "g")] | first))
  | if . == null then null else "\(.h)/\(.a)" end;
# a note's own grade: the first on a line that names no pane but its signer's, or that declares the signer the reviewer
# on that same line ("…: 9/10, merging. Reviewer acer-swift wF:p1; author wW:p1"); "Response to the review (wR:p1, 8/10)"
# signed by the author quotes wR:p1's grade, it is not the author's
def own_grade($by): (($by // "") | split("/") | last) as $a
  | [split("\n")[] | select(([scan("(?<![A-Za-z0-9_])[A-Za-z][A-Za-z0-9_]*:p[0-9]+(?![A-Za-z0-9_])")] | all(. == $a))
                            or ($a != "" and test("(?i)review(er:?|ed by) ([A-Za-z0-9][A-Za-z0-9.-]* )?" + $a + "(?![A-Za-z0-9_])")))
     | grade | select(. != null)] | first;
def notes: . as $p
  | [((.comments // [])[] | {body:(.body // ""), url:(.url // $p.url), oid:null}),
     ((.reviews // [])[] | {body:(.body // ""), url:$p.url, oid:(.commit.oid? // null)})]
  | map((.body | signer) as $by | . + {grade:(.body | own_grade($by)), by:$by});
# the signed grades of 9 or more on the PR's exact head (the review's commit, or the head's short sha in the note)
def passes: (.headRefOid // "") as $head
  | [notes[] | select(.grade != null and .grade >= 9 and .by != null and $head != "" and (.oid == $head or (.body | contains($head[0:7]))))];
# every signed grade on the PR's exact head, by anyone
def head_grades: (.headRefOid // "") as $head
  | [notes[] | select(.grade != null and .by != null and $head != "" and (.oid == $head or (.body | contains($head[0:7]))))];
# the review state of an open PR's current head (skills#77), from its independent signed grades on that head ($impl: its
# implementers, host/agent, whose grades do not count) and the open review handoffs for exactly this head ($in_review):
# passed (a 9 or more, no lower grade), disputed (both: a 9 never overrides a lower grade's findings, the owner decides),
# findings (only lower grades: back to the implementer, not another review), in_review, unreviewed (the one state a review
# handoff is for). A new head starts over at unreviewed or in_review.
def review_state($impl; $in_review): (.headRefOid // "") as $head
  | [head_grades[] | select(.by as $b | $impl | index($b) | not)] as $g
  | (any($g[]; .grade >= 9)) as $pass | (any($g[]; .grade < 9)) as $low
  | {head:(if $head == "" then null else $head end), implementer:$impl, in_review:$in_review,
     grades:[$g[] | {grade, by, url}],
     state:(if $pass and $low then "disputed" elif $pass then "passed" elif $low then "findings"
            elif ($in_review | length) > 0 then "in_review" else "unreviewed" end)};
