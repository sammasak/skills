#!/usr/bin/env bash
# PostToolUse Bash hook (shunt): a successful command whose output is over
# SHUNT_SPILL_MIN_CHARS (default 12000) has its full output saved to a 0600 log
# under ${XDG_CACHE_HOME:-~/.cache}/claude-spill/<session>/<tool_use_id>.log, and
# the model sees a ~4,000-char excerpt (head, tail, a diff index) with the path,
# via updatedToolOutput. Deterministic, no model call. Failed commands never
# reach PostToolUse, so error output is never hidden. Fail open everywhere: any
# problem exits 0 with no output and the original result stands; never exit 2.
# Skips: SHUNT_DISABLE / SHUNT_SPILL_DISABLE, interrupted or image results,
# background commands, plain file printers (the Bash-read hook owns those), calls
# to bulk-read.sh, and agent types in SHUNT_SKIP_AGENTS.
# shellcheck source-path=SCRIPTDIR
set -uo pipefail

SCRIPT_DIR=$(realpath -e -- "$0" 2>/dev/null) || exit 0
SCRIPT_DIR="${SCRIPT_DIR%/*}"
source "$SCRIPT_DIR/lib/shunt.sh" 2>/dev/null || exit 0
source "$SCRIPT_DIR/lib/log.sh" 2>/dev/null || log_hook() { :; }
command -v jq >/dev/null 2>&1 || exit 0
START_MS=$(($(date +%s%N) / 1000000))

CHARS=0 NLINES=0 EXCERPT=0 SECRET=false
CLAUDE_SESSION_ID=""
done_spill() { # done_spill <result>: log the decision and exit 0 (the original output stands)
  export CLAUDE_SESSION_ID
  log_hook "shunt-spill" "$1" "$(( ($(date +%s%N) / 1000000) - START_MS ))" \
    "{\"chars\":$CHARS,\"lines\":$NLINES,\"excerpt_chars\":$EXCERPT,\"secret\":$SECRET}" 2>/dev/null || true
  exit 0
}
{ [ "${SHUNT_DISABLE:-0}" = 1 ] || [ "${SHUNT_SPILL_DISABLE:-0}" = 1 ]; } && done_spill disabled
INPUT=$(cat 2>/dev/null) || exit 0

