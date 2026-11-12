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

T=$(shunt_threshold)
LINES=0 BYTES=0 RETURNED=0

done_hook() { # done_hook <result> [exit]
  log_hook "shunt-read" "$1" "$(( ($(date +%s%N) / 1000000) - START_MS ))" \
    "{\"lines\":$LINES,\"bytes\":$BYTES,\"returned\":$RETURNED,\"threshold\":$T}" 2>/dev/null || true
  exit "${2:-0}"
}

FILE=$(hook_file_path)
[ -n "$FILE" ] || exit 0
CWD=$(hook_cwd)
OFFSET=$(echo "$HOOK_INPUT" | jq -r '.tool_input.offset // 0 | if type == "number" then floor else 0 end' 2>/dev/null)
LIMIT=$(echo "$HOOK_INPUT" | jq -r '.tool_input.limit // 0 | if type == "number" then floor else 0 end' 2>/dev/null)
OFFSET=$(shunt_int "$OFFSET" 0)
LIMIT=$(shunt_int "$LIMIT" 0)

ABS=$(shunt_abs "$FILE" "${CWD:-$PWD}")
[ -f "$ABS" ] || exit 0
shunt_sensitive "$FILE" "${CWD:-$PWD}" && done_hook sensitive
shunt_nontext "$ABS" && done_hook nontext

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
  if [ "$OFFSET" -gt 0 ] || [ "$LIMIT" -gt 0 ]; then done_hook targeted; fi
  done_hook allow
fi

seen_before shunt-read "$ABS|$OFFSET|$LIMIT"
case $? in
  0) done_hook bypass ;;
  1) ;;
  *) done_hook nostate ;;
esac

SCRIPT=$(shunt_script_path "$SCRIPT_DIR")
QFILE=$(printf '%q' "$ABS")
cat >&2 <<EOF
shunt: $ABS is $LINES lines ($BYTES bytes); this Read would return about $RETURNED lines, over the threshold of $T lines (or $MINB bytes).
To explore or summarise it, run this via Bash instead (see the bulk-reader skill):
  $SCRIPT --question "<what you need to know>" --paths $QFILE
For exact content, Read a range with offset/limit of at most $T lines.
Repeating this same Read will be allowed if the whole file is truly required.
EOF
done_hook redirect 2
