#!/usr/bin/env bash
# Shunt suite: the two redirect hooks and scripts/bulk-read.sh, offline.
# A fake claude first on PATH serves canned CLI results chosen by
# FAKE_CLAUDE_MODE; no network, no model. XDG dirs point into a temp dir.
# Run: bash tests/test-shunt.sh   (also wired as skills:test:shunt and pre-push)

# ok/bad always succeed, so `A && ok || bad` is an if-then-else here; $ in single quotes is literal on purpose.
# shellcheck disable=SC2015,SC2016
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOKS="$ROOT/hooks"
BULK="$ROOT/scripts/bulk-read.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export XDG_RUNTIME_DIR="$TMP/run" XDG_STATE_HOME="$TMP/state" XDG_CACHE_HOME="$TMP/cache"
mkdir -p "$XDG_RUNTIME_DIR" "$XDG_STATE_HOME" "$XDG_CACHE_HOME"
# No inherited SHUNT_* (a live SHUNT_CLAUDE_BIN would beat the fake and call a real model); each case sets its own.
for v in "${!SHUNT_@}"; do unset "$v"; done
unset CLAUDE_CODE_MAX_OUTPUT_TOKENS
# 022: fixtures are 0644, so the private-mode guard is active (it stands down under 077; tested below).
umask 022
F="$TMP/f"; mkdir -p "$F"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }

# check <name> <want_exit> <stderr_pattern|-> <hook> <stdin_json>
check() {
  local name="$1" want_exit="$2" err_pat="$3" hook="$4" json="$5" code err
  printf '%s' "$json" | "$HOOKS/$hook" >"$TMP/out" 2>"$TMP/err"; code=$?
  err=$(cat "$TMP/err")
  if [ "$code" -eq "$want_exit" ] && { [ "$err_pat" = - ] || grep -qF -- "$err_pat" "$TMP/err"; }; then ok; else
    bad "$name (exit=$code want=$want_exit; stderr='$err')"; fi
}
# rd <file_path> [offset] [limit] [session]: Read hook input; each call a fresh session unless given
rd() { jq -nc --arg p "$1" --arg s "shunttest-${4:-r$RANDOM$RANDOM}" --argjson o "${2:-null}" --argjson l "${3:-null}" \
  '{session_id: $s, cwd: "/", tool_input: ({file_path: $p} + (if $o == null then {} else {offset: $o} end) + (if $l == null then {} else {limit: $l} end))}'; }
# bc <command> [session] [cwd]
bc() { jq -nc --arg c "$1" --arg s "shunttest-${2:-b$RANDOM$RANDOM}" --arg d "${3:-$F}" '{session_id: $s, cwd: $d, tool_input: {command: $c}}'; }

# fill <n> [width]: n lines of exactly width bytes (default 50), each starting with its number.
fill() { seq -f "%-$(( ${2:-50} - 1 ))g" 1 "$1"; }
# Token estimate is bytes*2/7 + lines*11/10 (threshold 8000). big.txt: 2000 x 50 B
# = 30771 tokens, at most 520 lines per ranged read. 35-byte lines cost 11.1 tokens:
# 720 lines = 7992 (allowed), 721 = 8003 (redirected).
seq 1 100 > "$F/small.txt"
fill 720 35 > "$F/t7992.txt"
fill 721 35 > "$F/t8003.txt"
fill 2000 > "$F/big.txt"
head -c 70000 /dev/zero | tr '\0' 'a' > "$F/minified.json"
: > "$F/empty.txt"
fill 2000 > "$F/pic.png"
{ seq 1 2000; printf 'x\0y\n'; } > "$F/blob.bin"
mkdir -p "$F/secrets" "$F/home/.ssh" "$F/dir"
fill 2000 > "$F/.env"; fill 2000 > "$F/.env.local"; fill 2000 > "$F/server.pem"
fill 2000 > "$F/api_token.txt"; fill 2000 > "$F/secrets/db.yaml"; fill 2000 > "$F/home/.ssh/config"
fill 2000 > "$F/app.sops.yaml"; fill 2000 > "$F/credentials.json"
ln -s "$F/.env" "$F/innocent.txt"
fill 2000 > "$F/with space.txt"
fill 2000 > "$F/vendor.log"

R=shunt-check-read.sh
B=shunt-check-bash-read.sh

# ── Read hook: size ──
check "small file allowed" 0 - $R "$(rd "$F/small.txt")"
check "7992 estimated tokens allowed" 0 - $R "$(rd "$F/t7992.txt")"
check "8003 estimated tokens redirected" 2 "about 8003 tokens in context, over the threshold of 8000" $R "$(rd "$F/t8003.txt")"
check "empty file allowed" 0 - $R "$(rd "$F/empty.txt")"
check "byte-large one-line file redirected" 2 "70000 bytes" $R "$(rd "$F/minified.json")"
# ── Read hook: ranges ──
check "bounded limit allowed" 0 - $R "$(rd "$F/big.txt" null 200)"
check "limit 0 is not a range" 2 "shunt:" $R "$(rd "$F/big.txt" null 0)"
check "offset 0 is not a range" 2 "shunt:" $R "$(rd "$F/big.txt" 0)"
check "huge limit redirected" 2 "shunt:" $R "$(rd "$F/big.txt" 1 100000)"
check "offset near end allowed" 0 - $R "$(rd "$F/big.txt" 1800)"
check "offset with bounded limit allowed" 0 - $R "$(rd "$F/big.txt" 500 300)"
check "offset leaving too much redirected" 2 "shunt:" $R "$(rd "$F/big.txt" 1000)"
rdj() { jq -nc --arg p "$F/big.txt" --arg s "shunttest-j$RANDOM$RANDOM" --argjson ti "$1" '{session_id:$s,tool_input:({file_path:$p} + $ti)}'; }
check "non-numeric offset cannot be judged: allowed" 0 - $R "$(rdj '{"offset":"x"}')"
check "non-numeric limit cannot be judged: allowed" 0 - $R "$(rdj '{"limit":"y"}')"
check "negative offset cannot be judged: allowed" 0 - $R "$(rdj '{"offset":-5}')"
check "overflowing offset cannot be judged: allowed" 0 - $R "$(rdj '{"offset":1e30}')"
check "overflowing digit-string offset: allowed" 0 - $R "$(rdj '{"offset":"99999999999999999999999"}')"
check "overflowing limit is still huge: redirected" 2 "shunt:" $R "$(rdj '{"limit":1e30}')"
check "digit-string offset near end allowed" 0 - $R "$(rdj '{"offset":"1800"}')"
check "float offset near end allowed" 0 - $R "$(rdj '{"offset":1800.0}')"
check "exponent offset near end allowed" 0 - $R "$(rdj '{"offset":1.8e3}')"
check "float offset leaving too much redirected" 2 "shunt:" $R "$(rdj '{"offset":10.0}')"
check "float limit bounded allowed" 0 - $R "$(rdj '{"limit":200.0}')"
check "exponent limit bounded allowed" 0 - $R "$(rdj '{"limit":2e2}')"
check "exponent limit too large redirected" 2 "shunt:" $R "$(rdj '{"limit":5e3}')"
check "fractional offset floored" 0 - $R "$(rdj '{"offset":1800.7}')"
for v in 1700.0 1e3 2e2; do
  printf '%s' "$(rdj "{\"offset\":$v}")" | "$HOOKS/$R" >/dev/null 2>"$TMP/err"
  grep -q "integer expected" "$TMP/err" && bad "offset $v: shell arithmetic error" || ok
done
for sid in '../escape' 'a/b' 'x y' 'semi;colon'; do
  check "session id '$sid' keeps no state: allowed" 0 - $R "$(jq -nc --arg p "$F/big.txt" --arg s "$sid" '{session_id:$s,tool_input:{file_path:$p}}')"
