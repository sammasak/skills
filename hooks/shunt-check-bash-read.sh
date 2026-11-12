#!/usr/bin/env bash
# PreToolUse Bash hook (shunt): the Bash spelling of a large whole-file read
# (cat/head/tail/less/more/bat/nl) is redirected once to scripts/bulk-read.sh,
# like shunt-check-read.sh does for Read. Simple patterns only, never a shell
# parser: any pipe, redirect, list, substitution, expansion, glob, escape,
# newline, env/sudo prefix or unknown option allows. Nothing from the command is
# evaluated or glob-expanded. Same fail-open, sensitive, non-text, repeat-bypass
# and logging rules as the Read hook; the repeat key is cwd + the command.
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

SHUNT_HOOK=shunt-bash
T=$(shunt_threshold)
MINB=$(shunt_min_bytes)
LINES=0 BYTES=0 RETURNED=0

CMD=$(hook_command)
[ -n "$CMD" ] || exit 0
case "$CMD" in
  cat\ * | head\ * | tail\ * | less\ * | more\ * | bat\ * | nl\ *) ;;
  *) exit 0 ;;
esac
# Anything beyond one simple invocation is out of scope: allow.
case "$CMD" in
  *[\|\>\<\;\&\$\`\{\}\(\)\\~\*\?\[\]]* | *$'\n'* | *$'\r'*) shunt_done compound ;;
esac

# Words: bare, or wrapped whole in one pair of single or double quotes.
TOKENS=()
rest="$CMD"
re_sq="^[[:space:]]*'([^']*)'([[:space:]]+|\$)"
re_dq='^[[:space:]]*"([^"]*)"([[:space:]]+|$)'
re_w="^[[:space:]]*([^[:space:]'\"]+)([[:space:]]+|\$)"
while [ -n "${rest//[[:space:]]/}" ]; do
  if [[ $rest =~ $re_sq ]] || [[ $rest =~ $re_dq ]] || [[ $rest =~ $re_w ]]; then
    TOKENS+=("${BASH_REMATCH[1]}")
    rest="${rest:${#BASH_REMATCH[0]}}"
  else
    shunt_done compound
  fi
done
TOOL="${TOKENS[0]}"
ARGS=("${TOKENS[@]:1}")

# Parse the bound: MODE lines|bytes; KIND first|last|from|allbut|whole; N count.
MODE=lines KIND=whole N=0
FILES=()
set_bound() { # set_bound <value>: [+-]digits, else allow
  local v="$1" sign=""
  case "$v" in +*) sign=+; v="${v#+}" ;; -*) sign=-; v="${v#-}" ;; esac
  case "$v" in '' | *[!0-9]*) shunt_done unparsed ;; esac
  [ "${#v}" -le 12 ] || v=1000000000000   # beyond shell arithmetic: just "huge"
  N=$((10#$v))
  if [ "$TOOL" = head ]; then
    [ "$sign" = - ] && KIND=allbut || KIND=first
  else
    [ "$sign" = + ] && KIND=from || KIND=last
  fi
}
if [ "$TOOL" = head ] || [ "$TOOL" = tail ]; then KIND=$([ "$TOOL" = head ] && echo first || echo last); N=10; fi

ddash=0 i=0
while [ "$i" -lt "${#ARGS[@]}" ]; do
  a="${ARGS[$i]}"; nxt="${ARGS[$((i + 1))]:-}"
  i=$((i + 1))
  if [ "$ddash" = 1 ] || [ "$a" = - ]; then [ "$a" = - ] || FILES+=("$a"); continue; fi
  [ "$a" = -- ] && { ddash=1; continue; }
  case "$TOOL" in
    head | tail)
      case "$a" in
        -f | -F | --follow | --follow=* | --retry | --pid=* | -s | --sleep-interval=*) shunt_done follow ;;
        -n | --lines) set_bound "$nxt"; i=$((i + 1)) ;;
        -c | --bytes) MODE=bytes; set_bound "$nxt"; i=$((i + 1)) ;;
        --lines=*) set_bound "${a#--lines=}" ;;
        --bytes=*) MODE=bytes; set_bound "${a#--bytes=}" ;;
        -n*) set_bound "${a#-n}" ;;
        -c*) MODE=bytes; set_bound "${a#-c}" ;;
        -q | -v | -z | --quiet | --silent | --verbose | --zero-terminated) ;;
        -[0-9]*) set_bound "${a#-}" ;;
        -* | +*) shunt_done unparsed ;;
        *) FILES+=("$a") ;;
      esac ;;
    cat)
      case "$a" in -*) ;; *) FILES+=("$a") ;; esac ;;
    nl)
      case "$a" in
        -[bdfhilnsvw]) i=$((i + 1)) ;;
        --*=* | -p | --no-renumber | -[bdfhilnsvw]?*) ;;
        -*) shunt_done unparsed ;;
        *) FILES+=("$a") ;;
      esac ;;
    less | more)
      case "$a" in
        -N | -R | -S | -n | -r | -X | -F | -d | -c | -s | -u | -f) ;;
        -* | +*) shunt_done unparsed ;;
        *) FILES+=("$a") ;;
      esac ;;
    bat)
      case "$a" in
        -p | -pp | -n | -A | -P | -u | --plain | --number | --show-all | --no-paging | --paging=* | --color=* | --style=* | --theme=*) ;;
        -*) shunt_done unparsed ;;
        *) FILES+=("$a") ;;
      esac ;;
  esac
done
[ "${#FILES[@]}" -gt 0 ] || exit 0

CWD=$(hook_cwd); CWD="${CWD:-$PWD}"
# returned <total>: how many of <total> units (lines or bytes) the bound prints.
returned() {
  local t="$1" r
  case "$KIND" in
    whole) r=$t ;;
    first | last) r=$(( N < t ? N : t )) ;;
    from) r=$(( t - (N > 0 ? N : 1) + 1 )) ;;
    allbut) r=$(( t - N )) ;;
  esac
  [ "$r" -lt 0 ] && r=0
  echo "$r"
}

BEST="" BEST_RET=-1 BEST_LINES=0 BEST_BYTES=0
for f in "${FILES[@]}"; do
  abs=$(shunt_abs "$f" "$CWD")
  [ -f "$abs" ] || continue
  shunt_sensitive "$f" "$CWD" && shunt_done sensitive
  shunt_nontext "$abs" && continue
  l=$(shunt_count_lines "$abs") || continue
  b=$(shunt_count_bytes "$abs") || continue
  if [ "$MODE" = bytes ]; then
    rb=$(returned "$b"); rl=0; [ "$b" -gt 0 ] && rl=$(( l * rb / b ))
  else
    rl=$(returned "$l"); rb=0; [ "$l" -gt 0 ] && rb=$(( b * rl / l ))
  fi
  if { [ "$rl" -gt "$T" ] || [ "$rb" -gt "$MINB" ]; } && [ "$rl" -gt "$BEST_RET" ]; then
    BEST=$abs BEST_RET=$rl BEST_LINES=$l BEST_BYTES=$b
  fi
done
[ -n "$BEST" ] || { [ "$KIND" = whole ] && shunt_done allow; shunt_done targeted; }
LINES=$BEST_LINES BYTES=$BEST_BYTES RETURNED=$BEST_RET

shunt_redirect "$SCRIPT_DIR" "$CWD|$CMD" \
  "shunt: this $TOOL would print about $RETURNED lines of $BEST ($LINES lines, $BYTES bytes), over the threshold of $T lines (or $MINB bytes)." \
  "$BEST" "For exact content, use the Read tool with offset/limit of at most $T lines." command output
