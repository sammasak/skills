#!/usr/bin/env bash
# PreToolUse Bash hook, worker hosts only (skills#28): the review gate for `gh pr merge`. Workers run in
# bypassPermissions, so no classifier asks before a merge; this hook refuses one unless
#   - it pins the head with --match-head-commit <40-hex>, and that is still the PR's head;
#   - a comment carries `Grade: N/10 (head <sha>)` for that head with N >= 9, signed `-- <host> <pane>`;
#   - neither the merging pane nor that grade's signer is the PR's implementer (the PR body's signer).
# Fail closed: an unparsable command or a failed `gh pr view` blocks. A quoted mention never matches.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/input.sh"
read_hook_input

CMD=$(hook_command)
[ -z "$CMD" ] && exit 0
SQ="'"
S=$(echo "$CMD" | sed -z "s/${SQ}[^${SQ}]*${SQ}/Q/g; s/\"[^\"]*\"/Q/g")
echo "$S" | grep -qE "(^|[|&;[:space:]])gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|\$)" || exit 0

block() { echo "BLOCKED: gh pr merge: $1" >&2; exit 2; }

# the merge's own words: PR number, repo, pinned head (one merge per command)
read -ra words <<<"$(echo "$CMD" | grep -oE "gh[[:space:]]+pr[[:space:]]+merge[^|&;]*" | head -1)"
pr='' repo='' head=''
i=3
while [ "$i" -lt "${#words[@]}" ]; do
  w=${words[$i]}
  case "$w" in
    -R|--repo) i=$((i + 1)); repo=${words[$i]:-} ;;
    --repo=*) repo=${w#--repo=} ;;
    --match-head-commit) i=$((i + 1)); head=${words[$i]:-} ;;
    --match-head-commit=*) head=${w#--match-head-commit=} ;;
    -*) ;;
    *) [ -n "$pr" ] || pr=${w##*/pull/} ;;
  esac
  i=$((i + 1))
done
[[ $pr =~ ^[0-9]+$ ]] || block "name the PR number (got '${pr:-none}'); a merge of the current branch is not reviewable here"
[[ $head =~ ^[0-9a-f]{40}$ ]] || block "pin the graded head: --match-head-commit <40-hex sha>"

view=$(gh pr view "$pr" ${repo:+-R "$repo"} --json headRefOid,body,comments 2>/dev/null) \
  || block "could not read PR #$pr${repo:+ in $repo} to check its review (fail closed)"
actual=$(jq -r '.headRefOid // ""' <<<"$view")
[ "$actual" = "$head" ] || block "PR #$pr's head is ${actual:-unknown}, not the pinned $head; the grade must be on the head you merge"

# "<host-prefix> <pane>" identities: the host up to its first dash, so `lenovo-21CB001PMX wN:p1` is `lenovo wN:p1`
SIGS='def sigs: [scan("(?m)^-- ([A-Za-z0-9._-]+) ([A-Za-z0-9]+:p[0-9]+)") | "\(.[0] | split("-")[0] | ascii_downcase) \(.[1])"];'
implementers=$(jq -c "$SIGS"' .body // "" | sigs' <<<"$view") || block "could not parse PR #$pr's body (fail closed)"
me="$(uname -n | cut -d. -f1 | cut -d- -f1 | tr '[:upper:]' '[:lower:]') ${HERDR_PANE_ID:-}"
if [ -n "${HERDR_PANE_ID:-}" ] && jq -e --arg me "$me" 'index($me) != null' <<<"$implementers" >/dev/null; then
  block "$me implemented PR #$pr (it signed the PR body); the implementer never merges its own change"
fi
# signers of a >= 9 grade naming this head (7+ hex prefix), the implementer's own grade excluded
graders=$(jq -c --arg h "$head" --argjson impl "$implementers" "$SIGS"'
  [.comments[].body
   | select([scan("Grade: ([0-9]+(?:\\.[0-9]+)?)/10 \\(head ([0-9a-f]{7,40})\\)")]
            | any(.[]; . as $g | ($g[0] | tonumber) >= 9 and ($h | startswith($g[1]))))
   | sigs[] | select(. as $s | $impl | index($s) | not)] | unique' <<<"$view") \
  || block "could not parse PR #$pr's comments (fail closed)"
[ "$(jq length <<<"$graders")" -gt 0 ] \
  || block "PR #$pr has no independent signed 'Grade: N/10 (head ${head:0:7})' with N >= 9 on this head; get the review first"
exit 0