done
[ -z "$(find "$TMP" / -maxdepth 2 -name '*escape*.seen' 2>/dev/null)" ] && ok || bad "an unsafe session id wrote state"
grep -q '"result":"nostate"' "$XDG_STATE_HOME"/claude-hooks/*.jsonl && ok || bad "nostate not logged"
# ── Read hook: shapes that always allow ──
check "nonexistent path allowed" 0 - $R "$(rd "$F/nope.txt")"
check "directory allowed" 0 - $R "$(rd "$F/dir")"
check "empty path allowed" 0 - $R "$(rd "")"
check "missing tool_input allowed" 0 - $R '{"session_id":"shunttest-x"}'
check "garbage input allowed" 0 - $R "not json"
check "empty input allowed" 0 - $R ""
check "missing session id allowed" 0 - $R "$(jq -nc --arg p "$F/big.txt" '{tool_input:{file_path:$p}}')"
check "image allowed" 0 - $R "$(rd "$F/pic.png")"
check "binary allowed" 0 - $R "$(rd "$F/blob.bin")"
# ── Read hook: sensitive and excluded ──
for s in .env .env.local server.pem api_token.txt secrets/db.yaml home/.ssh/config app.sops.yaml credentials.json innocent.txt; do
  check "sensitive $s allowed silently" 0 - $R "$(rd "$F/$s")"
  [ -s "$TMP/err" ] && bad "sensitive $s produced stderr"
done
check "vendor.log redirected before exclusion" 2 "shunt:" $R "$(rd "$F/vendor.log")"
SHUNT_EXCLUDE="/nowhere/*:*.log" check "SHUNT_EXCLUDE allows silently" 0 - $R "$(rd "$F/vendor.log")"
# a pattern that also matches a file in the cwd must stay a pattern (no pathname expansion)
mkdir -p "$TMP/globcwd/g"; : > "$TMP/globcwd/unrelated.log"; fill 2000 > "$TMP/globcwd/g/vendor.log"
# (no subshells around assertions: the PASS/FAIL counters must survive)
cd "$TMP/globcwd" || exit 1
SHUNT_EXCLUDE='*.log' check "SHUNT_EXCLUDE not glob-expanded against cwd (Read)" 0 - $R "$(rd "$TMP/globcwd/g/vendor.log")"
cd "$ROOT" || exit 1
[ -s "$TMP/err" ] && bad "SHUNT_EXCLUDE glob: Read hook redirected" || ok
# file guards in the hooks: a large file bulk-read.sh would refuse is read normally, never redirected
fill 2000 > "$F/private-notes.txt"; chmod 600 "$F/private-notes.txt"
check "private-mode large file allowed (umask 022)" 0 - $R "$(rd "$F/private-notes.txt")"
fill 2000 > "$F/open-notes.txt"; chmod 644 "$F/open-notes.txt"
check "same content at 0644 redirected" 2 "shunt:" $R "$(rd "$F/open-notes.txt")"
umask 077; check "private-mode guard stands down under umask 077" 2 "shunt:" $R "$(rd "$F/private-notes.txt")"; umask 022
{ echo "-----BEGIN OPENSSH PRIVATE KEY-----"; fill 2000; } > "$F/notes-a.txt"
check "key marker in a large file allowed (Read)" 0 - $R "$(rd "$F/notes-a.txt")"
check "key marker in a large file allowed (Bash)" 0 - $B "$(bc "cat notes-a.txt")"
check "private-mode file allowed (Bash)" 0 - $B "$(bc "cat private-notes.txt")"
# ── Read hook: switches ──
SHUNT_DISABLE=1 check "SHUNT_DISABLE allows" 0 - $R "$(rd "$F/big.txt")"
SHUNT_MIN_TOKENS=abc check "non-numeric threshold falls back to 8000 (8003 redirected)" 2 "threshold of 8000" $R "$(rd "$F/t8003.txt")"
SHUNT_MIN_TOKENS=abc check "non-numeric threshold falls back to 8000 (7992 allowed)" 0 - $R "$(rd "$F/t7992.txt")"
SHUNT_MIN_TOKENS=50000 check "raised threshold allows" 0 - $R "$(rd "$F/big.txt")"
SHUNT_MIN_LINES=10 SHUNT_MIN_BYTES=10 check "removed SHUNT_MIN_LINES/BYTES have no effect" 0 - $R "$(rd "$F/small.txt")"
# ── Read hook: message and repeat ──
check "message names the script" 2 "$ROOT/scripts/bulk-read.sh --question \"<what you need to know>\" --paths $F/big.txt" $R "$(rd "$F/big.txt" null null rep)"
check "message offers a ranged Read that fits" 2 "Read at most 520 lines at a time" $R "$(rd "$F/big.txt" null null rep2)"
check "identical repeat allowed" 0 - $R "$(rd "$F/big.txt" null null rep)"
check "third repeat still allowed" 0 - $R "$(rd "$F/big.txt" null null rep)"
check "same file, other session: redirected" 2 "shunt:" $R "$(rd "$F/big.txt" null null rep3)"
check "same session, other large range of the same file: allowed (key is the file)" 0 - $R "$(rd "$F/big.txt" 1 1000 rep)"
check "quoted path with space in message" 2 'with\ space.txt' $R "$(rd "$F/with space.txt")"
grep -q '"hook":"shunt-read".*"result":"bypass"' "$XDG_STATE_HOME"/claude-hooks/*.jsonl && ok || bad "bypass not logged"
grep -q '"hook":"shunt-read".*"result":"redirect".*"lines":2000.*"tokens":30771' "$XDG_STATE_HOME"/claude-hooks/*.jsonl && ok || bad "redirect not logged with line count"
grep -q '"result":"sensitive"' "$XDG_STATE_HOME"/claude-hooks/*.jsonl && ok || bad "sensitive not logged"

# ── Bash hook ──
check "cat large redirected" 2 "this cat would print about 2000 lines" $B "$(bc "cat big.txt")"
check "cat small allowed" 0 - $B "$(bc "cat small.txt")"
check "head default (10) allowed" 0 - $B "$(bc "head big.txt")"
check "tail default (10) allowed" 0 - $B "$(bc "tail big.txt")"
check "less large redirected" 2 "shunt:" $B "$(bc "less big.txt")"
check "more large redirected" 2 "shunt:" $B "$(bc "more big.txt")"
check "nl large redirected" 2 "shunt:" $B "$(bc "nl -ba big.txt")"
check "bat large redirected" 2 "shunt:" $B "$(bc "bat -p big.txt")"
check "bat line range allowed" 0 - $B "$(bc "bat -r 1:20 big.txt")"
check "head -n 5 allowed" 0 - $B "$(bc "head -n 5 big.txt")"
check "head -5 allowed" 0 - $B "$(bc "head -5 big.txt")"
check "head -n5 allowed" 0 - $B "$(bc "head -n5 big.txt")"
check "tail -n 20 allowed" 0 - $B "$(bc "tail -n 20 big.txt")"
check "tail --lines=20 allowed" 0 - $B "$(bc "tail --lines=20 big.txt")"
check "head -n 520 allowed (exactly 8000 tokens)" 0 - $B "$(bc "head -n 520 big.txt")"
check "head -n 5000 redirected" 2 "about 2000 lines" $B "$(bc "head -n 5000 big.txt")"
check "head -n 600 redirected" 2 "about 600 lines" $B "$(bc "head -n 600 big.txt")"
check "tail -n +1700 allowed" 0 - $B "$(bc "tail -n +1700 big.txt")"
check "tail -n +2 redirected" 2 "about 1999 lines" $B "$(bc "tail -n +2 big.txt")"
check "head -n -10 redirected" 2 "about 1990 lines" $B "$(bc "head -n -10 big.txt")"
check "head -c 1000 allowed" 0 - $B "$(bc "head -c 1000 minified.json")"
check "cat minified redirected" 2 "70000 bytes" $B "$(bc "cat minified.json")"
check "tail -f allowed" 0 - $B "$(bc "tail -f big.txt")"
check "tail -F allowed" 0 - $B "$(bc "tail -F big.txt")"
check "head -n with an overflowing count redirected" 2 "shunt:" $B "$(bc "head -n 99999999999999999999999 big.txt")"
check "unknown suffix allowed" 0 - $B "$(bc "head -n 1K big.txt")"
check "pipe allowed" 0 - $B "$(bc "cat big.txt | grep 5")"
check "redirect allowed" 0 - $B "$(bc "cat big.txt > /tmp/x")"
check "and-list allowed" 0 - $B "$(bc "cat big.txt && echo done")"
check "semicolon allowed" 0 - $B "$(bc "cat big.txt; echo done")"
check "substitution allowed" 0 - $B "$(bc 'cat $(echo big.txt)')"
check "variable allowed" 0 - $B "$(bc 'cat $HOME/big.txt')"
check "tilde allowed" 0 - $B "$(bc 'cat ~/big.txt')"
check "glob allowed (never expanded)" 0 - $B "$(bc 'cat *.txt')"
check "newline allowed" 0 - $B "$(bc $'cat big.txt\necho hi')"
check "sudo prefix allowed" 0 - $B "$(bc "sudo cat big.txt")"
check "env prefix allowed" 0 - $B "$(bc "LC_ALL=C cat big.txt")"
check "large file second redirected, names it" 2 "of $F/big.txt" $B "$(bc "cat small.txt big.txt")"
check "largest offender named" 2 "of $F/big.txt" $B "$(bc "cat t8003.txt big.txt small.txt")"
check "double-quoted path with space redirected" 2 'with\ space.txt' $B "$(bc 'cat "with space.txt"')"
check "single-quoted path with space redirected" 2 "shunt:" $B "$(bc "cat 'with space.txt'")"
check "partial quoting allowed" 0 - $B "$(bc 'cat with" "space.txt')"
check "absolute path redirected" 2 "shunt:" $B "$(bc "cat $F/big.txt" "" /)"
check "relative path resolved against cwd" 0 - $B "$(bc "cat big.txt" "" /)"
check "git status ignored" 0 - $B "$(bc "git status")"
check "grep ignored" 0 - $B "$(bc "grep -r foo big.txt")"
check "catalog-like command ignored" 0 - $B "$(bc "catalog big.txt")"
check "sensitive file allowed" 0 - $B "$(bc "cat .env")"
check "sensitive among large allowed" 0 - $B "$(bc "cat big.txt secrets/db.yaml")"
check "symlink to sensitive allowed" 0 - $B "$(bc "cat innocent.txt")"
check "image allowed" 0 - $B "$(bc "cat pic.png")"
check "binary allowed" 0 - $B "$(bc "cat blob.bin")"
check "nonexistent allowed" 0 - $B "$(bc "cat nope.txt")"
check "message names the script" 2 "$ROOT/scripts/bulk-read.sh --question" $B "$(bc "cat big.txt")"
check "message offers a ranged Read that fits" 2 "Read at most 520 lines at a time" $B "$(bc "cat big.txt")"
SHUNT_DISABLE=1 check "SHUNT_DISABLE allows" 0 - $B "$(bc "cat big.txt")"
check "missing session id allowed" 0 - $B "$(jq -nc --arg d "$F" '{cwd:$d,tool_input:{command:"cat big.txt"}}')"
check "bash: first attempt redirected" 2 "shunt:" $B "$(bc "cat big.txt" brep)"
check "bash: identical repeat allowed" 0 - $B "$(bc "cat big.txt" brep)"
check "bash: other session redirected" 2 "shunt:" $B "$(bc "cat big.txt" brep2)"
check "bash: same file from another cwd is the same key: allowed" 0 - $B "$(bc "cat $F/big.txt" brep "$F/dir")"
grep -q '"hook":"shunt-bash".*"result":"bypass"' "$XDG_STATE_HOME"/claude-hooks/*.jsonl && ok || bad "bash bypass not logged"

# ── v2: token trigger, exemptions, shared repeat key, advice ──
seq 1 2000 > "$F/nine-kb.txt"
check "2000-line 9 KB file allowed (about 4.7k tokens)" 0 - $R "$(rd "$F/nine-kb.txt")"
check "Bash: cat of a 2000-line 9 KB file allowed" 0 - $B "$(bc "cat nine-kb.txt")"
fill 241 73 > "$F/role-like.md"
check "241-line 17.5 KB markdown allowed" 0 - $R "$(rd "$F/role-like.md")"
mkdir -p "$F/proj/.claude/agents"
for n in CLAUDE.md AGENTS.md ROLE.md SKILL.md MEMORY.md; do
  fill 2000 > "$F/proj/$n"
  check "instruction file $n allowed" 0 - $R "$(rd "$F/proj/$n")"
done
fill 2000 > "$F/proj/.claude/agents/notes.txt"
check "anything under .claude/ allowed" 0 - $R "$(rd "$F/proj/.claude/agents/notes.txt")"
check "Bash: cat CLAUDE.md allowed" 0 - $B "$(bc "cat proj/CLAUDE.md")"
fill 2000 > "$F/proj/notes.md"
check "control: same size, ordinary name redirected" 2 "shunt:" $R "$(rd "$F/proj/notes.md")"
SHUNT_MIN_TOKENS=50 check "file in the hooks' own repo allowed" 0 - $R "$(rd "$ROOT/README.md")"
cp "$ROOT/README.md" "$F/readme-copy.md"; chmod 644 "$F/readme-copy.md"
SHUNT_MIN_TOKENS=50 check "control: the same file outside the repo redirected" 2 "shunt:" $R "$(rd "$F/readme-copy.md")"
ln -s "$ROOT/README.md" "$F/readme-link.md"
SHUNT_MIN_TOKENS=50 check "symlink into the hooks' repo allowed (resolved)" 0 - $R "$(rd "$F/readme-link.md")"
fill 900 > "$F/main.rs"; fill 900 > "$F/Makefile"; fill 900 > "$F/app.tsx"
check ".rs source allowed by default" 0 - $R "$(rd "$F/main.rs")"
check ".tsx source allowed by default" 0 - $R "$(rd "$F/app.tsx")"
check "Makefile allowed by default" 0 - $R "$(rd "$F/Makefile")"
check "Bash: cat of source allowed by default" 0 - $B "$(bc "cat main.rs")"
SHUNT_INCLUDE_SOURCE=1 check ".rs redirected with SHUNT_INCLUDE_SOURCE=1" 2 "shunt:" $R "$(rd "$F/main.rs")"
SHUNT_INCLUDE_SOURCE=1 check "Bash: source redirected with SHUNT_INCLUDE_SOURCE=1" 2 "shunt:" $B "$(bc "cat main.rs")"
rdx() { jq -nc --arg p "$1" --arg s "shunttest-x$RANDOM$RANDOM" --argjson top "$2" --argjson ti "${3:-{\}}" \
  '{session_id:$s,cwd:"/",tool_input:({file_path:$p} + $ti)} + $top'; }
bcx() { jq -nc --arg c "$1" --arg s "shunttest-x$RANDOM$RANDOM" --arg d "$F" --argjson top "$2" '{session_id:$s,cwd:$d,tool_input:{command:$c}} + $top'; }
check "allow_large: true allowed" 0 - $R "$(rdx "$F/big.txt" '{}' '{"allow_large":true}')"
check "allow_large: false still redirected" 2 "shunt:" $R "$(rdx "$F/big.txt" '{}' '{"allow_large":false}')"
for m in dontAsk plan; do
  check "permission_mode $m allowed (Read)" 0 - $R "$(rdx "$F/big.txt" "{\"permission_mode\":\"$m\"}")"
  check "permission_mode $m allowed (Bash)" 0 - $B "$(bcx "cat big.txt" "{\"permission_mode\":\"$m\"}")"
done
for m in default acceptEdits auto bypassPermissions; do
  check "permission_mode $m still redirected" 2 "shunt:" $R "$(rdx "$F/big.txt" "{\"permission_mode\":\"$m\"}")"
done
for a in Explore claude-code-guide statusline-setup; do
  check "agent_type $a allowed" 0 - $R "$(rdx "$F/big.txt" "{\"agent_type\":\"$a\"}")"
done
check "agent_type Explore allowed (Bash)" 0 - $B "$(bcx "cat big.txt" '{"agent_type":"Explore"}')"
check "agent_type general-purpose redirected" 2 "shunt:" $R "$(rdx "$F/big.txt" '{"agent_type":"general-purpose"}')"
SHUNT_SKIP_AGENTS="general-purpose, code-reviewer" check "SHUNT_SKIP_AGENTS list honoured" 0 - $R "$(rdx "$F/big.txt" '{"agent_type":"code-reviewer"}')"
SHUNT_SKIP_AGENTS="general-purpose" check "SHUNT_SKIP_AGENTS replaces the default" 2 "shunt:" $R "$(rdx "$F/big.txt" '{"agent_type":"Explore"}')"
SHUNT_SKIP_AGENTS="" check "empty SHUNT_SKIP_AGENTS covers every agent" 2 "shunt:" $R "$(rdx "$F/big.txt" '{"agent_type":"Explore"}')"
for r in instructions source explicit mode subagent; do
  grep -q "\"result\":\"$r\"" "$XDG_STATE_HOME"/claude-hooks/*.jsonl && ok || bad "result $r not logged"
done
# one redirect per file per session, whichever hook and shape
redirects=0
for step in r-whole r-offset1 b-doublespace r-link; do
  case $step in
    r-whole) j=$(rd "$F/big.txt" null null share) h=$R ;;
    r-offset1) j=$(rd "$F/big.txt" 1 null share) h=$R ;;
    b-doublespace) j=$(bc "cat  big.txt" share) h=$B ;;
    r-link) ln -sf "$F/big.txt" "$F/big-link.txt"; j=$(rd "$F/big-link.txt" null null share) h=$R ;;
  esac
  printf '%s' "$j" | "$HOOKS/$h" >/dev/null 2>&1; [ $? -eq 2 ] && redirects=$((redirects + 1))
done
[ "$redirects" -eq 1 ] && ok || bad "whole, offset:1, 'cat  f' and a symlink in one session gave $redirects redirects, want 1"
check "Bash first, then Read of the same file: allowed" 2 "shunt:" $B "$(bc "cat big.txt" share2)"
check "...the Read that follows is allowed" 0 - $R "$(rd "$F/big.txt" null null share2)"
ls "$XDG_RUNTIME_DIR"/claude-shunt-shunttest-share.seen >/dev/null 2>&1 && ok || bad "one shared state file per session expected"
# the range advice fits
fill 300 300 > "$F/wide.txt"
check "300 x 300 B redirected" 2 "shunt:" $R "$(rd "$F/wide.txt")"
N=$(sed -n 's/.*Read at most \([0-9]*\) lines.*/\1/p' "$TMP/err")
[ -n "$N" ] && [ "$N" -ge 1 ] && ok || bad "no range advice for wide.txt"
check "following the advice from the top is allowed" 0 - $R "$(rd "$F/wide.txt" 1 "${N:-1}")"
check "following the advice at the end is allowed" 0 - $R "$(rd "$F/wide.txt" $(( 300 - ${N:-1} + 1 )) "${N:-1}")"
check "one line more than the advice is redirected (advice is the maximum)" 2 "shunt:" $R "$(rd "$F/wide.txt" 1 $(( ${N:-1} + 1 )))"
head -c 65536 /dev/zero | tr '\0' 'a' > "$F/one-line.json"
check "one-line 64 KB JSON redirected" 2 "shunt:" $R "$(rd "$F/one-line.json")"
grep -q "Read at most" "$TMP/err" && bad "one-line file got range advice" || ok
grep -q "If you will edit this file, Read the range you will change, or repeat this read." "$TMP/err" && ok || bad "edit advice missing"
grep -q "allow_large is not needed" "$TMP/err" && ok || bad "allow_large note missing"
fill 5000 > "$F/huge.txt"
check "file over the payload cap redirected" 2 "over the bulk-read payload cap (200000 bytes)" $R "$(rd "$F/huge.txt")"
grep -q "bulk-read.sh" "$TMP/err" && bad "file over the payload cap still suggested the script" || ok
grep -q "use Grep" "$TMP/err" && ok || bad "file over the payload cap: no Grep suggestion"
SHUNT_MAX_PAYLOAD_BYTES=300000 check "raised payload cap suggests the script again" 2 "bulk-read.sh --question" $R "$(rd "$F/huge.txt")"
# unreadable state file: allow silently (no "Permission denied" from a failed redirect)
: > "$XDG_RUNTIME_DIR/claude-shunt-shunttest-locked.seen"; chmod 000 "$XDG_RUNTIME_DIR/claude-shunt-shunttest-locked.seen"
check "unreadable state file allows" 0 - $R "$(rd "$F/big.txt" null null locked)"
[ -s "$TMP/err" ] && bad "unreadable state file printed '$(cat "$TMP/err")'" || ok
chmod 600 "$XDG_RUNTIME_DIR/claude-shunt-shunttest-locked.seen"

