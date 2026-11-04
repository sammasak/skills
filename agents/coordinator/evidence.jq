# GitHub evidence rules shared by work:status (correlate.jq) and coord:changed (idle.jq): which issue a PR refers to,
# how a grade and its signer are read from a note, and which notes pass a PR's head.
def num: if type == "string" and test("^#[0-9]+$") then ltrimstr("#") | tonumber else null end;
# a PR refers to #N when it closes it, names it in title or body (not OWNER/REPO#N, which is another repo), or its branch
# carries N as a path or dash segment
def refs($n): ((.closingIssuesReferences // []) | any(.number == $n))
  or (((.title // "") + "\n" + (.body // "")) | test("(^|[^A-Za-z0-9_./#-])#\($n)([^0-9]|$)"))
  or ((.headRefName // "") | test("(^|[/_-])\($n)([/_-]|$)"));
def grade: [capture("(?<![0-9.])(?<g>10|[0-9])/10(?![0-9])").g] | first | if . == null then null else tonumber end;
# reviews are signed "(<host> <agent>, …" or "-- <host> <agent>" (one GitHub account for every agent)
def signer: [capture("(\\(|-- )(?<h>[A-Za-z0-9][A-Za-z0-9.-]*) (?<a>[A-Za-z0-9_]+:[A-Za-z0-9_]+)") | "\(.h)/\(.a)"] | first;
# a note's own grade: the first on a line that names no pane but its signer's; "Response to the review (wR:p1, 8/10)"
# signed by the author quotes wR:p1's grade, it is not the author's
def own_grade($by): (($by // "") | split("/") | last) as $a
  | [split("\n")[] | select([scan("(?<![A-Za-z0-9_])[A-Za-z][A-Za-z0-9_]*:p[0-9]+(?![A-Za-z0-9_])")] | all(. == $a)) | grade | select(. != null)] | first;
def notes: . as $p
  | [((.comments // [])[] | {body:(.body // ""), url:(.url // $p.url), oid:null}),
     ((.reviews // [])[] | {body:(.body // ""), url:$p.url, oid:(.commit.oid? // null)})]
  | map((.body | signer) as $by | . + {grade:(.body | own_grade($by)), by:$by});
# the signed grades of 9 or more on the PR's exact head (the review's commit, or the head's short sha in the note)
def passes: (.headRefOid // "") as $head
  | [notes[] | select(.grade != null and .grade >= 9 and .by != null and $head != "" and (.oid == $head or (.body | contains($head[0:7]))))];
