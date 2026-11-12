#!/usr/bin/env bash
# PreToolUse Read hook (shunt): a Read that would put more than SHUNT_MIN_TOKENS
# (default 8000) estimated tokens into context is redirected once per file to
# scripts/bulk-read.sh, which asks an inexpensive model the question instead.
# An optimisation, NOT a security boundary: every internal error allows, and so
# do sensitive, non-text, instruction and source files, allow_large, dontAsk and
# plan modes, skipped subagents and targeted ranges. Any later read of the same
# resolved file in the session (Read or Bash, any shape) is allowed and logged
# as bypass, so a real need is never blocked twice. Policy lives in
# lib/shunt.sh. Kill switch: SHUNT_DISABLE=1.
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
# shellcheck disable=SC2034  # START_MS and SHUNT_HOOK are read by shunt_done (lib/shunt.sh)
START_MS=$(($(date +%s%N) / 1000000))

# shellcheck disable=SC2034
SHUNT_HOOK=shunt-read
T=$(shunt_threshold)
LINES=0 BYTES=0 RETURNED=0 TOKENS=0

FILE=$(hook_file_path)
[ -n "$FILE" ] || exit 0
GATE=$(shunt_context_gate)
[ -n "$GATE" ] && shunt_done "$GATE"
[ "$(echo "$HOOK_INPUT" | jq -r '.tool_input.allow_large // false' 2>/dev/null)" = true ] && shunt_done explicit
CWD=$(hook_cwd)
# A non-negative number (floored, so 1700.0 and 1e3 work) or digit string is a
# range bound; anything else (a word, a negative) cannot be judged and allows. A
# limit too big for shell arithmetic is capped (still "huge"); such an offset is
# "cannot tell".
range_arg() { # range_arg <name>: the number, 0 when absent, x when unparseable
  echo "$HOOK_INPUT" | jq -r --arg k "$1" '.tool_input[$k]
    | if . == null then 0
      elif type == "number" then (if . < 0 then "x" elif . >= 1e12 then "big" else floor end)
      elif type == "string" and test("^[0-9]+$") then (if length <= 12 then tonumber else "big" end)
      else "x" end' 2>/dev/null || echo x
}
OFFSET=$(range_arg offset)
LIMIT=$(range_arg limit)
[ "$LIMIT" = big ] && LIMIT=1000000000000
# Anything still not a plain integer (jq printing 1e+03, say) cannot be judged: allow.
[[ "$OFFSET" =~ ^[0-9]+$ ]] || shunt_done unparsed
[[ "$LIMIT" =~ ^[0-9]+$ ]] || shunt_done unparsed

ABS=$(shunt_abs "$FILE" "${CWD:-$PWD}")
[ -f "$ABS" ] || exit 0
REAL=$(realpath -e -- "$ABS" 2>/dev/null) || exit 0
shunt_sensitive "$FILE" "${CWD:-$PWD}" && shunt_done sensitive
shunt_nontext "$REAL" && shunt_done nontext
shunt_instructions "$ABS" "$REAL" "$SCRIPT_DIR" && shunt_done instructions
shunt_source "$REAL" && shunt_done source

LINES=$(shunt_count_lines "$REAL") || exit 0
BYTES=$(shunt_count_bytes "$REAL") || exit 0

# Lines this read returns. Read's offset is the 1-based first line, so
# offset:0 and limit:0 both mean "from the start / no limit": not a range.
RETURNED=$LINES
[ "$OFFSET" -gt 0 ] && RETURNED=$(( LINES - OFFSET + 1 ))
[ "$RETURNED" -lt 0 ] && RETURNED=0
[ "$LIMIT" -gt 0 ] && [ "$LIMIT" -lt "$RETURNED" ] && RETURNED=$LIMIT
# Bytes it returns, pro rata, so a one-line minified file still counts.
RET_BYTES=0
[ "$LINES" -gt 0 ] && RET_BYTES=$(( BYTES * RETURNED / LINES ))
TOKENS=$(shunt_tokens "$RET_BYTES" "$RETURNED")

if [ "$TOKENS" -le "$T" ]; then
  if [ "$OFFSET" -gt 0 ] || [ "$LIMIT" -gt 0 ]; then shunt_done targeted; fi
  shunt_done allow
fi

# Only a read that would be redirected pays for these: a file bulk-read.sh would
# refuse (private mode, key material) is read normally, never sent toward it.
shunt_private "$REAL" && shunt_done private
shunt_secret_marker "$REAL" && shunt_done secret

shunt_redirect "$SCRIPT_DIR" "$ABS" "$REAL" \
  "shunt: $ABS is $LINES lines ($BYTES bytes); this Read would put about $TOKENS tokens in context, over the threshold of $T."