# ── v2 review: LINES, physical paths, 2000-line cap, int bounds, no HOME, source list ──
# LINES is bash's terminal-rows variable: under a sized pty the hook must still use the file's line count
if command -v script >/dev/null 2>&1; then
  rd "$F/big.txt" null null pty > "$TMP/pty.json"
  script -qec "stty rows 24 cols 80; '$HOOKS/$R' < '$TMP/pty.json'" "$TMP/pty.log" >/dev/null 2>&1
  grep -q "Read at most 520 lines" "$TMP/pty.log" && ok || bad "pty: range advice wrong: $(grep -o 'Read at most [0-9]* lines' "$TMP/pty.log")"
  grep -q '"session":"shunttest-pty".*"lines":2000' "$XDG_STATE_HOME"/claude-hooks/*.jsonl && ok || bad "pty: logged line count is not the file's"
else
  echo "SKIP: pty test (no script(1) on PATH)"
fi
mkdir -p "$TMP/fakehome"; ln -s "$HOOKS" "$TMP/fakehome/hooks"; ln -s "$HOOKS/$R" "$TMP/fakehome/read-hook.sh"
fill 2000 > "$TMP/fakehome/notes.txt"
for h in "$TMP/fakehome/hooks/$R" "$TMP/fakehome/read-hook.sh"; do
  printf '%s' "$(rd "$TMP/fakehome/notes.txt")" | "$h" >/dev/null 2>"$TMP/err"; code=$?
  [ "$code" -eq 2 ] && ok || bad "symlinked hook $h exempted a foreign tree (exit $code)"
  grep -qF "$ROOT/scripts/bulk-read.sh --question" "$TMP/err" && ok || bad "symlinked hook $h named the wrong script: $(cat "$TMP/err")"
done
fill 5000 8 > "$F/narrow.txt"
check "5000 x 8 B whole Read (capped at 2000 lines, ~6.8k tokens) allowed" 0 - $R "$(rd "$F/narrow.txt")"
grep -q '"lines":5000,"bytes":40000,"returned":2000' "$XDG_STATE_HOME"/claude-hooks/*.jsonl && ok || bad "2000-line cap not reflected in the log"
check "the same file with limit 5000 redirected (no cap with an explicit limit)" 2 "shunt:" $R "$(rd "$F/narrow.txt" null 5000)"
SHUNT_MIN_TOKENS=9999999999999999999 check "a threshold over 15 digits falls back to 8000" 2 "threshold of 8000" $R "$(rd "$F/t8003.txt")"
SHUNT_MIN_TOKENS=999999999999999 check "a 15-digit threshold is used" 0 - $R "$(rd "$F/big.txt")"
for h in $R $B; do
  if [ "$h" = "$R" ]; then j=$(rd "$F/big.txt"); else j=$(bc "cat big.txt"); fi
  printf '%s' "$j" | env -u HOME -u XDG_STATE_HOME -u XDG_RUNTIME_DIR "$HOOKS/$h" >/dev/null 2>"$TMP/err"; code=$?
  [ "$code" -eq 0 ] && [ ! -s "$TMP/err" ] && ok || bad "$h with HOME and XDG dirs unset: exit $code, stderr '$(cat "$TMP/err")'"
done
for e in sql css v r m s pl; do
  fill 2000 > "$F/data.$e"
  check "large .$e is not exempt as source" 2 "shunt:" $R "$(rd "$F/data.$e")"
done
fill 2000 > "$F/bundle.min.js"; fill 2000 > "$F/site.min.css"; fill 2000 > "$F/app.js"
check "*.min.js is not source" 2 "shunt:" $R "$(rd "$F/bundle.min.js")"
check "*.min.css is not source" 2 "shunt:" $R "$(rd "$F/site.min.css")"
check "plain .js is still source" 0 - $R "$(rd "$F/app.js")"

# ── PostToolUse spill of large command output ──
SP=shunt-spill-output.sh
SPROOT="$XDG_CACHE_HOME/claude-spill"
# spin <stdout-file> [json merged over the input] [stderr-file]: write $TMP/sp.json
spin() {
  jq -n --rawfile o "$1" --rawfile e "${3:-/dev/null}" --arg s "spill$RANDOM$RANDOM" --arg t "toolu_$RANDOM$RANDOM" --argjson x "${2:-{\}}" \
    '{session_id:$s,tool_use_id:$t,tool_input:{command:"make test"},tool_response:{stdout:$o,stderr:$e,interrupted:false,isImage:false}} * $x' > "$TMP/sp.json"
}
sprun() { "$HOOKS/$SP" < "$TMP/sp.json" > "$TMP/sp.out" 2> "$TMP/sp.err"; echo $?; }
splog() { echo "$SPROOT/$(jq -r .session_id "$TMP/sp.json")/$(jq -r .tool_use_id "$TMP/sp.json").log"; }
sptext() { jq -r '.hookSpecificOutput.updatedToolOutput.stdout' "$TMP/sp.out"; }
# untouched(name): exit 0 and no output, so the original result stands
untouched() { local c; c=$(sprun); [ "$c" = 0 ] && [ ! -s "$TMP/sp.out" ] && [ ! -s "$TMP/sp.err" ] && ok || bad "spill: $1 (exit $c, out '$(head -c 200 "$TMP/sp.out")', err '$(cat "$TMP/sp.err")')"; }
seq -f '%g small' 1 100 > "$TMP/small.out"
spin "$TMP/small.out"; untouched "small output untouched"
grep -q '"hook":"shunt-spill".*"result":"small"' "$XDG_STATE_HOME"/claude-hooks/*.jsonl && ok || bad "spill: small not logged"
seq -f 'generated line %06g ..........................................................................................' 1 3000 > "$TMP/gen.out"
sed -i '1501s/.*/MIDDLE-MARKER-7f3a9 in the middle/' "$TMP/gen.out"
spin "$TMP/gen.out"
c=$(sprun)
[ "$c" = 0 ] && ok || bad "spill: exit $c"
jq -e '(keys == ["hookSpecificOutput"]) and (.hookSpecificOutput | keys == ["hookEventName","updatedToolOutput"])
  and .hookSpecificOutput.hookEventName == "PostToolUse"
  and (.hookSpecificOutput.updatedToolOutput | keys == ["interrupted","isImage","stderr","stdout"])
  and .hookSpecificOutput.updatedToolOutput.interrupted == false and .hookSpecificOutput.updatedToolOutput.isImage == false
  and .hookSpecificOutput.updatedToolOutput.stderr == "" and (.hookSpecificOutput.updatedToolOutput.stdout | type == "string")' "$TMP/sp.out" >/dev/null \
  && ok || bad "spill: replacement JSON has the wrong shape: $(head -c 300 "$TMP/sp.out")"
