#!/usr/bin/env bash
# Skill-use suite: hooks/emit-skill-use.sh against a local receiver (127.0.0.1,
# ephemeral port) that records each POST. No model, no network beyond loopback.
# Run: bash tests/test-skill-use.sh   (also wired as skills:test:skill-use and pre-push)

# ok/bad always succeed, so `A && ok || bad` is an if-then-else here.
# shellcheck disable=SC2015
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/hooks/emit-skill-use.sh"
TMP=$(mktemp -d)
RECV_PID=""
trap '[ -n "$RECV_PID" ] && kill "$RECV_PID" 2>/dev/null; rm -rf "$TMP"' EXIT
export XDG_STATE_HOME="$TMP/state" CLAUDE_CONFIG_DIR="$TMP/conf"
unset HARNESS_OTLP_ENDPOINT HARNESS_RESOURCE_ATTRIBUTES HARNESS_SKILL_USE_DISABLE

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }

# Receiver: one JSON line per POST (path, content type, parsed body).
CAP="$TMP/captured.jsonl"
cat > "$TMP/recv.py" <<'PY'
import http.server, json, sys
out, portfile = sys.argv[1], sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        rec = {"path": self.path, "type": self.headers.get("Content-Type", ""), "body": json.loads(body)}
        with open(out, "a") as f:
            f.write(json.dumps(rec) + "\n")
        self.send_response(200)
        self.end_headers()
    def log_message(self, *a): pass
s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
with open(portfile, "w") as f:
    f.write(str(s.server_address[1]))
s.serve_forever()
PY
python3 -I "$TMP/recv.py" "$CAP" "$TMP/port" >/dev/null 2>&1 &
RECV_PID=$!
for _ in $(seq 50); do [ -s "$TMP/port" ] && break; sleep 0.1; done
[ -s "$TMP/port" ] || { echo "FAIL: receiver did not start"; exit 1; }
EP="http://127.0.0.1:$(cat "$TMP/port")"
: > "$CAP"

