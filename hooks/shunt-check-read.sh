#!/usr/bin/env bash
# PreToolUse Read hook (shunt): a large whole-file read is redirected once to
# scripts/bulk-read.sh, which asks an inexpensive model the question instead of
# pulling the file into context. An optimisation, NOT a security boundary:
# every internal error, sensitive path, non-text file, targeted range, or
# missing session id allows silently; the identical Read repeated in the same
# session is allowed (logged as bypass), so a real need is never blocked twice.
# Policy (thresholds, sensitive list) lives in lib/shunt.sh. Kill switch:
# SHUNT_DISABLE=1.
# shellcheck source-path=SCRIPTDIR
set -uo pipefail

[ "${SHUNT_DISABLE:-0}" = "1" ] && exit 0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/input.sh" 2>/dev/null || exit 0
source "$SCRIPT_DIR/lib/shunt.sh" 2>/dev/null || exit 0
source "$SCRIPT_DIR/lib/state.sh" 2>/dev/null || exit 0
source "$SCRIPT_DIR/lib/log.sh" 2>/dev/null || true
command -v jq >/dev/null 2>&1 || exit 0
read_hook_input
START_MS=$(($(date +%s%N) / 1000000))

SHUNT_HOOK=shunt-read
T=$(shunt_threshold)
LINES=0 BYTES=0 RETURNED=0

FILE=$(hook_file_path)
[ -n "$FILE" ] || exit 0
CWD=$(hook_cwd)
# A whole non-negative number (or digit string) is a range bound; anything else
# (a word, a fraction, a negative) cannot be judged and allows. A limit too big
# for shell arithmetic is capped (still "huge"); such an offset is "cannot tell".
range_arg() { # range_arg <name>: the number, 0 when absent, x when unparseable
  echo "$HOOK_INPUT" | jq -r --arg k "$1" '.tool_input[$k]
    | if . == null then 0
      elif type == "number" and . >= 0 and . == floor then (if . < 1e12 then . else "big" end)
      elif type == "string" and test("^[0-9]+$") then (if length <= 12 then tonumber else "big" end)
      else "x" end' 2>/dev/null || echo x
}
OFFSET=$(range_arg offset)
LIMIT=$(range_arg limit)
case "$OFFSET" in '' | x | big) shunt_done unparsed ;; esac
case "$LIMIT" in '' | x) shunt_done unparsed ;; big) LIMIT=1000000000000 ;; esac

ABS=$(shunt_abs "$FILE" "${CWD:-$PWD}")
[ -f "$ABS" ] || exit 0
shunt_sensitive "$FILE" "${CWD:-$PWD}" && shunt_done sensitive
shunt_nontext "$ABS" && shunt_done nontext

LINES=$(shunt_count_lines "$ABS") || exit 0
BYTES=$(shunt_count_bytes "$ABS") || exit 0
MINB=$(shunt_min_bytes)

# Lines this read returns. Read's offset is the 1-based first line, so
# offset:0 and limit:0 both mean "from the start / no limit": not a range.
RETURNED=$LINES
[ "$OFFSET" -gt 0 ] && RETURNED=$(( LINES - OFFSET + 1 ))
[ "$RETURNED" -lt 0 ] && RETURNED=0
[ "$LIMIT" -gt 0 ] && [ "$LIMIT" -lt "$RETURNED" ] && RETURNED=$LIMIT
# Bytes it returns, pro rata, so a one-line minified file still counts as large.
RET_BYTES=0
[ "$LINES" -gt 0 ] && RET_BYTES=$(( BYTES * RETURNED / LINES ))

if [ "$RETURNED" -le "$T" ] && [ "$RET_BYTES" -le "$MINB" ]; then
  if [ "$OFFSET" -gt 0 ] || [ "$LIMIT" -gt 0 ]; then shunt_done targeted; fi
  shunt_done allow
fi

shunt_redirect "$SCRIPT_DIR" "$ABS|$OFFSET|$LIMIT" \
  "shunt: $ABS is $LINES lines ($BYTES bytes); this Read would return about $RETURNED lines, over the threshold of $T lines (or $MINB bytes)." \
  "$ABS" "For exact content, Read a range with offset/limit of at most $T lines." Read file
