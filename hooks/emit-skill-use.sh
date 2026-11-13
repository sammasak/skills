#!/usr/bin/env bash
# PreToolUse (Skill) and UserPromptSubmit hook (telemetry): emit one "skill use"
# log record naming the skill. Claude Code's own skill_activated event reports
# every user skill as "custom_skill" unless tool details are logged, which would
# also export tool input; this record carries the name and nothing else.
# Deterministic: no model, no network beyond the POST. Only when
# HARNESS_OTLP_ENDPOINT is set (HARNESS_SKILL_USE_DISABLE=1 turns it off). Always
# exits 0 with no output; the POST runs detached, so the hook never waits on it.
# shellcheck source-path=SCRIPTDIR
set -uo pipefail

INPUT=$(cat 2>/dev/null) || exit 0
SCRIPT_DIR=$(realpath -e -- "$0" 2>/dev/null) || exit 0
SCRIPT_DIR="${SCRIPT_DIR%/*}"
source "$SCRIPT_DIR/lib/log.sh" 2>/dev/null || log_hook() { :; }
command -v jq >/dev/null 2>&1 || exit 0
START_MS=$(($(date +%s%N) / 1000000))

CLAUDE_SESSION_ID=""
done_use() { # done_use <result>: log the result and exit 0
  export CLAUDE_SESSION_ID
  log_hook "skill-use" "$1" "$(( ($(date +%s%N) / 1000000) - START_MS ))" 2>/dev/null || true
  exit 0
}
[ "${HARNESS_SKILL_USE_DISABLE:-0}" = 1 ] && done_use disabled
[ -n "${HARNESS_OTLP_ENDPOINT:-}" ] || done_use no-endpoint
command -v curl >/dev/null 2>&1 || exit 0

# NUL-separated fields, as in emit-work-ref.sh. Of a prompt only a leading
# /name token leaves jq; the rest is never exported or put on a command line.
FIELDS=()
while IFS= read -r -d '' f; do FIELDS+=("$f"); done < <(printf '%s' "$INPUT" | jq -j '
  def s: if type == "string" then . else "" end;
  [ (.session_id | s), (.cwd | s), (.agent_type | s), (.hook_event_name | s),
    (if .tool_name == "Skill" then (.tool_input | objects | .skill | s) // "" else "" end),
    ((.prompt | s | capture("^/(?<n>[A-Za-z0-9_.:-]{1,80})(\\s|$)").n) // "")
  ] | map(. + "\u0000") | add' 2>/dev/null)
[ "${#FIELDS[@]}" -eq 6 ] || done_use unparsed
SID=${FIELDS[0]} CWD=${FIELDS[1]} AGENT=${FIELDS[2]} EVENT=${FIELDS[3]} TOOL_SKILL=${FIELDS[4]} SLASH=${FIELDS[5]}
CLAUDE_SESSION_ID=$SID
[ -n "$SID" ] || done_use unparsed

# name or plugin:name, each part starting with a letter or digit (so never . or ..)
NAME_RE='^[A-Za-z0-9][A-Za-z0-9_.-]*(:[A-Za-z0-9][A-Za-z0-9_.-]*)?$'
case "$EVENT" in
  PreToolUse)
    NAME=${TOOL_SKILL#/} TRIGGER=model
    { [ "${#NAME}" -le 80 ] && [[ "$NAME" =~ $NAME_RE ]]; } || done_use no-skill
    ;;
  UserPromptSubmit)
    NAME=$SLASH TRIGGER=user-slash
    [[ "$NAME" =~ $NAME_RE ]] || done_use no-skill
    # A typed /name is a skill only when one is installed under that name: a user
    # or project skill, or plugin:skill in the plugin cache. Built-in commands and
    # any other typed text are not, so nothing else of a prompt is ever sent.
    CONF="${CLAUDE_CONFIG_DIR:-${HOME:+$HOME/.claude}}"
    FOUND=""
    if [[ "$NAME" == *:* ]]; then
      [ -n "$CONF" ] && FOUND=$(compgen -G "$CONF/plugins/cache/*/${NAME%%:*}/*/skills/${NAME#*:}/SKILL.md" 2>/dev/null)
    elif { [ -n "$CONF" ] && [ -e "$CONF/skills/$NAME/SKILL.md" ]; } \
      || { [ -n "$CWD" ] && [ -e "$CWD/.claude/skills/$NAME/SKILL.md" ]; }; then
      FOUND=1
    fi
    [ -n "$FOUND" ] || done_use no-skill
    ;;
  *) done_use no-skill ;;
esac

# One OTLP/HTTP JSON log record, shaped as emit-work-ref.sh's.
PAYLOAD=$(jq -cn --arg now "$(date +%s%N)" --arg ra "${HARNESS_RESOURCE_ATTRIBUTES:-}" \
  --arg sid "$SID" --arg name "$NAME" --arg trigger "$TRIGGER" --arg agent "$AGENT" '
  def kv: with_entries(select(.value != "")) | to_entries | map({key, value: {stringValue: .value}});
  ({"service.name": "claude-code"}
    + ([$ra | split(",")[] | capture("^\\s*(?<key>[^=\\s]+)\\s*=\\s*(?<value>.*?)\\s*$")] | from_entries)) as $res
  | {resourceLogs: [{resource: {attributes: ($res | kv)}, scopeLogs: [{logRecords: [{
      timeUnixNano: $now, body: {stringValue: "skill_use"},
      attributes: ({"event.name": "skill_use", "session.id": $sid, "skill.name": $name,
        "invocation_trigger": $trigger, "agent_type": $agent} | kv)}]}]}]}' 2>/dev/null) || done_use unparsed

# Detached, every fd redirected: the hook returns now and nothing holds its stdout open.
curl -q -s -o /dev/null --proto '=http,https' --max-time 2 -H 'Content-Type: application/json' --data-binary @- \
  "${HARNESS_OTLP_ENDPOINT%/}/v1/logs" <<<"$PAYLOAD" >/dev/null 2>&1 &
done_use emitted