# tool <session> <skill> [agent_type]: a PreToolUse(Skill) input; the args must never be exported.
tool() { jq -nc --arg s "$1" --arg k "$2" --arg a "${3:-}" \
  '{session_id: $s, cwd: "/", hook_event_name: "PreToolUse", tool_name: "Skill", tool_input: {skill: $k, args: "ARGSECRET"}}
   + (if $a == "" then {} else {agent_type: $a} end)'; }
# prompt <session> <text> [cwd]: a UserPromptSubmit input.
prompt() { jq -nc --arg s "$1" --arg p "$2" --arg d "${3:-/}" '{session_id: $s, cwd: $d, hook_event_name: "UserPromptSubmit", prompt: $p}'; }

# run <name> <want_result> <stdin> [VAR=value...]: exit 0, empty stdout and stderr,
# under 1 s, and the hook's logged result; MS holds the runtime.
SLOWEST=0
run() {
  local name="$1" want="$2" json="$3" t0 code got
  shift 3
  t0=$(date +%s%N)
  printf '%s' "$json" | env "$@" "$HOOK" >"$TMP/out" 2>"$TMP/err"; code=$?
  MS=$(( ($(date +%s%N) - t0) / 1000000 ))
  [ "$MS" -gt "$SLOWEST" ] && SLOWEST=$MS
  got=$(cat "$XDG_STATE_HOME"/claude-hooks/*.jsonl 2>/dev/null | jq -r 'select(.hook == "skill-use") | .result' | tail -1)
  if [ "$code" -eq 0 ] && [ ! -s "$TMP/out" ] && [ ! -s "$TMP/err" ] && [ "$MS" -lt 1000 ] && [ "$got" = "$want" ]; then ok; else
    bad "$name (exit=$code result=$got want=$want ms=$MS stdout='$(cat "$TMP/out")' stderr='$(cat "$TMP/err")')"; fi
}

# rec <session> <jq filter>: the filter over that session's captured record (waits up to 5 s for it).
rec() {
  local r=""
  for _ in $(seq 50); do
    r=$(jq -c --arg s "$1" 'select(any(.body.resourceLogs[0].scopeLogs[0].logRecords[0].attributes[];
      .key == "session.id" and .value.stringValue == $s))' "$CAP" 2>/dev/null | tail -1)
    [ -n "$r" ] && break; sleep 0.1
  done
  printf '%s' "$r" | jq -r "$2" 2>/dev/null
}
# attrs <session>: the record's attributes as sorted k=v pairs.
attrs() { rec "$1" '[.body.resourceLogs[0].scopeLogs[0].logRecords[0].attributes[] | "\(.key)=\(.value.stringValue)"] | sort | join(",")'; }
# expect <name> <want> <got>
expect() { [ "$3" = "$2" ] && ok || bad "$1 (got '$3' want '$2')"; }

E="HARNESS_OTLP_ENDPOINT=$EP"
PLUG="$CLAUDE_CONFIG_DIR/plugins/cache/claude-plugins-official/superpowers/7.0.0/skills/brainstorming"
mkdir -p "$CLAUDE_CONFIG_DIR/skills/herdr" "$TMP/proj/.claude/skills/local-skill" "$PLUG"
touch "$CLAUDE_CONFIG_DIR/skills/herdr/SKILL.md" "$TMP/proj/.claude/skills/local-skill/SKILL.md" "$PLUG/SKILL.md"

# ── the Skill tool: identity, resource attributes, payload shape ──
run "Skill tool emits" emitted "$(tool s1 superpowers:brainstorming Explore)" "$E" "HARNESS_RESOURCE_ATTRIBUTES=host.name=lenovo-21cb001pmx, worker.name=push"
expect "posted to /v1/logs" /v1/logs "$(rec s1 .path)"
expect "content type json" application/json "$(rec s1 .type)"
expect "resource attributes" "service.name=claude-code,host.name=lenovo-21cb001pmx,worker.name=push" \
  "$(rec s1 '[.body.resourceLogs[0].resource.attributes[] | "\(.key)=\(.value.stringValue)"] | join(",")')"
expect "body" skill_use "$(rec s1 '.body.resourceLogs[0].scopeLogs[0].logRecords[0].body.stringValue')"
expect "timeUnixNano is a digit string" true "$(rec s1 '.body.resourceLogs[0].scopeLogs[0].logRecords[0].timeUnixNano | test("^[0-9]{19}$")')"
expect "attributes: exactly these" \
  "agent_type=Explore,event.name=skill_use,invocation_trigger=model,session.id=s1,skill.name=superpowers:brainstorming" "$(attrs s1)"
expect "all attributes are strings" true "$(rec s1 '[.body.resourceLogs[0] | .resource.attributes[], .scopeLogs[0].logRecords[0].attributes[] | .value | keys == ["stringValue"]] | all')"
run "every use is a record (no dedupe)" emitted "$(tool s2 herdr)" "$E"
expect "no agent_type when absent" "event.name=skill_use,invocation_trigger=model,session.id=s2,skill.name=herdr" "$(attrs s2)"
run "leading slash dropped" emitted "$(tool s3 /herdr)" "$E"
expect "name without the slash" herdr "$(rec s3 '.body.resourceLogs[0].scopeLogs[0].logRecords[0].attributes[] | select(.key == "skill.name") | .value.stringValue')"

# ── a typed /name: only an installed skill, and only the name ──
run "typed user skill emits" emitted "$(prompt s4 "/herdr PROMPTSECRET and more")" "$E"
expect "typed: name and trigger" "event.name=skill_use,invocation_trigger=user-slash,session.id=s4,skill.name=herdr" "$(attrs s4)"
run "typed plugin skill emits" emitted "$(prompt s5 "/superpowers:brainstorming")" "$E"
run "typed project skill emits" emitted "$(prompt s6 "/local-skill x" "$TMP/proj")" "$E"
run "built-in command is not a skill" no-skill "$(prompt s7 "/clear")" "$E"
run "project skill of another cwd is not a skill" no-skill "$(prompt s8 "/local-skill x")" "$E"
run "plain prompt" no-skill "$(prompt s9 "please run /herdr PROMPTSECRET")" "$E"
run "path-like prompt" no-skill "$(prompt s10 "/etc/passwd PROMPTSECRET")" "$E"
run "unknown plugin:skill is not a skill" no-skill "$(prompt s20 "/foo:PROMPTSECRET")" "$E"
run "unknown skill of a known plugin" no-skill "$(prompt s21 "/superpowers:PROMPTSECRET")" "$E"
run "dot names" no-skill "$(prompt s22 "/..:.. x")" "$E"
run "later line is not a typed skill" no-skill "$(prompt s23 $'hello\n/herdr x')" "$E"
run "non-string prompt" no-skill '{"session_id":"s24","hook_event_name":"UserPromptSubmit","prompt":{"a":"/herdr"}}' "$E"
run "no HOME and no config dir" no-skill "$(prompt s25 "/herdr")" -u HOME -u CLAUDE_CONFIG_DIR "$E"

# ── other tools, bad names, switches and bad input ──
run "another tool" no-skill '{"session_id":"s11","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"skill":"herdr","command":"ARGSECRET"}}' "$E"
run "name with other characters" no-skill "$(tool s12 'her dr;x')" "$E"
run "empty skill name" no-skill "$(tool s13 "")" "$E"
run "81-character name" no-skill "$(tool s26 "$(printf 'a%.0s' $(seq 81))")" "$E"
run "non-string skill" no-skill '{"session_id":"s27","hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":123}}' "$E"
run "string tool_input" no-skill '{"session_id":"s28","hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":"herdr"}' "$E"
run "non-string session" unparsed '{"session_id":{"a":1},"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"herdr"}}' "$E"
run "top-level array" unparsed '[1]' "$E"
run "another hook event" no-skill '{"session_id":"s14","hook_event_name":"Stop"}' "$E"
run "endpoint unset sends nothing" no-endpoint "$(tool s15 herdr)"
run "disable switch" disabled "$(tool s16 herdr)" "$E" HARNESS_SKILL_USE_DISABLE=1
run "malformed stdin" unparsed "not json {" "$E"
run "empty stdin" unparsed "" "$E"
run "no session" unparsed '{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"herdr"}}' "$E"
run "unreachable endpoint returns fast" emitted "$(tool s17 herdr)" HARNESS_OTLP_ENDPOINT=http://10.255.255.1:9
FAST=$MS

# Without jq on PATH: still exit 0 and silent.
mkdir -p "$TMP/bin"
for t in bash cat env realpath date curl; do ln -sf "$(command -v "$t")" "$TMP/bin/$t"; done
printf '%s' "$(tool s18 herdr)" | PATH="$TMP/bin" "$TMP/bin/env" "$E" "$HOOK" >"$TMP/out" 2>&1 && [ ! -s "$TMP/out" ] \
  && ok || bad "no jq: exit 0 and silent"

# Exactly the 6 emitted records arrived, and no prompt text or tool argument in any of them.
sleep 0.5
expect "records received" 6 "$(grep -c . "$CAP")"
grep -q 'PROMPTSECRET\|ARGSECRET' "$CAP" && bad "prompt text or tool arguments leaked into a payload" || ok

echo "---"
echo "slowest hook run ${SLOWEST} ms; unreachable endpoint ${FAST} ms"
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
