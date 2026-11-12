#!/usr/bin/env bash
# PostToolUse Bash hook (shunt): a successful command whose output is over
# SHUNT_SPILL_MIN_CHARS (default 12000) has its stdout saved in full to a 0600 log
# under ${XDG_CACHE_HOME:-~/.cache}/claude-spill/<session>/<tool_use_id>.log (a
# long stderr goes to <tool_use_id>.stderr.log), and the model sees a ~4,000-char
# excerpt (head, tail, a diff index) with the paths, via updatedToolOutput.
# Deterministic, no model call. Failed commands never reach PostToolUse, so error
# output is never hidden. Fail open everywhere: any problem exits 0 with no
# output and the original result stands; never exit 2. Skips: SHUNT_DISABLE /
# SHUNT_SPILL_DISABLE, interrupted or image results, background commands, plain
# file printers (the Bash-read hook owns those), calls to bulk-read.sh, and agent
# types in SHUNT_SKIP_AGENTS.
# shellcheck source-path=SCRIPTDIR
set -uo pipefail

# Read stdin first, so no early exit leaves a large payload on a closed pipe.
INPUT=$(cat 2>/dev/null) || exit 0
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

# One jq pass for every field the decision needs; NUL-separated (commands hold no NUL).
FIELDS=()
while IFS= read -r -d '' f; do FIELDS+=("$f"); done < <(printf '%s' "$INPUT" | jq -j '
  [ (.session_id // ""), (.tool_use_id // ""), (.agent_type // ""), (.permission_mode // ""),
    (.tool_input.run_in_background // false | tostring), (.tool_response.backgroundTaskId // ""),
    (.tool_response.interrupted // false | tostring), (.tool_response.isImage // false | tostring),
    (.tool_response.persistedOutputPath // ""), (.tool_response.returnCodeInterpretation // ""),
    ((.tool_response.stdout // "") | length | tostring), ((.tool_response.stderr // "") | length | tostring),
    (.tool_input.command // "") ] | map(tostring + "\u0000") | add' 2>/dev/null)
[ "${#FIELDS[@]}" -eq 13 ] || exit 0
SID=${FIELDS[0]} TID=${FIELDS[1]} AGENT=${FIELDS[2]} PMODE=${FIELDS[3]} BG=${FIELDS[4]} BGID=${FIELDS[5]}
INTR=${FIELDS[6]} IMG=${FIELDS[7]} PERSISTED=${FIELDS[8]} RCI=${FIELDS[9]}
OUT_LEN=${FIELDS[10]} ERR_LEN=${FIELDS[11]} CMD=${FIELDS[12]}
CLAUDE_SESSION_ID=$SID
CHARS=$(( OUT_LEN + ERR_LEN ))
MIN=$(shunt_int "${SHUNT_SPILL_MIN_CHARS:-}" 12000)

{ [ "$INTR" = true ] || [ "$IMG" = true ]; } && done_spill interrupted
{ [ "$BG" = true ] || [ -n "$BGID" ]; } && done_spill background
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
# Claude Code says it saved the output but we cannot read it: we cannot show the rest either.
if [ -n "$PERSISTED" ] && { [ ! -f "$PERSISTED" ] || [ ! -r "$PERSISTED" ]; }; then done_spill error; fi

# Where the logs go. Ids become path components, so only the safe-character set.
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

# Once an hour: drop session dirs untouched for SHUNT_SPILL_KEEP_DAYS (at least 1).
# Only direct children of the resolved root that are real directories (find -P
# never follows symlinks, and rm -r does not descend through them). A symlinked
# stamp is never touched; cleanup then just does not run.
STAMP="$ROOT/.cleanup-stamp"
if [ ! -L "$STAMP" ] && { [ ! -e "$STAMP" ] || [ -n "$(find "$STAMP" -maxdepth 0 -mmin +60 2>/dev/null)" ]; }; then
  touch "$STAMP" 2>/dev/null
  KEEP=$(shunt_int "${SHUNT_SPILL_KEEP_DAYS:-}" 2)
  [ "$KEEP" -ge 1 ] || KEEP=1
  find "$ROOT" -mindepth 1 -maxdepth 1 -type d ! -name "$SID" -mmin +$(( KEEP * 1440 )) -exec rm -rf -- {} + 2>/dev/null
fi

# stdout: Claude Code's saved file when it made one (no second copy), else our own
# log; either way the log is stdout only. A long stderr gets its own file.
if [ -n "$PERSISTED" ]; then
  LOG=$(realpath -e -- "$PERSISTED" 2>/dev/null) || done_spill error
else
  LOG="$DIR/$TID.log"
  (set -C; printf '' > "$LOG") 2>/dev/null || done_spill error
  printf '%s' "$INPUT" | jq -j '.tool_response.stdout // ""' >> "$LOG" 2>/dev/null || done_spill error
fi
KEEP_ERR=false ERRLOG=""
if [ "$ERR_LEN" -gt 2000 ]; then
  ERRLOG="$DIR/$TID.stderr.log"
  (set -C; printf '' > "$ERRLOG") 2>/dev/null || done_spill error
  printf '%s' "$INPUT" | jq -j '.tool_response.stderr' >> "$ERRLOG" 2>/dev/null || done_spill error
elif [ "$ERR_LEN" -gt 0 ]; then
  KEEP_ERR=true
fi
OUT_BYTES=$(shunt_count_bytes "$LOG") || done_spill error
NLINES=$(shunt_count_lines "$LOG") || done_spill error
CHARS=$(( OUT_BYTES + ERR_LEN ))

# Whole-file secret scan (streaming), stdout log and stderr log alike.
LIST="$DIR/no-delegate.list"
for f in "$LOG" ${ERRLOG:+"$ERRLOG"}; do
  if shunt_secret_marker_stream "$f"; then
    SECRET=true
    [ -L "$LIST" ] && done_spill error
    printf '%s\n' "$f" >> "$LIST" 2>/dev/null || done_spill error
  fi
done

# Lines are bounded before the shell sees them: bytes 1-241 (LC_ALL=C, so a 30 MB
# single line costs one cut); a longer line is shown as 240 bytes plus a mark. A
# multibyte character split by the cut becomes U+FFFD when jq reads the excerpt.
bounded() { LC_ALL=C cut -b 1-241; }
mark() { # mark <line>: the line, or its first 240 bytes with a visible mark
  local LC_ALL=C
  if [ "${#1}" -gt 240 ]; then printf '%s…[cut]' "${1:0:240}"; else printf '%s' "$1"; fi
}
blen() { local LC_ALL=C; echo "${#1}"; }

# Head (fewer lines when a diff index takes their place), a diff index, then the tail.
HEAD_MAX=15 HEAD_CHARS=1200 TAIL_MAX=40 TAIL_CHARS=2800
INDEX=()
# A diff starts within its first lines, so only then pay for scanning the whole log.
if head -c 65536 -- "$LOG" 2>/dev/null | LC_ALL=C grep -aq '^diff --git '; then
  while IFS= read -r l || [ -n "$l" ]; do INDEX+=("$(mark "$l")"); done < <(LC_ALL=C grep -an -m 40 '^diff --git ' -- "$LOG" 2>/dev/null | bounded)
fi
if [ "${#INDEX[@]}" -gt 0 ]; then HEAD_MAX=5 HEAD_CHARS=600 TAIL_CHARS=1600; fi

HEAD=() used=0
while IFS= read -r l || [ -n "$l" ]; do
  l=$(mark "$l"); n=$(blen "$l")
  [ $(( used + n + 1 )) -le "$HEAD_CHARS" ] || [ "${#HEAD[@]}" -eq 0 ] || break
  HEAD+=("$l"); used=$(( used + n + 1 ))
done < <(head -n "$HEAD_MAX" -- "$LOG" 2>/dev/null | bounded)

REMAIN=$(( NLINES - ${#HEAD[@]} ))
[ "$REMAIN" -lt 0 ] && REMAIN=0
TAILN=$(( REMAIN < TAIL_MAX ? REMAIN : TAIL_MAX ))
TAIL=()
if [ "$TAILN" -gt 0 ]; then
  RAW=()
  while IFS= read -r l || [ -n "$l" ]; do RAW+=("$(mark "$l")"); done < <(tail -n "$TAILN" -- "$LOG" 2>/dev/null | bounded)
  used=0 i=$(( ${#RAW[@]} - 1 ))
  while [ "$i" -ge 0 ]; do
    l=${RAW[$i]}; n=$(blen "$l")
    [ $(( used + n + 1 )) -le "$TAIL_CHARS" ] || break
    TAIL=("$l" "${TAIL[@]}"); used=$(( used + n + 1 )); i=$(( i - 1 ))
  done
fi
OMITTED=$(( NLINES - ${#HEAD[@]} - ${#TAIL[@]} ))
[ "$OMITTED" -lt 0 ] && OMITTED=0

# Suggest bulk-read.sh only where it can work: not for secret-looking output, not
# in modes that cannot or should not run it, and not for a log bulk-read would
# refuse as too large once line numbers and delimiters are added.
SUGGEST=true
[ "$SECRET" = true ] && SUGGEST=false
case "$PMODE" in dontAsk | plan) SUGGEST=false ;; esac
[ $(( OUT_BYTES + NLINES * 8 + 1024 )) -le "$(shunt_max_payload)" ] || SUGGEST=false

EX="$DIR/$TID.excerpt"
(set -C; printf '' > "$EX") 2>/dev/null || EX=$(mktemp "$DIR/.excerpt.XXXXXX") || done_spill error
trap 'rm -f "$EX"' EXIT
{
  status="command succeeded"
  [ -n "$RCI" ] && status="command succeeded ($RCI)"
  printf '[shunt] %s; its stdout was %s chars, %s lines, saved in full to %s.\n' "$status" "$OUT_BYTES" "$NLINES" "$LOG"
  [ -n "$ERRLOG" ] && printf '[shunt] stderr was %s chars, saved in full to %s; its last lines are at the end.\n' "$ERR_LEN" "$ERRLOG"
  [ "$SECRET" = true ] && printf 'This output looks like it contains secret material; do not delegate it.\n'
  if [ "$SUGGEST" = true ]; then
    printf 'Showing the first and last lines. For the rest: Grep or Read a range of that file, or %s --question "<what you need>" --paths %q. Do not re-run the command just to see more.\n' \
      "$(shunt_script_path "$SCRIPT_DIR")" "$LOG"
  else
    printf 'Showing the first and last lines. For the rest: Grep or Read a range of that file. Do not re-run the command just to see more.\n'
  fi
  [ "${#HEAD[@]}" -gt 0 ] && printf '%s\n' "${HEAD[@]}"
  if [ "${#INDEX[@]}" -gt 0 ]; then
    printf '[diff index: log line:header, %s shown]\n' "${#INDEX[@]}"
    used=0
    for l in "${INDEX[@]}"; do
      n=$(blen "$l")
      [ $(( used + n + 1 )) -le 1200 ] || { printf '[... more files in the log ...]\n'; break; }
      printf '%s\n' "$l"; used=$(( used + n + 1 ))
    done
  fi
  [ "$OMITTED" -gt 0 ] && printf '[... %s lines omitted ...]\n' "$OMITTED"
  [ "${#TAIL[@]}" -gt 0 ] && printf '%s\n' "${TAIL[@]}"
  if [ -n "$ERRLOG" ]; then
    printf -- '--- stderr (last lines; all of it is in %s) ---\n' "$ERRLOG"
    ERRT=()
    while IFS= read -r l || [ -n "$l" ]; do ERRT+=("$(mark "$l")"); done < <(tail -n 20 -- "$ERRLOG" 2>/dev/null | bounded)
    used=0 i=$(( ${#ERRT[@]} - 1 )) OUT_E=()
    while [ "$i" -ge 0 ]; do
      l=${ERRT[$i]}; n=$(blen "$l")
      [ $(( used + n + 1 )) -le 1000 ] || break
      OUT_E=("$l" "${OUT_E[@]}"); used=$(( used + n + 1 )); i=$(( i - 1 ))
    done
    [ "${#OUT_E[@]}" -gt 0 ] && printf '%s\n' "${OUT_E[@]}"
  fi
} > "$EX" 2>/dev/null || done_spill error

# The original tool_response with only stdout and stderr replaced, so fields Claude
# Code reads (returnCodeInterpretation, noOutputExpected, ...) survive.
OUT_JSON=$(printf '%s' "$INPUT" | jq -c --rawfile out "$EX" --argjson keep "$KEEP_ERR" '
  {hookSpecificOutput:{hookEventName:"PostToolUse",updatedToolOutput:(
    (.tool_response | del(.persistedOutputPath, .persistedOutputSize))
    + {stdout:$out, stderr:(if $keep then (.tool_response.stderr // "") else "" end)}
    | .interrupted = (.interrupted // false) | .isImage = (.isImage // false))}}' 2>/dev/null) \
  || done_spill error
EXCERPT=$(jq -r '.hookSpecificOutput.updatedToolOutput.stdout | length' <<<"$OUT_JSON" 2>/dev/null) || EXCERPT=0
printf '%s\n' "$OUT_JSON"
done_spill spilled
