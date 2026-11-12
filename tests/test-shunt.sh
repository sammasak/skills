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
export XDG_RUNTIME_DIR="$TMP/run" XDG_STATE_HOME="$TMP/state"
mkdir -p "$XDG_RUNTIME_DIR" "$XDG_STATE_HOME"
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

seq 1 100 > "$F/small.txt"
seq 1 350 > "$F/l350.txt"
seq 1 351 > "$F/l351.txt"
seq 1 2000 > "$F/big.txt"
head -c 70000 /dev/zero | tr '\0' 'a' > "$F/minified.js"
: > "$F/empty.txt"
seq 1 2000 > "$F/pic.png"
{ seq 1 2000; printf 'x\0y\n'; } > "$F/blob.bin"
mkdir -p "$F/secrets" "$F/home/.ssh" "$F/dir"
seq 1 2000 > "$F/.env"; seq 1 2000 > "$F/.env.local"; seq 1 2000 > "$F/server.pem"
seq 1 2000 > "$F/api_token.txt"; seq 1 2000 > "$F/secrets/db.yaml"; seq 1 2000 > "$F/home/.ssh/config"
seq 1 2000 > "$F/app.sops.yaml"; seq 1 2000 > "$F/credentials.json"
ln -s "$F/.env" "$F/innocent.txt"
seq 1 2000 > "$F/with space.txt"
seq 1 2000 > "$F/vendor.log"

R=shunt-check-read.sh
B=shunt-check-bash-read.sh