cmp -s "$TMP/gen.out" "$(splog)" && ok || bad "spill: log differs from the output"
[ "$(stat -c %a "$(splog)")" = 600 ] && [ "$(stat -c %a "$(dirname "$(splog)")")" = 700 ] && ok || bad "spill: log or dir mode not 0600/0700"
sptext > "$TMP/sp.txt"
grep -qxF "$(head -n 1 "$TMP/gen.out")" "$TMP/sp.txt" && grep -qxF "$(tail -n 1 "$TMP/gen.out")" "$TMP/sp.txt" && ok || bad "spill: first or last line missing from the excerpt"
[ "$(jq -r '.hookSpecificOutput.updatedToolOutput.stdout | length' "$TMP/sp.out")" -le 4500 ] && ok || bad "spill: excerpt over 4500 chars"
grep -q "MIDDLE-MARKER-7f3a9" "$TMP/sp.txt" && bad "spill: the middle leaked into the excerpt" || ok
grep -q "MIDDLE-MARKER-7f3a9" "$(splog)" && ok || bad "spill: the middle is not in the log"
grep -qF "[shunt] command succeeded; its stdout was $(wc -c < "$TMP/gen.out") chars, 3000 lines, saved in full to $(splog)." "$TMP/sp.txt" && ok || bad "spill: header wrong: $(head -n 1 "$TMP/sp.txt")"
grep -q "exit 0" "$TMP/sp.txt" && bad "spill: the notice asserts an exit status" || ok
grep -qF "Do not re-run the command just to see more." "$TMP/sp.txt" && ! grep -q "bulk-read.sh --question" "$TMP/sp.txt" && ok || bad "spill: a log over the payload cap must not suggest bulk-read"
seq -f 'mid-size line %06g ......................................' 1 400 > "$TMP/mid.out"
spin "$TMP/mid.out"; sprun >/dev/null; MIDLOG=$(splog)
sptext | grep -qF "$ROOT/scripts/bulk-read.sh --question \"<what you need>\" --paths $MIDLOG" && ok || bad "spill: guidance line wrong: $(sptext | sed -n 2p)"
grep -q '^\[\.\.\. [0-9]* lines omitted \.\.\.\]$' "$TMP/sp.txt" && ok || bad "spill: omitted marker missing"
grep -q '"hook":"shunt-spill".*"result":"spilled".*"secret":false' "$XDG_STATE_HOME"/claude-hooks/*.jsonl && ok || bad "spill: spilled not logged"
head -c 20000 /dev/zero | tr '\0' 'x' > "$TMP/oneline.out"
spin "$TMP/oneline.out"; c=$(sprun)
[ "$c" = 0 ] && cmp -s "$TMP/oneline.out" "$(splog)" && sptext | grep -q '…\[cut\]' && [ "$(jq -r '.hookSpecificOutput.updatedToolOutput.stdout | length' "$TMP/sp.out")" -le 4500 ] && ok || bad "spill: 20k single line not handled"
fill 2000 > "$F/big.md"
spin "$TMP/gen.out" '{"tool_input":{"command":"cat big.md"}}'; untouched "cat big.md is a printer"
spin "$TMP/gen.out" '{"tool_input":{"command":"sed -n 1,3000p big.md"}}'; untouched "sed -n is a printer"
spin "$TMP/gen.out" '{"tool_input":{"command":"cat big.md | grep line"}}'; c=$(sprun); [ -s "$TMP/sp.out" ] && ok || bad "spill: a filtered cat should spill"
spin "$TMP/gen.out" '{"tool_input":{"command":"/x/scripts/bulk-read.sh --question q --paths f"}}'; untouched "bulk-read.sh output untouched"
spin "$TMP/gen.out" '{"tool_input":{"command":"make","run_in_background":true}}'; untouched "run_in_background untouched"
spin "$TMP/gen.out" '{"tool_response":{"interrupted":true}}'; untouched "interrupted untouched"
spin "$TMP/gen.out" '{"tool_response":{"isImage":true}}'; untouched "image untouched"
spin "$TMP/gen.out" '{"agent_type":"Explore"}'; untouched "skipped agent type untouched"
spin "$TMP/gen.out"; SHUNT_SPILL_DISABLE=1 untouched "SHUNT_SPILL_DISABLE=1 untouched"
spin "$TMP/gen.out"; SHUNT_DISABLE=1 untouched "SHUNT_DISABLE=1 untouched"
spin "$TMP/gen.out"; SHUNT_SPILL_MIN_CHARS=1000000 untouched "raised SHUNT_SPILL_MIN_CHARS untouched"
printf 'not json' > "$TMP/sp.json"; untouched "malformed stdin"
: > "$TMP/sp.json"; untouched "empty stdin"
spin "$TMP/gen.out" '{"tool_use_id":"../escaped"}'; untouched "unsafe tool_use_id"
spin "$TMP/gen.out" '{"session_id":"../../escaped"}'; untouched "unsafe session_id"
[ -z "$(find "$XDG_CACHE_HOME" "$TMP" -maxdepth 3 -name '*escaped*' 2>/dev/null)" ] && ok || bad "spill: an unsafe id wrote a file"
mkdir -p "$TMP/ro-cache"; chmod 500 "$TMP/ro-cache"
spin "$TMP/gen.out"; XDG_CACHE_HOME="$TMP/ro-cache" untouched "unwritable cache dir"
chmod 700 "$TMP/ro-cache"
spin "$TMP/gen.out"; HOME='' XDG_CACHE_HOME='' untouched "no HOME and no XDG_CACHE_HOME"
# stderr: short kept as is, long folded into the log with its tail shown
printf 'warning: short\n' > "$TMP/short.err"
spin "$TMP/gen.out" '{}' "$TMP/short.err"; sprun >/dev/null
jq -e '.hookSpecificOutput.updatedToolOutput.stderr == "warning: short\n"' "$TMP/sp.out" >/dev/null && ok || bad "spill: short stderr not kept"
seq -f 'stderr line %g ------------------------------------------' 1 300 > "$TMP/long.err"
spin "$TMP/gen.out" '{}' "$TMP/long.err"; sprun >/dev/null
jq -e '.hookSpecificOutput.updatedToolOutput.stderr == ""' "$TMP/sp.out" >/dev/null && sptext | grep -q -- '--- stderr (last lines' && sptext | grep -qF "stderr line 300 " \
  && cmp -s "$TMP/gen.out" "$(splog)" && cmp -s "$TMP/long.err" "${SPLOG_ERR:=$(splog | sed 's/\.log$/.stderr.log/')}" && ok || bad "spill: long stderr not in its own log"
unset SPLOG_ERR
# Claude Code's own saved output: use it, no copy, real tail
mkdir -p "$TMP/home/.claude/projects/p/sess/tool-results"
PERS="$TMP/home/.claude/projects/p/sess/tool-results/big-out.txt"
seq -f 'persisted line %g ..........' 1 5000 > "$PERS"
head -c 30000 "$PERS" > "$TMP/cut.out"
spin "$TMP/cut.out" "$(jq -nc --arg p "$PERS" '{tool_response:{persistedOutputPath:$p,persistedOutputSize:1}}')"; sprun >/dev/null
jq -e '.hookSpecificOutput.updatedToolOutput | has("persistedOutputPath") or has("persistedOutputSize") | not' "$TMP/sp.out" >/dev/null && ok || bad "spill: persisted fields kept in the replacement"
sptext | grep -qF "saved in full to $PERS." && sptext | grep -qxF "persisted line 5000 .........." && ok || bad "spill: persisted output not used: $(sptext | head -n 1)"
[ ! -e "$(splog)" ] && ok || bad "spill: persisted output was copied"
# diff index
{ for i in 1 2 3; do printf 'diff --git a/src/f%s.c b/src/f%s.c\nindex 1..2 100644\n' "$i" "$i"; seq -f '+added line %g in a hunk of the diff ..........' 1 400; done; } > "$TMP/diff.out"
spin "$TMP/diff.out" '{"tool_input":{"command":"git diff"}}'; sprun >/dev/null
sptext | grep -q '^\[diff index' && sptext | grep -qF "805:diff --git a/src/f3.c b/src/f3.c" && ok || bad "spill: diff index missing: $(sptext | grep -n diff)"
# secret-looking output: still spilled, flagged, no delegation suggested
{ seq -f 'pre %g ..............................' 1 10; echo "-----BEGIN OPENSSH PRIVATE KEY-----"; seq -f 'post %g ..............................' 1 2000; } > "$TMP/secret.out"
spin "$TMP/secret.out"; sprun >/dev/null
SECRET_LOG=$(splog)
sptext | grep -qF "This output looks like it contains secret material; do not delegate it." && ! sptext | grep -q "bulk-read.sh --question" && ok || bad "spill: secret output not flagged"
grep -qxF "$SECRET_LOG" "$(dirname "$SECRET_LOG")/no-delegate.list" && ok || bad "spill: secret log not listed do-not-delegate"
grep -q '"hook":"shunt-spill".*"secret":true' "$XDG_STATE_HOME"/claude-hooks/*.jsonl && ok || bad "spill: secret not logged"
# odd characters: control characters and U+FFFD survive, the result stays valid JSON
printf 'ctl \001 and \357\277\275 and tab\t\n' > "$TMP/odd.out"; cat "$TMP/gen.out" >> "$TMP/odd.out"
spin "$TMP/odd.out"; sprun >/dev/null
jq -e '.hookSpecificOutput.updatedToolOutput.stdout | test("tab")' "$TMP/sp.out" >/dev/null && cmp -s "$TMP/odd.out" "$(splog)" && ok || bad "spill: control characters broke the excerpt"
printf '{"session_id":"s","tool_use_id":"t","tool_input":{"command":"x"},"tool_response":{"stdout":"bad \377 byte %s","stderr":""}}' "$(head -c 13000 /dev/zero | tr '\0' 'y')" > "$TMP/sp.json"
c=$(sprun); [ "$c" = 0 ] && { [ ! -s "$TMP/sp.out" ] || jq -e . "$TMP/sp.out" >/dev/null; } && ok || bad "spill: invalid UTF-8 input: exit $c"
# spill logs and Claude Code's saved outputs are data: a whole Read is redirected, a range passes
GENLOG=$(grep -l "MIDDLE-MARKER-7f3a9" "$SPROOT"/*/*.log | head -n 1)
check "whole Read of a large spill log redirected" 2 "shunt:" $R "$(rd "$GENLOG")"
check "ranged Read of a spill log allowed" 0 - $R "$(rd "$GENLOG" 1490 30)"
check "whole Read of Claude Code's saved output (.claude/.../tool-results) redirected" 2 "shunt:" $R "$(rd "$PERS")"
# cleanup: once an hour, only stale real directories inside the root
mkdir -p "$SPROOT/old-sess" "$SPROOT/new-sess" "$TMP/outside-old"
touch -d '3 days ago' "$SPROOT/old-sess" "$TMP/outside-old"; touch -d '1 day ago' "$SPROOT/new-sess"
ln -s "$TMP/outside-old" "$SPROOT/link-sess"; touch -h -d '3 days ago' "$SPROOT/link-sess"
rm -f "$SPROOT/.cleanup-stamp"
spin "$TMP/gen.out"; sprun >/dev/null
[ ! -e "$SPROOT/old-sess" ] && [ -d "$SPROOT/new-sess" ] && [ -d "$TMP/outside-old" ] && [ -L "$SPROOT/link-sess" ] && ok || bad "spill cleanup removed the wrong things"
[ -s "$SECRET_LOG" ] && ok || bad "spill cleanup removed a fresh session"
mkdir -p "$SPROOT/old-sess2"; touch -d '3 days ago' "$SPROOT/old-sess2"
spin "$TMP/gen.out"; sprun >/dev/null
[ -d "$SPROOT/old-sess2" ] && ok || bad "spill cleanup ran twice within an hour"
# stderr stays separate: the log is stdout byte for byte, each tail is its own stream
seq -f 'out line %g' 1 500 > "$TMP/o500.out"
for i in 1 2 3 4 5; do printf 'ERR%s %s\n' "$i" "$(head -c 900 /dev/zero | tr '\0' 'e')"; done > "$TMP/e5.err"
spin "$TMP/o500.out" '{}' "$TMP/e5.err"; SHUNT_SPILL_MIN_CHARS=5000 sprun >/dev/null
EL=$(splog | sed 's/\.log$/.stderr.log/')
cmp -s "$TMP/o500.out" "$(splog)" && cmp -s "$TMP/e5.err" "$EL" && ok || bad "spill 500+5: logs are not the separate streams"
sptext > "$TMP/sp.txt"
grep -qx "out line 500" "$TMP/sp.txt" && ok || bad "spill 500+5: the true end of stdout is not shown"
sed -n '/^--- stderr (last lines/,$p' "$TMP/sp.txt" > "$TMP/errblock.txt"
grep -q '^ERR5 ' "$TMP/errblock.txt" && ! grep -q '^out line' "$TMP/errblock.txt" && ok || bad "spill 500+5: stderr block holds stdout lines"
grep -qF "stderr was $(wc -c < "$TMP/e5.err") chars, saved in full to $EL" "$TMP/sp.txt" && grep -qF "its stdout was $(wc -c < "$TMP/o500.out") chars, 500 lines" "$TMP/sp.txt" && ok || bad "spill 500+5: counts wrong: $(head -n 2 "$TMP/sp.txt")"
head -c 6001 /dev/zero | tr '\0' 'o' | fold -w 100 > "$TMP/o6001.out"; head -c 6000 /dev/zero | tr '\0' 'r' | fold -w 100 > "$TMP/e6000.err"
spin "$TMP/o6001.out" '{}' "$TMP/e6000.err"; c=$(sprun)
EL=$(splog | sed 's/\.log$/.stderr.log/')
[ "$c" = 0 ] && cmp -s "$TMP/o6001.out" "$(splog)" && cmp -s "$TMP/e6000.err" "$EL" && ok || bad "spill 6001+6000: logs wrong"
sptext > "$TMP/sp.txt"
grep -qxF "$(tail -n 1 "$TMP/o6001.out")" "$TMP/sp.txt" && [ "$(sed -n '/^--- stderr (last lines/,$p' "$TMP/sp.txt" | grep -v '^$' | tail -n 1)" = "$(tail -n 1 "$TMP/e6000.err")" ] && ok || bad "spill 6001+6000: tails wrong"
# the original tool_response survives; no exit status is asserted
spin "$TMP/gen.out" '{"tool_input":{"command":"diff a b"},"tool_response":{"returnCodeInterpretation":"Files differ","noOutputExpected":false}}'; sprun >/dev/null
jq -e '.hookSpecificOutput.updatedToolOutput | .returnCodeInterpretation == "Files differ" and .noOutputExpected == false and .interrupted == false and .isImage == false' "$TMP/sp.out" >/dev/null && ok || bad "spill: tool_response fields lost"
sptext | head -n 1 | grep -qF "[shunt] command succeeded (Files differ); its stdout was" && ! sptext | grep -q "exit 0" && ok || bad "spill: interpretation missing: $(sptext | head -n 1)"
spin "$TMP/gen.out" '{"tool_response":{"backgroundTaskId":"bg_123"}}'; untouched "backgroundTaskId untouched"
grep -q '"hook":"shunt-spill".*"result":"background"' "$XDG_STATE_HOME"/claude-hooks/*.jsonl && ok || bad "spill: background not logged"
printf 'hello' > "$TMP/five.out"
spin "$TMP/five.out" "$(jq -nc --arg p "$TMP/nowhere/persisted.txt" '{tool_response:{persistedOutputPath:$p,persistedOutputSize:99999}}')"; untouched "unreadable persisted path untouched"
[ ! -e "$(splog)" ] && ok || bad "spill: unreadable persisted path still wrote a log"
# a 5 MB single-line persisted file stays fast (lines are bounded before the shell reads them)
head -c 5000000 /dev/zero | tr '\0' 'z' > "$TMP/home/.claude/projects/p/sess/tool-results/one-line.txt"
head -c 30000 "$TMP/home/.claude/projects/p/sess/tool-results/one-line.txt" > "$TMP/cut1.out"
spin "$TMP/cut1.out" "$(jq -nc --arg p "$TMP/home/.claude/projects/p/sess/tool-results/one-line.txt" '{tool_response:{persistedOutputPath:$p,persistedOutputSize:1}}')"
t0=$(date +%s%N); sprun >/dev/null; t1=$(date +%s%N)
ms=$(( (t1 - t0) / 1000000 ))
[ "$ms" -lt 1000 ] && sptext | grep -q '…\[cut\]' && [ "$(jq -r '.hookSpecificOutput.updatedToolOutput.stdout | length' "$TMP/sp.out")" -le 4500 ] && ok || bad "spill: 5 MB single line took ${ms} ms or was not cut"
echo "info: spill of a 5 MB single-line persisted file ${ms} ms"
# a late secret is found by the whole-log scan
{ cat "$TMP/gen.out"; echo "token=ghp_abcdefghijklmnopqrstuvwxyz0123456789"; } > "$TMP/late.out"
spin "$TMP/late.out"; sprun >/dev/null; LATE_LOG=$(splog)
sptext | grep -qF "do not delegate it" && grep -qxF "$LATE_LOG" "$(dirname "$LATE_LOG")/no-delegate.list" && ok || bad "spill: late secret not flagged"
# modes that cannot or should not run bulk-read: spilled, but no suggestion
for m in dontAsk plan; do
  spin "$TMP/mid.out" "{\"permission_mode\":\"$m\"}"; sprun >/dev/null
  [ -s "$TMP/sp.out" ] && ! sptext | grep -q "bulk-read.sh" && ok || bad "spill: $m got a bulk-read suggestion"
done
fill 4000 49 > "$TMP/near-cap.out"
spin "$TMP/near-cap.out"; sprun >/dev/null
! sptext | grep -q "bulk-read.sh --question" && ok || bad "spill: a log near the payload cap (with numbering) still suggested bulk-read"
# KEEP_DAYS is at least 1; symlinked stamp and list are never followed
mkdir -p "$SPROOT/half-day"; touch -d '12 hours ago' "$SPROOT/half-day"; rm -f "$SPROOT/.cleanup-stamp"
spin "$TMP/gen.out"; SHUNT_SPILL_KEEP_DAYS=0 sprun >/dev/null
[ -d "$SPROOT/half-day" ] && ok || bad "spill: SHUNT_SPILL_KEEP_DAYS=0 deleted a 12-hour-old session"
: > "$TMP/stamp-target"; touch -d '2 days ago' "$TMP/stamp-target"; rm -f "$SPROOT/.cleanup-stamp"; ln -s "$TMP/stamp-target" "$SPROOT/.cleanup-stamp"
mkdir -p "$SPROOT/old-sess3"; touch -d '3 days ago' "$SPROOT/old-sess3"
spin "$TMP/gen.out"; sprun >/dev/null
[ -d "$SPROOT/old-sess3" ] && [ -n "$(find "$TMP/stamp-target" -mmin +60)" ] && ok || bad "spill: a symlinked stamp was followed"
rm -f "$SPROOT/.cleanup-stamp"
spin "$TMP/secret.out" '{"session_id":"listlink"}'; mkdir -p "$SPROOT/listlink"; : > "$TMP/list-target"
ln -s "$TMP/list-target" "$SPROOT/listlink/no-delegate.list"
untouched "symlinked no-delegate.list: untouched"
[ ! -s "$TMP/list-target" ] && ok || bad "spill: wrote through a symlinked no-delegate.list"

# the small path stays fast
spin "$TMP/small.out"
t0=$(date +%s%N); for _ in 1 2 3 4 5; do "$HOOKS/$SP" < "$TMP/sp.json" >/dev/null 2>&1; done; t1=$(date +%s%N)
SPILL_SMALL_MS=$(( (t1 - t0) / 5000000 ))
[ "$SPILL_SMALL_MS" -lt 300 ] && ok || bad "spill: small path took ${SPILL_SMALL_MS} ms per call"
echo "info: spill small path ${SPILL_SMALL_MS} ms per call"

# ── composition: validate-bash, check-loop and shunt on one input, in sequence ──
# each decides alone; a shunt redirect then repeat stays far under check-loop's
# advisory (5) and block (12); a force push stays blocked by validate-bash.
compose() { # compose <json> -> "vb cl sh" exit codes
  local c1 c2 c3
  printf '%s' "$1" | "$HOOKS/validate-bash.sh" >/dev/null 2>&1; c1=$?
  printf '%s' "$1" | "$HOOKS/check-loop.sh" >"$TMP/cl.out" 2>/dev/null; c2=$?
  printf '%s' "$1" | "$HOOKS/$B" >/dev/null 2>&1; c3=$?
  echo "$c1 $c2 $c3"
}
J=$(bc "cat big.txt" comp)
[ "$(compose "$J")" = "0 0 2" ] && ok || bad "composition: first large cat should be 0 0 2, got $(compose "$J")"
[ "$(compose "$J")" = "0 0 0" ] && ok || bad "composition: the repeat should pass all three"
[ -s "$TMP/cl.out" ] && bad "composition: check-loop advised after 2 identical commands" || ok
J=$(bc "git push --force origin main" comp)
[ "$(compose "$J")" = "2 0 0" ] && ok || bad "composition: force push should be blocked by validate-bash only"
J=$(bc "cat small.txt" comp)
[ "$(compose "$J")" = "0 0 0" ] && ok || bad "composition: small cat passes all three"

# ── bulk-read.sh ──
# A fake claude records argv, stdin and selected env, and answers per FAKE_CLAUDE_MODE.
FB="$TMP/fakebin"; mkdir -p "$FB"
cat > "$FB/claude" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FAKE_DIR/argv"
cat > "$FAKE_DIR/stdin"
printf 'SHUNT_DISABLE=%s\nSHUNT_DEPTH=%s\nCLAUDE_CODE_MAX_OUTPUT_TOKENS=%s\nPWD=%s\n' \
  "${SHUNT_DISABLE:-}" "${SHUNT_DEPTH:-}" "${CLAUDE_CODE_MAX_OUTPUT_TOKENS:-unset}" "$PWD" > "$FAKE_DIR/env"
env > "$FAKE_DIR/fullenv"
res() { jq -nc --arg r "$1" --argjson e "${2:-false}" '{type:"result",subtype:"success",is_error:$e,result:$r,duration_ms:900,num_turns:1,total_cost_usd:0.0012,
  usage:{input_tokens:7,output_tokens:56,cache_creation_input_tokens:1234,cache_read_input_tokens:10},modelUsage:{"claude-haiku-test":{}}}'; }
case "${FAKE_CLAUDE_MODE:-ok}" in
  ok) res "- answer at big.txt:42" ;;
  long) res "$(head -c 20000 /dev/zero | tr '\0' 'z')" ;;
  sleep) sleep 10 ;;
  crash) echo "segfault in node" >&2; exit 3 ;;
  auth) res "Invalid API key · Please run /login" true; exit 1 ;;
  rate) res "Claude AI usage limit reached" true; exit 1 ;;
  model) res "There's an issue with the selected model (nonesuch). It may not exist or you may not have access to it." true; exit 1 ;;
  maxturns) jq -nc '{type:"result",subtype:"error_max_turns",is_error:true}' ;;
  budget) jq -nc '{type:"result",subtype:"error_max_budget_usd",is_error:true,total_cost_usd:0.07,errors:["Reached maximum budget ($0.05)"]}'; exit 1 ;;
  outlimit) jq -nc '{type:"result",subtype:"success",is_error:true,api_error:"max_output_tokens",result:"API Error: response exceeded the 1500 output token maximum."}'; exit 1 ;;
  garbage) echo "<html>oops</html>" ;;
  notloggedin) echo "Not logged in · Please run /login"; exit 1 ;;
  empty) res "  " ;;
  nested) "$BULK" --question q --paths "$F/small.txt" 2> "$FAKE_DIR/nested-err"; echo "$?" > "$FAKE_DIR/nested-rc"; res "x" ;;
esac
FAKE
chmod +x "$FB/claude"
export FAKE_DIR="$TMP/fake" BULK F; mkdir -p "$FAKE_DIR" "$TMP/tmpd"
# br <name> <want_exit> <stderr_pattern|-> <stdout_pattern|-> <args...>: run bulk-read with the fake claude
br() {
  local name="$1" want="$2" ep="$3" op="$4" code; shift 4
  rm -f "$FAKE_DIR"/*
  (cd "${BR_CWD:-$F}" && TMPDIR="$TMP/tmpd" PATH="$FB:$PATH" "$BULK" "$@") >"$TMP/out" 2>"$TMP/err"; code=$?
  if [ "$code" -eq "$want" ] && { [ "$ep" = - ] || grep -qF -- "$ep" "$TMP/err"; } && { [ "$op" = - ] || grep -qF -- "$op" "$TMP/out"; }; then ok; else
    bad "bulk-read: $name (exit=$code want=$want; stderr='$(cat "$TMP/err")' stdout='$(head -c 300 "$TMP/out")')"; fi
}
Q="Where is the retry budget set?"
FB_MSG="Fall back: Read the file with offset/limit ranges, or repeat the full Read"
br "success" 0 "model=claude-haiku-test input_tokens=7 output_tokens=56 cache_read=10 cache_write=1234 turns=1 cost_usd=0.0012" "answer at big.txt:42" --question "$Q" --paths big.txt small.txt
argv=$(cat "$FAKE_DIR/argv")
grep -qxF -- "-p" <<<"$argv" && ok || bad "bulk-read: not headless (-p)"
grep -A1 -xF -- "--model" <<<"$argv" | grep -qx haiku && ok || bad "bulk-read: default model is not haiku"
grep -A1 -xF -- "--tools" <<<"$argv" | sed -n 2p | grep -qx '' && ok || bad "bulk-read: tools not disabled (--tools \"\")"
grep -A1 -xF -- "--max-budget-usd" <<<"$argv" | grep -qx 0.15 && ok || bad "bulk-read: default budget ceiling not 0.15"
for fl in --output-format --no-session-persistence --safe-mode --strict-mcp-config --disable-slash-commands --system-prompt; do
  grep -qxF -- "$fl" <<<"$argv" && ok || bad "bulk-read: missing $fl"
done
grep -qF "$Q" <<<"$argv" && bad "bulk-read: question on argv" || ok
grep -qE '^ +42.42 +$' "$FAKE_DIR/argv" && bad "bulk-read: payload on argv" || ok
grep -qF "$Q" "$FAKE_DIR/stdin" && ok || bad "bulk-read: question not on stdin"
grep -qP '^ +42\t42 +$' "$FAKE_DIR/stdin" && ok || bad "bulk-read: content not line-numbered on stdin"
grep -qF "untrusted" <<<"$argv" && grep -qF "not found in the provided files" <<<"$argv" && ok || bad "bulk-read: system prompt"
D=$(grep -oE '<<<BEGIN FILE-[0-9a-f]+ path=big.txt' "$FAKE_DIR/stdin" | sed 's/<<<BEGIN //; s/ path=.*//')
[ -n "$D" ] && grep -qxF "<<<END $D>>>" "$FAKE_DIR/stdin" && ok || bad "bulk-read: delimiter wrapper"
grep -qx "SHUNT_DISABLE=1" "$FAKE_DIR/env" && grep -qx "SHUNT_DEPTH=1" "$FAKE_DIR/env" && ok || bad "bulk-read: child env lacks SHUNT_DISABLE=1/SHUNT_DEPTH=1"
grep -qx "CLAUDE_CODE_MAX_OUTPUT_TOKENS=unset" "$FAKE_DIR/env" && ok || bad "bulk-read: CLAUDE_CODE_MAX_OUTPUT_TOKENS reached the child"
grep -qx "PWD=$XDG_CACHE_HOME/shunt-bulk-read" "$FAKE_DIR/env" && ok || bad "bulk-read: child not run in the stable empty dir"
grep -q '"hook":"bulk-read".*"result":"ok".*"files":2.*"cost_usd":0.0012.*"input_tokens":7.*"output_tokens":56.*"cache_creation_input_tokens":1234' "$XDG_STATE_HOME"/claude-hooks/*.jsonl && ok || bad "bulk-read: success not logged"
CLAUDE_CODE_MAX_OUTPUT_TOKENS=99 SHUNT_MODEL=sonnet SHUNT_MAX_BUDGET_USD=0.2 br "model and budget configurable" 0 - - --question "$Q" --paths small.txt
grep -A1 -xF -- "--model" "$FAKE_DIR/argv" | grep -qx sonnet && grep -A1 -xF -- "--max-budget-usd" "$FAKE_DIR/argv" | grep -qx 0.2 && ok || bad "bulk-read: SHUNT_MODEL/SHUNT_MAX_BUDGET_USD ignored"
grep -qx "CLAUDE_CODE_MAX_OUTPUT_TOKENS=unset" "$FAKE_DIR/env" && ok || bad "bulk-read: an inherited CLAUDE_CODE_MAX_OUTPUT_TOKENS reached the child"
SHUNT_MAX_BUDGET_USD='1;rm' br "malformed budget falls back" 0 - - --question "$Q" --paths small.txt
grep -A1 -xF -- "--max-budget-usd" "$FAKE_DIR/argv" | grep -qx 0.15 && ok || bad "bulk-read: malformed budget passed through"
FAKE_CLAUDE_MODE=nested br "nested call inside the child" 0 - - --question "$Q" --paths small.txt
[ "$(cat "$FAKE_DIR/nested-rc" 2>/dev/null)" = 1 ] && grep -qF "inside a bulk-read child" "$FAKE_DIR/nested-err" && ok || bad "bulk-read: depth guard did not refuse a nested call"
FAKE_CLAUDE_MODE=long br "long answer truncated" 0 - "answer truncated at 12000 of 20000 bytes" --question "$Q" --paths small.txt
[ "$(head -n 1 "$TMP/out" | wc -c)" -le 12001 ] && ok || bad "bulk-read: truncation exceeded the limit"
SHUNT_TIMEOUT_SECONDS=1 FAKE_CLAUDE_MODE=sleep br "timeout" 1 "timed out after 1s. $FB_MSG" - --question "$Q" --paths small.txt
FAKE_CLAUDE_MODE=crash br "non-zero exit" 1 "claude exited 3: segfault in node. $FB_MSG" - --question "$Q" --paths small.txt
FAKE_CLAUDE_MODE=auth br "auth failure" 1 "could not authenticate: Invalid API key" - --question "$Q" --paths small.txt
FAKE_CLAUDE_MODE=rate br "usage limit" 1 "rate or usage limit: Claude AI usage limit reached. $FB_MSG" - --question "$Q" --paths small.txt
FAKE_CLAUDE_MODE=model br "model unavailable" 1 "model 'haiku' is unavailable" - --question "$Q" --paths small.txt
FAKE_CLAUDE_MODE=maxturns br "error subtype" 1 "claude reported an error (exit 0): error_max_turns" - --question "$Q" --paths small.txt
FAKE_CLAUDE_MODE=budget br "budget exceeded" 1 "cost more than SHUNT_MAX_BUDGET_USD=0.15 (cost 0.07) and the answer was discarded" - --question "$Q" --paths small.txt
FAKE_CLAUDE_MODE=outlimit br "output token limit" 1 "hit an output token limit" - --question "$Q" --paths small.txt
FAKE_CLAUDE_MODE=garbage br "non-JSON output" 1 "non-JSON output: <html>oops</html>. $FB_MSG" - --question "$Q" --paths small.txt
FAKE_CLAUDE_MODE=empty br "empty answer" 1 "empty answer. $FB_MSG" - --question "$Q" --paths small.txt
grep -q '"hook":"bulk-read".*"result":"timeout"' "$XDG_STATE_HOME"/claude-hooks/*.jsonl && ok || bad "bulk-read: failure not logged"
# validation: nothing reaches claude
SHUNT_CLAUDE_BIN="$FB/claude" br "SHUNT_CLAUDE_BIN used" 0 - - --question "$Q" --paths small.txt
# refusals: each must end with the fallback line and never start claude
brx() { # brx <name> <stderr_pattern> <args...>
  local name="$1" pat="$2"; shift 2
  br "$name" 1 "$pat" - "$@"
  grep -qF "$FB_MSG" "$TMP/err" && ok || bad "bulk-read: $name: no fallback line"
  [ -e "$FAKE_DIR/argv" ] && bad "bulk-read: $name: claude ran" || ok
}
brx "missing question" "missing --question" --paths small.txt
brx "missing paths" "missing --paths" --question "$Q"
brx "nonexistent path" "nope.txt does not exist" --question "$Q" --paths nope.txt
brx "directory" "not a regular file" --question "$Q" --paths dir
brx "sensitive path" "not delegated; read it directly if you are permitted to" --question "$Q" --paths .env
brx "symlink to sensitive file" "not delegated" --question "$Q" --paths innocent.txt
brx "sensitive directory" "not delegated" --question "$Q" --paths secrets/db.yaml
SHUNT_EXCLUDE="*.log" brx "excluded path" "not delegated" --question "$Q" --paths vendor.log
brx "binary" "binary or non-text" --question "$Q" --paths blob.bin
SHUNT_MAX_PAYLOAD_BYTES=5000 brx "oversized request" "split" --question "$Q" --paths big.txt
SHUNT_MAX_FILES=2 brx "too many files" "over SHUNT_MAX_FILES=2" --question "$Q" --paths small.txt big.txt t7992.txt
SHUNT_DEPTH=1 brx "depth guard" "refusing to run inside a bulk-read child" --question "$Q" --paths small.txt
SHUNT_CLAUDE_BIN="$TMP/no-such-claude" brx "claude binary missing" "was not found; set SHUNT_CLAUDE_BIN" --question "$Q" --paths small.txt
# the refusal list, table-driven: each spelling alone and as the second path
SENS=(.claude/.credentials.json .git-credentials .pgpass kubeconfig terraform.tfstate secrets.yaml Secrets/db.yaml
  .docker/config.json .htpasswd secrets.nix private.key.bak .env-prod passwords.txt keys.txt .env server.pem
  id_ed25519 app.sops.yaml .netrc .npmrc .pypirc api_token.txt .ssh/config .aws/credentials .kube/config
  .gnupg/pubring.kbx SECRET/notes.md prod.tfvars vault.gpg cert.p12 store.jks client.ovpn backup.age
  prod.env docker.env app.env key.txt age-key.txt .config/age/key.txt var/lib/sops-nix/key.txt
  .secrets/db.yaml my-secrets/db.yaml credentials/aws.json tokens/gh.json wg0.conf etc/wireguard/wg0.conf
  rclone.conf .config/rclone/rclone.conf .my.cnf auth.json .codex/auth.json k3s.yaml admin.conf
  kube-config.yaml .dev.vars AuthKey_ABC.p8 cert.der private_key ssh_host_ed25519_key etc/rancher/k3s/k3s.yaml
  .bash_history .zsh_history .histfile .local/share/fish/fish_history talosconfig .config/talos/config
  .msmtprc .mbsyncrc .authinfo .authinfo.gpg .envrc .claude.json)
for s in "${SENS[@]}"; do
  mkdir -p "$F/sens/$(dirname "$s")"; seq 1 10 > "$F/sens/$s"
  brx "refuse $s" "not delegated" --question "$Q" --paths "sens/$s"
  brx "refuse $s as second path" "sens/$s is a sensitive" --question "$Q" --paths small.txt "sens/$s"
done
# structural guards, independent of names
printf 'line %s\n' 1 2 3 > "$F/plain-a.txt"; chmod 600 "$F/plain-a.txt"
brx "private mode refused (umask 022)" "is private (mode 600" --question "$Q" --paths plain-a.txt
chmod 400 "$F/plain-a.txt"
brx "0400 refused" "is private (mode 400" --question "$Q" --paths plain-a.txt
chmod 644 "$F/plain-a.txt"
br "same content at 0644 sent" 0 - - --question "$Q" --paths plain-a.txt
chmod 640 "$F/plain-a.txt"
br "group-readable 0640 sent" 0 - - --question "$Q" --paths plain-a.txt
chmod 600 "$F/plain-a.txt"
umask 077; br "private mode not a signal under umask 077: sent" 0 - - --question "$Q" --paths plain-a.txt; umask 022
chmod 644 "$F/plain-a.txt"
i=0
for m in "-----BEGIN RSA PRIVATE KEY-----" "-----BEGIN PRIVATE KEY-----" "-----BEGIN EC PRIVATE KEY-----" \
  "-----BEGIN OPENSSH PRIVATE KEY-----" "-----BEGIN ENCRYPTED PRIVATE KEY-----" "-----BEGIN PGP PRIVATE KEY BLOCK-----" \
  "AGE-SECRET-KEY-1QQQQQQQQQQQQQQQQ" $'data: ENC[AES256_GCM,data:x,iv:y]\nsops:\n  version: 3' \
  $'{"a": "ENC[AES256_GCM,data:x]", "sops": {}}' $'sops:\n  age: []\nkey: ENC[x]'; do
  i=$((i + 1)); { echo "intro"; printf '%s\n' "$m"; echo "outro"; } > "$F/notes-$i.md"
  brx "marker $i refused under an innocent name" "looks like secret material by content" --question "$Q" --paths "notes-$i.md"
done
printf 'the word sops: appears, and so does the word PRIVATE KEY, but no marker\n' > "$F/prose.md"
br "prose mentioning sops: without ENC[ is sent" 0 - - --question "$Q" --paths prose.md
BR_CWD="$TMP/globcwd" SHUNT_EXCLUDE='*.log' brx "SHUNT_EXCLUDE not glob-expanded against cwd" "not delegated" --question "$Q" --paths g/vendor.log
# third review probe: umask 077, every file 0600, so only names and content guard
P="$TMP/probe"; mkdir -p "$P/.local/share/fish" "$P/.config/talos" "$P/clusters/homelab"
B64KEY='LS0tLS1CRUdJTiBFQyBQUklWQVRFIEtFWS0tLS0tCk1IY0NBUUVFSUJhc2U2NGtleQo='
(
  umask 077
  seq 1 400 > "$P/.bash_history"
  seq 1 400 > "$P/.local/share/fish/fish_history"
  seq 1 400 > "$P/.config/talos/config"
  { echo "machine:"; echo "  ca:"; echo "    key: $B64KEY"; seq 1 400 | sed 's/^/  # /'; } > "$P/clusters/homelab/controlplane.yaml"
  { echo "apiVersion: v1"; echo "kind: Config"; echo "users:"; echo "- user:"; echo "    client-key-data: $B64KEY"; seq 1 400 | sed 's/^/# /'; } > "$P/homelab.yaml"
)
umask 077
for f in .bash_history .local/share/fish/fish_history .config/talos/config clusters/homelab/controlplane.yaml homelab.yaml; do
  [ "$(stat -c %a "$P/$f")" = 600 ] && ok || bad "probe fixture $f is not 0600"
  check "umask 077: Read of $f allowed" 0 - $R "$(rd "$P/$f")"
  [ -s "$TMP/err" ] && bad "umask 077: Read of $f printed '$(cat "$TMP/err")'" || ok
  BR_CWD="$P" brx "umask 077: bulk-read refuses $f" "not delegated" --question "$Q" --paths "$f"
done
umask 022
for r in sensitive secret; do
  grep -q "\"hook\":\"shunt-read\".*\"result\":\"$r\"" "$XDG_STATE_HOME"/claude-hooks/*.jsonl && ok || bad "Read hook did not log $r"
done
{ echo "data:"; echo "  tls.key: $B64KEY"; seq 1 400 | sed 's/^/# /'; } > "$F/tls-bundle.yaml"; chmod 644 "$F/tls-bundle.yaml"
check "umask 022: base64 key at 0644 allowed by the Read hook" 0 - $R "$(rd "$F/tls-bundle.yaml")"
brx "umask 022: base64 key at 0644 refused" "looks like secret material by content" --question "$Q" --paths tls-bundle.yaml
printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: db\nstringData:\n  password: hunter2\n' > "$F/db-manifest.yaml"
brx "plaintext Kubernetes Secret refused" "looks like secret material by content" --question "$Q" --paths db-manifest.yaml
printf '{"apiVersion": "v1", "kind": "Secret", "data": {}}\n' > "$F/db-manifest.json"
brx "JSON Kubernetes Secret refused" "looks like secret material by content" --question "$Q" --paths db-manifest.json
printf 'kind: Deployment\n# mentions a Secret by name only\n' > "$F/deploy.yaml"
br "manifest mentioning a Secret is sent" 0 - - --question "$Q" --paths deploy.yaml
# fourth review: more content markers, under umask 077 at 0600 (mode check off)
umask 077
i=0
for body in $'apiVersion: v1\nkind: List\nitems:\n  - apiVersion: v1\n    kind: Secret\n    data: {}' \
  $'items:\n- kind: Secret\n  data: {}' $'apiVersion: v1\nkind: "Secret"\ndata: {}' $'kind: \'Secret\'' \
  '{"kind" : "Secret", "data": {}}' $'{\n  "kind":"Secret"\n}' \
  $'[Interface]\nPrivateKey = aGVsbG8=\nAddress = 10.0.0.2/32' $'[Peer]\nPresharedKey = aGVsbG8=' \
  'GITHUB_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz0123456789' 'pat: github_pat_11ABCDEF_xyz' 'ANTHROPIC_API_KEY=sk-ant-api03-xyz' \
  'access-tokens = github.com=ghp_x' $'apiVersion: v1\nkind: Config\nusers:\n- name: admin\n  user:\n    token: abc.def.ghi'; do
  i=$((i + 1)); { echo "# fixture"; printf '%s\n' "$body"; seq 1 400 | sed 's/^/# /'; } > "$F/m4-$i.txt"
  [ "$(stat -c %a "$F/m4-$i.txt")" = 600 ] && ok || bad "m4-$i fixture not 0600"
  check "umask 077: Read of marker file m4-$i allowed" 0 - $R "$(rd "$F/m4-$i.txt")"
  brx "umask 077: marker m4-$i refused" "looks like secret material by content" --question "$Q" --paths "m4-$i.txt"
done
printf 'kind: Deployment\nspec:\n  envFrom:\n  - secretRef: {name: db}  # a kind: Secret named db\n# this mounts a kind: Secret\n' > "$F/deploy2.yaml"
br "umask 077: Deployment mentioning kind: Secret mid-line is sent" 0 - - --question "$Q" --paths deploy2.yaml
printf 'apiVersion: v1\nkind: Config\nusers:\n- name: admin\n  user:\n    exec: {command: kubelogin}\n' > "$F/execconfig.yaml"
br "umask 077: kubeconfig without a token is sent" 0 - - --question "$Q" --paths execconfig.yaml
printf 'auth:\n  token: abc\n' > "$F/notconfig.yaml"
br "umask 077: token line without kind: Config is sent" 0 - - --question "$Q" --paths notconfig.yaml
umask 022
fill 2000 > "$F/locked.txt"; chmod 000 "$F/locked.txt"
check "unreadable file allowed silently" 0 - $R "$(rd "$F/locked.txt")"
[ -s "$TMP/err" ] && bad "unreadable file printed '$(cat "$TMP/err")'" || ok
chmod 644 "$F/locked.txt"
grep -q '"hook":"bulk-read".*"result":"private"' "$XDG_STATE_HOME"/claude-hooks/*.jsonl && ok || bad "private refusal not logged"
grep -q '"hook":"bulk-read".*"result":"secret"' "$XDG_STATE_HOME"/claude-hooks/*.jsonl && ok || bad "secret refusal not logged"
grep -q '"hook":"bulk-read".*"result":"sensitive"' "$XDG_STATE_HOME"/claude-hooks/*.jsonl && ok || bad "sensitive refusal not logged"
# ── v2: bulk-read plumbing ──
# spill logs through bulk-read: listed secret logs refused, content check applies, clean logs sent
{ fill 2000; echo "token=ghp_abcdefghijklmnopqrstuvwxyz0123456789"; } > "$F/late-notes.txt"
brx "a secret past 64 KiB is found (whole-file scan)" "looks like secret material by content" --question "$Q" --paths late-notes.txt
brx "spill log with a late secret refused" "saved command output that looked like secret material" --question "$Q" --paths "$LATE_LOG"
brx "spill log listed do-not-delegate is refused" "saved command output that looked like secret material" --question "$Q" --paths "$SECRET_LOG"
mkdir -p "$SPROOT/manual"; { echo "-----BEGIN RSA PRIVATE KEY-----"; fill 50; } > "$SPROOT/manual/toolu_m.log"; chmod 644 "$SPROOT/manual/toolu_m.log"
brx "spill log with key material refused by the content check" "looks like secret material by content" --question "$Q" --paths "$SPROOT/manual/toolu_m.log"
br "clean spill log is delegated" 0 - "answer at big.txt:42" --question "$Q" --paths "$MIDLOG"
HOME='' XDG_CACHE_HOME='' br "no HOME and no XDG_CACHE_HOME: clear refusal" 1 "neither XDG_CACHE_HOME nor HOME is set" - --question "$Q" --paths small.txt
FAKE_CLAUDE_MODE=notloggedin br "'Not logged in' on stdout reaches the message" 1 "claude exited 1: Not logged in" - --question "$Q" --paths small.txt
NOJQ_PATH=""
IFS=: read -ra pdirs <<< "$PATH"
for d in "${pdirs[@]}"; do [ -x "$d/jq" ] || NOJQ_PATH="$NOJQ_PATH:$d"; done
rm -f "$FAKE_DIR"/*
(cd "$F" && PATH="$FB$NOJQ_PATH" "$BULK" --question "$Q" --paths small.txt) >"$TMP/out" 2>"$TMP/err"; code=$?
[ "$code" -eq 1 ] && grep -q "jq was not found" "$TMP/err" && ok || bad "bulk-read without jq: exit=$code stderr='$(cat "$TMP/err")'"
[ -e "$FAKE_DIR/argv" ] && bad "bulk-read without jq: claude ran" || ok
HERDR_PANE_ID=w1 HERDR_WORKSPACE_ID=ws HERDR_CLAUDE_WORKER_SETTINGS=/x CLAUDE_CODE_SESSION_ID=parent CLAUDE_CODE_CHILD_SESSION=1 \
  CLAUDE_CODE_MESSAGING_SOCKET=/s CLAUDE_CODE_MESSAGING_TOKEN=tok CLAUDE_EFFORT=max \
  br "identity variables set in the parent" 0 - - --question "$Q" --paths small.txt
for v in HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_CLAUDE_WORKER_SETTINGS CLAUDE_CODE_SESSION_ID CLAUDE_CODE_CHILD_SESSION \
  CLAUDE_CODE_MESSAGING_SOCKET CLAUDE_CODE_MESSAGING_TOKEN CLAUDE_EFFORT; do
  grep -q "^$v=" "$FAKE_DIR/fullenv" && bad "bulk-read: $v reached the child" || ok
done
grep -qx "SHUNT_DISABLE=1" "$FAKE_DIR/env" && ok || bad "bulk-read: SHUNT_DISABLE lost with the scrub"
br "second call" 0 - - --question "$Q" --paths small.txt
grep -qx "PWD=$XDG_CACHE_HOME/shunt-bulk-read" "$FAKE_DIR/env" && ok || bad "bulk-read: second call used another cwd"
[ -z "$(ls -A "$XDG_CACHE_HOME/shunt-bulk-read")" ] && ok || bad "bulk-read: the child cwd is not empty"
grep -q '"hook":"bulk-read".*"result":"ok".*"event":"delegated".*"bytes_sent":[1-9][0-9]*.*"exit_status":0.*"claude_exit":0.*"cost_usd":0.0012' "$XDG_STATE_HOME"/claude-hooks/*.jsonl && ok || bad "bulk-read: delegated event not logged"
grep -q '"hook":"bulk-read".*"result":"timeout".*"event":"delegated".*"exit_status":1' "$XDG_STATE_HOME"/claude-hooks/*.jsonl && ok || bad "bulk-read: failed delegation not logged with exit status"
fill 4100 > "$F/over-cap.txt"
brx "default payload cap is 200000 bytes" "over SHUNT_MAX_PAYLOAD_BYTES=200000" --question "$Q" --paths over-cap.txt
grep -q '"hook":"bulk-read".*"result":"invalid".*"event":"refused".*"bytes_sent":0' "$XDG_STATE_HOME"/claude-hooks/*.jsonl && ok || bad "bulk-read: refusal not logged as refused"
grep -q '"hook":"bulk-read".*"result":"invalid"' "$XDG_STATE_HOME"/claude-hooks/*.jsonl && ok || bad "bulk-read: validation failure not logged"
[ -n "$(ls -A "$TMP/tmpd")" ] && bad "bulk-read: temp dir left behind" || ok

echo "---"
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
