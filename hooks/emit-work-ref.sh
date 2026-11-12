#!/usr/bin/env bash
# Stop and SessionStart hook (telemetry): emit one "work reference" log record,
# the repository, branch and commit the session is on, so usage keyed by
# session.id can later be joined to a PR or issue (session -> branch -> PR, by gh).
# Deterministic: no model, no gh, no GitHub API. Only when HARNESS_OTLP_ENDPOINT
# is set (HARNESS_WORK_REF_DISABLE=1 turns it off), and once per session per
# repository and branch. Always exits 0 with no output (a Stop hook's output can
# steer the session); the POST runs detached, so the hook never waits on it.
# shellcheck source-path=SCRIPTDIR
set -uo pipefail

INPUT=$(cat 2>/dev/null) || exit 0
SCRIPT_DIR=$(realpath -e -- "$0" 2>/dev/null) || exit 0
SCRIPT_DIR="${SCRIPT_DIR%/*}"
source "$SCRIPT_DIR/lib/log.sh" 2>/dev/null || log_hook() { :; }
command -v jq >/dev/null 2>&1 || exit 0
START_MS=$(($(date +%s%N) / 1000000))

CLAUDE_SESSION_ID=""
done_ref() { # done_ref <result>: log the result and exit 0
  export CLAUDE_SESSION_ID
  log_hook "work-ref" "$1" "$(( ($(date +%s%N) / 1000000) - START_MS ))" 2>/dev/null || true
  exit 0
}
[ "${HARNESS_WORK_REF_DISABLE:-0}" = 1 ] && done_ref disabled
[ -n "${HARNESS_OTLP_ENDPOINT:-}" ] || done_ref no-endpoint
{ command -v git && command -v curl; } >/dev/null 2>&1 || exit 0

# NUL-separated fields, as in shunt-spill-output.sh.
FIELDS=()
while IFS= read -r -d '' f; do FIELDS+=("$f"); done < <(printf '%s' "$INPUT" | jq -j '
  [ (.session_id // ""), (.cwd // ""), (.agent_type // "") ] | map(tostring + "\u0000") | add' 2>/dev/null)
[ "${#FIELDS[@]}" -eq 3 ] || done_ref unparsed
SID=${FIELDS[0]} CWD=${FIELDS[1]} AGENT=${FIELDS[2]}
CLAUDE_SESSION_ID=$SID
{ [ -n "$SID" ] && [ -n "$CWD" ]; } || done_ref unparsed

# Every git call is bounded, so a hung repo (network filesystem, lock) cannot stall the session.
T=()
command -v timeout >/dev/null 2>&1 && T=(timeout 2)
TOP=$("${T[@]}" git -C "$CWD" rev-parse --show-toplevel 2>/dev/null) || done_ref no-repo
g() { "${T[@]}" git -C "$TOP" "$@" 2>/dev/null; }
URL=$(g config --get remote.origin.url) || done_ref no-repo
# Only github.com owner/repo is joinable by gh. Only the two names are kept, so
# credentials embedded in an https URL never leave this script.
GH_RE='^(git@github\.com:|(https?|ssh|git)://([^/@]*@)?github\.com(:[0-9]+)?/)([A-Za-z0-9-]+)/([A-Za-z0-9_.-]+)$'
URL="${URL%/}"
[[ "${URL%.git}" =~ $GH_RE ]] || done_ref no-repo
OWNER=${BASH_REMATCH[5]} REPO=${BASH_REMATCH[6]}
REV=$(g rev-parse HEAD) || done_ref no-repo
REV=${REV:0:12}
BRANCH=$(g symbolic-ref --short -q HEAD) || BRANCH=""   # empty when detached

# Issue or PR number, only from an unambiguous branch name: issue-76, issue/76,
# gh-76, pr-76, #76, or a leading 76- (bare or after fix/, feat/ and the like).
HINT=""
B="${BRANCH,,}"
HINT_RE='(^|[^a-z0-9])(issue[-/]|gh-|pr-|#)([0-9]+)'
LEAD_RE='^((fix|feat|feature|bug|bugfix|hotfix|chore|docs|refactor|test|issue)/)?([0-9]+)-'
if [[ "$B" =~ $HINT_RE ]] || [[ "$B" =~ $LEAD_RE ]]; then HINT=${BASH_REMATCH[3]}; fi

# Dedupe on repository and branch (not the commit): the last key sent per session.
BASE="${XDG_STATE_HOME:-${HOME:+$HOME/.local/state}}"
[ -n "$BASE" ] || done_ref unparsed
DIR="$BASE/claude-hooks/work-ref"
mkdir -p "$DIR" 2>/dev/null || done_ref unparsed
STATE="$DIR/${SID//[!A-Za-z0-9_-]/_}"
KEY="$OWNER/$REPO@$BRANCH"
LAST=""
[ -f "$STATE" ] && IFS= read -r LAST < "$STATE" 2>/dev/null
[ "$LAST" = "$KEY" ] && done_ref unchanged
printf '%s\n' "$KEY" > "$STATE" 2>/dev/null || done_ref unparsed

# Once an hour: drop session state untouched for 7 days (as shunt-spill-output.sh does).
STAMP="$DIR/.cleanup-stamp"
if [ ! -L "$STAMP" ] && { [ ! -e "$STAMP" ] || [ -n "$(find "$STAMP" -maxdepth 0 -mmin +60 2>/dev/null)" ]; }; then
  touch "$STAMP" 2>/dev/null
  find "$DIR" -mindepth 1 -maxdepth 1 -type f ! -name .cleanup-stamp -mmin +$(( 7 * 1440 )) -delete 2>/dev/null
fi

# One OTLP/HTTP JSON log record. HARNESS_RESOURCE_ATTRIBUTES uses the
# OTEL_RESOURCE_ATTRIBUTES syntax (k=v,k=v); empty attributes are dropped.
PAYLOAD=$(jq -cn --arg now "$(date +%s%N)" --arg ra "${HARNESS_RESOURCE_ATTRIBUTES:-}" \
  --arg sid "$SID" --arg owner "$OWNER" --arg repo "$REPO" --arg branch "$BRANCH" \
  --arg rev "$REV" --arg hint "$HINT" --arg agent "$AGENT" '
  def kv: with_entries(select(.value != "")) | to_entries | map({key, value: {stringValue: .value}});
  ({"service.name": "claude-code"}
    + ([$ra | split(",")[] | capture("^\\s*(?<key>[^=\\s]+)\\s*=\\s*(?<value>.*?)\\s*$")] | from_entries)) as $res
  | {resourceLogs: [{resource: {attributes: ($res | kv)}, scopeLogs: [{logRecords: [{
      timeUnixNano: $now, body: {stringValue: "work_ref"},
      attributes: ({"event.name": "work_ref", "session.id": $sid, "vcs.owner.name": $owner,
        "vcs.repository.name": $repo, "vcs.ref.head.name": $branch, "vcs.ref.head.revision": $rev,
        "work.ref.hint": $hint, "agent_type": $agent} | kv)}]}]}]}' 2>/dev/null) || done_ref unparsed

# Detached, every fd redirected: the hook returns now and nothing holds its stdout open.
curl -s -o /dev/null --max-time 2 -H 'Content-Type: application/json' --data-binary @- \
  "${HARNESS_OTLP_ENDPOINT%/}/v1/logs" <<<"$PAYLOAD" >/dev/null 2>&1 &
done_ref emitted