# ── Read hook: size ──
check "small file allowed" 0 - $R "$(rd "$F/small.txt")"
check "350 lines allowed" 0 - $R "$(rd "$F/l350.txt")"
check "351 lines redirected" 2 "is 351 lines" $R "$(rd "$F/l351.txt")"
check "empty file allowed" 0 - $R "$(rd "$F/empty.txt")"
check "byte-large one-line file redirected" 2 "70000 bytes" $R "$(rd "$F/minified.js")"
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
mkdir -p "$TMP/globcwd/g"; : > "$TMP/globcwd/unrelated.log"; seq 1 2000 > "$TMP/globcwd/g/vendor.log"
(cd "$TMP/globcwd" && SHUNT_EXCLUDE='*.log' check "SHUNT_EXCLUDE not glob-expanded against cwd (Read)" 0 - $R "$(rd "$TMP/globcwd/g/vendor.log")")
[ -s "$TMP/err" ] && bad "SHUNT_EXCLUDE glob: Read hook redirected" || ok
# file guards in the hooks: a large file bulk-read.sh would refuse is read normally, never redirected
seq 1 2000 > "$F/private-notes.txt"; chmod 600 "$F/private-notes.txt"
check "private-mode large file allowed (umask 022)" 0 - $R "$(rd "$F/private-notes.txt")"
seq 1 2000 > "$F/open-notes.txt"; chmod 644 "$F/open-notes.txt"
check "same content at 0644 redirected" 2 "shunt:" $R "$(rd "$F/open-notes.txt")"
(umask 077; check "private-mode guard stands down under umask 077" 2 "shunt:" $R "$(rd "$F/private-notes.txt")")
{ echo "-----BEGIN OPENSSH PRIVATE KEY-----"; seq 1 2000; } > "$F/notes-a.txt"
check "key marker in a large file allowed (Read)" 0 - $R "$(rd "$F/notes-a.txt")"
check "key marker in a large file allowed (Bash)" 0 - $B "$(bc "cat notes-a.txt")"
check "private-mode file allowed (Bash)" 0 - $B "$(bc "cat private-notes.txt")"
# ── Read hook: switches ──
SHUNT_DISABLE=1 check "SHUNT_DISABLE allows" 0 - $R "$(rd "$F/big.txt")"
SHUNT_MIN_LINES=abc check "non-numeric threshold falls back to 350 (351 redirected)" 2 "threshold of 350" $R "$(rd "$F/l351.txt")"
SHUNT_MIN_LINES=abc check "non-numeric threshold falls back to 350 (350 allowed)" 0 - $R "$(rd "$F/l350.txt")"
SHUNT_MIN_LINES=5000 check "raised threshold allows" 0 - $R "$(rd "$F/big.txt")"
# ── Read hook: message and repeat ──
check "message names the script" 2 "$ROOT/scripts/bulk-read.sh --question \"<what you need to know>\" --paths $F/big.txt" $R "$(rd "$F/big.txt" null null rep)"
check "message offers a ranged Read" 2 "offset/limit of at most 350 lines" $R "$(rd "$F/big.txt" null null rep2)"
check "identical repeat allowed" 0 - $R "$(rd "$F/big.txt" null null rep)"
check "third repeat still allowed" 0 - $R "$(rd "$F/big.txt" null null rep)"
check "same file, other session: redirected" 2 "shunt:" $R "$(rd "$F/big.txt" null null rep3)"
check "same session, different range: redirected" 2 "shunt:" $R "$(rd "$F/big.txt" 1 1000 rep)"
check "quoted path with space in message" 2 'with\ space.txt' $R "$(rd "$F/with space.txt")"
grep -q '"hook":"shunt-read".*"result":"bypass"' "$XDG_STATE_HOME"/claude-hooks/*.jsonl && ok || bad "bypass not logged"
grep -q '"hook":"shunt-read".*"result":"redirect".*"lines":2000' "$XDG_STATE_HOME"/claude-hooks/*.jsonl && ok || bad "redirect not logged with line count"
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
check "head -n 350 allowed" 0 - $B "$(bc "head -n 350 big.txt")"
check "head -n 5000 redirected" 2 "about 2000 lines" $B "$(bc "head -n 5000 big.txt")"
check "head -n 351 redirected" 2 "about 351 lines" $B "$(bc "head -n 351 big.txt")"
check "tail -n +1700 allowed" 0 - $B "$(bc "tail -n +1700 big.txt")"
check "tail -n +2 redirected" 2 "about 1999 lines" $B "$(bc "tail -n +2 big.txt")"
check "head -n -10 redirected" 2 "about 1990 lines" $B "$(bc "head -n -10 big.txt")"
check "head -c 1000 allowed" 0 - $B "$(bc "head -c 1000 minified.js")"
check "cat minified redirected" 2 "70000 bytes" $B "$(bc "cat minified.js")"
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
check "largest offender named" 2 "of $F/big.txt" $B "$(bc "cat l351.txt big.txt small.txt")"
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
check "message offers a ranged Read" 2 "Read tool with offset/limit of at most 350 lines" $B "$(bc "cat big.txt")"
SHUNT_DISABLE=1 check "SHUNT_DISABLE allows" 0 - $B "$(bc "cat big.txt")"
check "missing session id allowed" 0 - $B "$(jq -nc --arg d "$F" '{cwd:$d,tool_input:{command:"cat big.txt"}}')"
check "bash: first attempt redirected" 2 "shunt:" $B "$(bc "cat big.txt" brep)"
check "bash: identical repeat allowed" 0 - $B "$(bc "cat big.txt" brep)"
check "bash: other session redirected" 2 "shunt:" $B "$(bc "cat big.txt" brep2)"
check "bash: same command, other cwd is another key" 2 "shunt:" $B "$(bc "cat $F/big.txt" brep "$F/dir")"
grep -q '"hook":"shunt-bash".*"result":"bypass"' "$XDG_STATE_HOME"/claude-hooks/*.jsonl && ok || bad "bash bypass not logged"

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
grep -A1 -xF -- "--max-budget-usd" <<<"$argv" | grep -qx 0.05 && ok || bad "bulk-read: default budget ceiling not 0.05"
for fl in --output-format --no-session-persistence --safe-mode --strict-mcp-config --disable-slash-commands --system-prompt; do
  grep -qxF -- "$fl" <<<"$argv" && ok || bad "bulk-read: missing $fl"
done
grep -qF "$Q" <<<"$argv" && bad "bulk-read: question on argv" || ok
grep -qE '^ +42.42$' "$FAKE_DIR/argv" && bad "bulk-read: payload on argv" || ok
grep -qF "$Q" "$FAKE_DIR/stdin" && ok || bad "bulk-read: question not on stdin"
grep -qP '^ +42\t42$' "$FAKE_DIR/stdin" && ok || bad "bulk-read: content not line-numbered on stdin"
grep -qF "untrusted" <<<"$argv" && grep -qF "not found in the provided files" <<<"$argv" && ok || bad "bulk-read: system prompt"
D=$(grep -oE '<<<BEGIN FILE-[0-9a-f]+ path=big.txt' "$FAKE_DIR/stdin" | sed 's/<<<BEGIN //; s/ path=.*//')
[ -n "$D" ] && grep -qxF "<<<END $D>>>" "$FAKE_DIR/stdin" && ok || bad "bulk-read: delimiter wrapper"
grep -qx "SHUNT_DISABLE=1" "$FAKE_DIR/env" && grep -qx "SHUNT_DEPTH=1" "$FAKE_DIR/env" && ok || bad "bulk-read: child env lacks SHUNT_DISABLE=1/SHUNT_DEPTH=1"
grep -qx "CLAUDE_CODE_MAX_OUTPUT_TOKENS=unset" "$FAKE_DIR/env" && ok || bad "bulk-read: CLAUDE_CODE_MAX_OUTPUT_TOKENS reached the child"
grep -q "^PWD=$TMP/tmpd/bulk-read\." "$FAKE_DIR/env" && ok || bad "bulk-read: child not run in the private temp dir"
grep -q '"hook":"bulk-read".*"result":"ok".*"files":2.*"cost_usd":0.0012.*"input_tokens":7.*"output_tokens":56.*"cache_creation_input_tokens":1234' "$XDG_STATE_HOME"/claude-hooks/*.jsonl && ok || bad "bulk-read: success not logged"
CLAUDE_CODE_MAX_OUTPUT_TOKENS=99 SHUNT_MODEL=sonnet SHUNT_MAX_BUDGET_USD=0.2 br "model and budget configurable" 0 - - --question "$Q" --paths small.txt
grep -A1 -xF -- "--model" "$FAKE_DIR/argv" | grep -qx sonnet && grep -A1 -xF -- "--max-budget-usd" "$FAKE_DIR/argv" | grep -qx 0.2 && ok || bad "bulk-read: SHUNT_MODEL/SHUNT_MAX_BUDGET_USD ignored"
grep -qx "CLAUDE_CODE_MAX_OUTPUT_TOKENS=unset" "$FAKE_DIR/env" && ok || bad "bulk-read: an inherited CLAUDE_CODE_MAX_OUTPUT_TOKENS reached the child"
SHUNT_MAX_BUDGET_USD='1;rm' br "malformed budget falls back" 0 - - --question "$Q" --paths small.txt
grep -A1 -xF -- "--max-budget-usd" "$FAKE_DIR/argv" | grep -qx 0.05 && ok || bad "bulk-read: malformed budget passed through"
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
FAKE_CLAUDE_MODE=budget br "budget exceeded" 1 "cost more than SHUNT_MAX_BUDGET_USD=0.05 (cost 0.07) and the answer was discarded" - --question "$Q" --paths small.txt
FAKE_CLAUDE_MODE=outlimit br "output token limit" 1 "hit an output token limit" - --question "$Q" --paths small.txt
FAKE_CLAUDE_MODE=garbage br "non-JSON output" 1 "non-JSON output. $FB_MSG" - --question "$Q" --paths small.txt
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
SHUNT_MAX_FILES=2 brx "too many files" "over SHUNT_MAX_FILES=2" --question "$Q" --paths small.txt big.txt l350.txt
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
  kube-config.yaml .dev.vars AuthKey_ABC.p8 cert.der private_key ssh_host_ed25519_key etc/rancher/k3s/k3s.yaml)
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
(umask 077; br "private mode not a signal under umask 077: sent" 0 - - --question "$Q" --paths plain-a.txt)
chmod 644 "$F/plain-a.txt"
i=0
for m in "-----BEGIN RSA PRIVATE KEY-----" "-----BEGIN PRIVATE KEY-----" "-----BEGIN EC PRIVATE KEY-----" \
  "-----BEGIN OPENSSH PRIVATE KEY-----" "-----BEGIN ENCRYPTED PRIVATE KEY-----" "-----BEGIN PGP PRIVATE KEY BLOCK-----" \
  "AGE-SECRET-KEY-1QQQQQQQQQQQQQQQQ" $'data: ENC[AES256_GCM,data:x,iv:y]\nsops:\n  version: 3' \
  $'{"a": "ENC[AES256_GCM,data:x]", "sops": {}}' $'sops:\n  age: []\nkey: ENC[x]'; do
  i=$((i + 1)); { echo "intro"; printf '%s\n' "$m"; echo "outro"; } > "$F/notes-$i.md"
  brx "marker $i refused under an innocent name" "contains private key or sops-encrypted material" --question "$Q" --paths "notes-$i.md"
done
printf 'the word sops: appears, and so does the word PRIVATE KEY, but no marker\n' > "$F/prose.md"
br "prose mentioning sops: without ENC[ is sent" 0 - - --question "$Q" --paths prose.md
BR_CWD="$TMP/globcwd" SHUNT_EXCLUDE='*.log' brx "SHUNT_EXCLUDE not glob-expanded against cwd" "not delegated" --question "$Q" --paths g/vendor.log
grep -q '"hook":"bulk-read".*"result":"private"' "$XDG_STATE_HOME"/claude-hooks/*.jsonl && ok || bad "private refusal not logged"
grep -q '"hook":"bulk-read".*"result":"secret"' "$XDG_STATE_HOME"/claude-hooks/*.jsonl && ok || bad "secret refusal not logged"
grep -q '"hook":"bulk-read".*"result":"sensitive"' "$XDG_STATE_HOME"/claude-hooks/*.jsonl && ok || bad "sensitive refusal not logged"
grep -q '"hook":"bulk-read".*"result":"invalid"' "$XDG_STATE_HOME"/claude-hooks/*.jsonl && ok || bad "bulk-read: validation failure not logged"
[ -n "$(ls -A "$TMP/tmpd")" ] && bad "bulk-read: temp dir left behind" || ok

echo "---"
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