# One jq pass for every field the decision needs; NUL-separated (commands hold no NUL).
FIELDS=()
while IFS= read -r -d '' f; do FIELDS+=("$f"); done < <(printf '%s' "$INPUT" | jq -j '
  [ (.session_id // ""), (.tool_use_id // ""), (.agent_type // ""),
    (.tool_input.run_in_background // false | tostring),
    (.tool_response.interrupted // false | tostring), (.tool_response.isImage // false | tostring),
    (.tool_response.persistedOutputPath // ""),
    ((.tool_response.stdout // "") | length | tostring), ((.tool_response.stderr // "") | length | tostring),
    (.tool_input.command // "") ] | map(tostring + "\u0000") | add' 2>/dev/null)
[ "${#FIELDS[@]}" -eq 10 ] || exit 0
SID=${FIELDS[0]} TID=${FIELDS[1]} AGENT=${FIELDS[2]} BG=${FIELDS[3]} INTR=${FIELDS[4]} IMG=${FIELDS[5]}
PERSISTED=${FIELDS[6]} OUT_LEN=${FIELDS[7]} ERR_LEN=${FIELDS[8]} CMD=${FIELDS[9]}
CLAUDE_SESSION_ID=$SID
CHARS=$(( OUT_LEN + ERR_LEN ))
MIN=$(shunt_int "${SHUNT_SPILL_MIN_CHARS:-}" 12000)

{ [ "$INTR" = true ] || [ "$IMG" = true ]; } && done_spill interrupted
[ "$BG" = true ] && done_spill background
[ -n "$PERSISTED" ] || [ "$CHARS" -gt "$MIN" ] || done_spill small
shunt_file_printer "$CMD" && ! shunt_compound "$CMD" && done_spill printer
case "$CMD" in *bulk-read.sh*) done_spill printer ;; esac
if [ -n "$AGENT" ]; then
  IFS=, read -ra skip <<< "${SHUNT_SKIP_AGENTS-$SHUNT_DEFAULT_SKIP_AGENTS}"
  for a in "${skip[@]}"; do
    a="${a#"${a%%[![:space:]]*}"}"; a="${a%"${a##*[![:space:]]}"}"
    [ -n "$a" ] && [ "$a" = "$AGENT" ] && done_spill subagent
  done
fi

# Where the log goes. Ids become path components, so only the safe-character set.
{ shunt_safe_id "$SID" && shunt_safe_id "$TID"; } || done_spill error
ROOT=$(shunt_spill_root) || done_spill error
[ -n "$ROOT" ] || done_spill error
umask 077
mkdir -p "$ROOT" 2>/dev/null || done_spill error
[ -L "$ROOT" ] && done_spill error
ROOT=$(realpath -e -- "$ROOT" 2>/dev/null) || done_spill error
DIR="$ROOT/$SID"
{ mkdir -p "$DIR" && chmod 700 "$ROOT" "$DIR"; } 2>/dev/null || done_spill error
[ -L "$DIR" ] && done_spill error

# Once an hour: drop session dirs untouched for SHUNT_SPILL_KEEP_DAYS. Only direct
# children of the resolved root that are real directories (find -P never follows
# symlinks, and rm -r does not descend through them).
STAMP="$ROOT/.cleanup-stamp"
if [ ! -e "$STAMP" ] || [ -n "$(find "$STAMP" -maxdepth 0 -mmin +60 2>/dev/null)" ]; then
  touch "$STAMP" 2>/dev/null
  KEEP=$(shunt_int "${SHUNT_SPILL_KEEP_DAYS:-}" 2)
  find "$ROOT" -mindepth 1 -maxdepth 1 -type d ! -name "$SID" -mmin +$(( KEEP * 1440 )) -exec rm -rf -- {} + 2>/dev/null
fi

KEEP_ERR=false      # true: stderr is short and goes back as is; else it is folded into a log
ERR_TAIL_FROM=""    # file whose stderr section feeds the "last 20 lines" block
if [ -n "$PERSISTED" ] && [ -r "$PERSISTED" ] && [ -f "$PERSISTED" ]; then
  # Claude Code already saved it: use that file, no second copy.
  LOG=$(realpath -e -- "$PERSISTED" 2>/dev/null) || done_spill error
  if [ "$ERR_LEN" -gt 2000 ]; then
    ERRLOG="$DIR/$TID.stderr.log"
    (set -C; printf '' > "$ERRLOG") 2>/dev/null || done_spill error
    printf '%s' "$INPUT" | jq -j '.tool_response.stderr' >> "$ERRLOG" 2>/dev/null || done_spill error
    ERR_TAIL_FROM=$ERRLOG
  else
    KEEP_ERR=true
  fi
  CHARS=$(shunt_count_bytes "$LOG") || done_spill error
  CHARS=$(( CHARS + ERR_LEN ))
else
  LOG="$DIR/$TID.log"
  (set -C; printf '' > "$LOG") 2>/dev/null || done_spill error
  printf '%s' "$INPUT" | jq -j '.tool_response.stdout // ""' >> "$LOG" 2>/dev/null || done_spill error
  if [ "$ERR_LEN" -gt 2000 ]; then
    { printf '\n--- stderr ---\n'; printf '%s' "$INPUT" | jq -j '.tool_response.stderr'; } >> "$LOG" 2>/dev/null || done_spill error
    ERR_TAIL_FROM=stderr-in-log
  elif [ "$ERR_LEN" -gt 0 ]; then
    KEEP_ERR=true
  fi
fi
NLINES=$(shunt_count_lines "$LOG") || done_spill error

if shunt_secret_marker "$LOG"; then
  SECRET=true
  printf '%s\n' "$LOG" >> "$DIR/no-delegate.list" 2>/dev/null || done_spill error
fi

cut_line() { # cut_line <line>: at most 240 chars, with a visible mark
  if [ "${#1}" -gt 240 ]; then printf '%s…[cut]' "${1:0:240}"; else printf '%s' "$1"; fi
}

# Head (fewer lines when a diff index takes their place), a diff index, then the tail.
HEAD_MAX=15 HEAD_CHARS=1200 TAIL_MAX=40 TAIL_CHARS=2800
INDEX=()
while IFS= read -r l || [ -n "$l" ]; do INDEX+=("$(cut_line "$l")"); done < <(grep -n -m 40 '^diff --git ' -- "$LOG" 2>/dev/null)
if [ "${#INDEX[@]}" -gt 0 ]; then HEAD_MAX=5 HEAD_CHARS=600 TAIL_CHARS=1600; fi

HEAD=() used=0
while IFS= read -r l || [ -n "$l" ]; do
  l=$(cut_line "$l")
  [ $(( used + ${#l} + 1 )) -le "$HEAD_CHARS" ] || [ "${#HEAD[@]}" -eq 0 ] || break
  HEAD+=("$l"); used=$(( used + ${#l} + 1 ))
done < <(head -n "$HEAD_MAX" -- "$LOG" 2>/dev/null)

REMAIN=$(( NLINES - ${#HEAD[@]} ))
[ "$REMAIN" -lt 0 ] && REMAIN=0
TAILN=$(( REMAIN < TAIL_MAX ? REMAIN : TAIL_MAX ))
TAIL=()
if [ "$TAILN" -gt 0 ]; then
  RAW=()
  while IFS= read -r l || [ -n "$l" ]; do RAW+=("$(cut_line "$l")"); done < <(tail -n "$TAILN" -- "$LOG" 2>/dev/null)
  used=0 i=$(( ${#RAW[@]} - 1 ))
  while [ "$i" -ge 0 ]; do
    l=${RAW[$i]}
    [ $(( used + ${#l} + 1 )) -le "$TAIL_CHARS" ] || break
    TAIL=("$l" "${TAIL[@]}"); used=$(( used + ${#l} + 1 )); i=$(( i - 1 ))
  done
fi
OMITTED=$(( NLINES - ${#HEAD[@]} - ${#TAIL[@]} ))
[ "$OMITTED" -lt 0 ] && OMITTED=0

EX="$DIR/$TID.excerpt"
(set -C; printf '' > "$EX") 2>/dev/null || EX=$(mktemp "$DIR/.excerpt.XXXXXX") || done_spill error
trap 'rm -f "$EX"' EXIT
{
  printf '[shunt] command output was %s chars, %s lines (exit 0); full output saved to %s.\n' "$CHARS" "$NLINES" "$LOG"
  [ -n "${ERRLOG:-}" ] && printf '[shunt] stderr was saved to %s.\n' "$ERRLOG"
  if [ "$SECRET" = true ]; then
    printf 'This output looks like it contains secret material; do not delegate it.\n'
    printf 'Showing the first and last lines. For the rest: Grep or Read a range of that file. Do not re-run the command just to see more.\n'
  elif [ "$(shunt_count_bytes "$LOG")" -gt "$(shunt_max_payload)" ]; then
    printf 'Showing the first and last lines. For the rest: Grep or Read a range of that file (it is over the bulk-read payload cap). Do not re-run the command just to see more.\n'
  else
    printf 'Showing the first and last lines. For the rest: Grep or Read a range of that file, or %s --question "<what you need>" --paths %q. Do not re-run the command just to see more.\n' \
      "$(shunt_script_path "$SCRIPT_DIR")" "$LOG"
  fi
  printf '%s\n' "${HEAD[@]}"
  if [ "${#INDEX[@]}" -gt 0 ]; then
    printf '[diff index: log line:header, %s shown]\n' "${#INDEX[@]}"
    used=0
    for l in "${INDEX[@]}"; do
      [ $(( used + ${#l} + 1 )) -le 1200 ] || { printf '[... more files in the log ...]\n'; break; }
      printf '%s\n' "$l"; used=$(( used + ${#l} + 1 ))
    done
  fi
  [ "$OMITTED" -gt 0 ] && printf '[... %s lines omitted ...]\n' "$OMITTED"
  [ "${#TAIL[@]}" -gt 0 ] && printf '%s\n' "${TAIL[@]}"
  if [ -n "$ERR_TAIL_FROM" ]; then
    printf -- '--- stderr (last 20 lines; all of it is in the log) ---\n'
    src=$LOG; [ "$ERR_TAIL_FROM" = stderr-in-log ] || src=$ERR_TAIL_FROM
    used=0
    while IFS= read -r l || [ -n "$l" ]; do
      l=$(cut_line "$l")
      [ $(( used + ${#l} + 1 )) -le 1000 ] || break
      printf '%s\n' "$l"; used=$(( used + ${#l} + 1 ))
    done < <(tail -n 20 -- "$src" 2>/dev/null)
  fi
} > "$EX" 2>/dev/null || done_spill error

OUT_JSON=$(printf '%s' "$INPUT" | jq -c --rawfile out "$EX" --argjson keep "$KEEP_ERR" \
  '{hookSpecificOutput:{hookEventName:"PostToolUse",updatedToolOutput:{stdout:$out,
    stderr:(if $keep then (.tool_response.stderr // "") else "" end),interrupted:false,isImage:false}}}' 2>/dev/null) \
  || done_spill error
EXCERPT=$(jq -r '.hookSpecificOutput.updatedToolOutput.stdout | length' <<<"$OUT_JSON" 2>/dev/null) || EXCERPT=0
printf '%s\n' "$OUT_JSON"
done_spill spilled
