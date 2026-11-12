#!/usr/bin/env bash
# Work-ref suite: hooks/emit-work-ref.sh against temp git repos with fake origin
# URLs and a local receiver (127.0.0.1, ephemeral port) that records each POST.
# No gh, no model, no network beyond loopback and one unroutable address.
# Run: bash tests/test-work-ref.sh   (also wired as skills:test:work-ref and pre-push)

# ok/bad always succeed, so `A && ok || bad` is an if-then-else here.
# shellcheck disable=SC2015
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/hooks/emit-work-ref.sh"
TMP=$(mktemp -d)
RECV_PID=""
trap '[ -n "$RECV_PID" ] && kill "$RECV_PID" 2>/dev/null; rm -rf "$TMP"' EXIT
export XDG_STATE_HOME="$TMP/state" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset HARNESS_OTLP_ENDPOINT HARNESS_RESOURCE_ATTRIBUTES HARNESS_WORK_REF_DISABLE GIT_DIR GIT_WORK_TREE

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

# inp <session> <cwd> [agent_type]
inp() { jq -nc --arg s "$1" --arg d "$2" --arg a "${3:-}" \
  '{session_id: $s, cwd: $d, hook_event_name: "Stop"} + (if $a == "" then {} else {agent_type: $a} end)'; }

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
  got=$(cat "$XDG_STATE_HOME"/claude-hooks/*.jsonl 2>/dev/null | jq -r 'select(.hook == "work-ref") | .result' | tail -1)
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
# attr <session> <key>: a log record attribute ("" when absent).
attr() { rec "$1" ".body.resourceLogs[0].scopeLogs[0].logRecords[0].attributes[] | select(.key == \"$2\") | .value.stringValue"; }
# expect <name> <want> <got>
expect() { [ "$3" = "$2" ] && ok || bad "$1 (got '$3' want '$2')"; }

# repo <dir> <origin url|-> [branch]
repo() {
  git init -q -b main "$1" && git -C "$1" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  [ "$2" = - ] || git -C "$1" remote add origin "$2"
  [ -z "${3:-}" ] || git -C "$1" checkout -q -b "$3"
}

E="HARNESS_OTLP_ENDPOINT=$EP"
R1="$TMP/r1"
repo "$R1" git@github.com:sammasak/skills.git fix/143-kyverno-background-reports
mkdir -p "$R1/sub"

# ── first emit: identity, resource attributes, payload shape ──
run "first Stop emits" emitted "$(inp s1 "$R1/sub" Explore)" "$E" "HARNESS_RESOURCE_ATTRIBUTES=host.name=lenovo-21cb001pmx, worker.name=push"
expect "posted to /v1/logs" /v1/logs "$(rec s1 .path)"
expect "content type json" application/json "$(rec s1 .type)"
expect "resource attributes" "service.name=claude-code,host.name=lenovo-21cb001pmx,worker.name=push" \
  "$(rec s1 '[.body.resourceLogs[0].resource.attributes[] | "\(.key)=\(.value.stringValue)"] | join(",")')"
expect "body" work_ref "$(rec s1 '.body.resourceLogs[0].scopeLogs[0].logRecords[0].body.stringValue')"
expect "timeUnixNano is a digit string" true "$(rec s1 '.body.resourceLogs[0].scopeLogs[0].logRecords[0].timeUnixNano | test("^[0-9]{19}$")')"
expect "event.name" work_ref "$(attr s1 event.name)"
expect "owner" sammasak "$(attr s1 vcs.owner.name)"
expect "repo" skills "$(attr s1 vcs.repository.name)"
expect "branch" fix/143-kyverno-background-reports "$(attr s1 vcs.ref.head.name)"
expect "revision" "$(git -C "$R1" rev-parse HEAD | cut -c1-12)" "$(attr s1 vcs.ref.head.revision)"
expect "hint from fix/<n>-" 143 "$(attr s1 work.ref.hint)"
expect "agent_type" Explore "$(attr s1 agent_type)"
expect "all attributes are strings" true "$(rec s1 '[.body.resourceLogs[0] | .resource.attributes[], .scopeLogs[0].logRecords[0].attributes[] | .value | keys == ["stringValue"]] | all')"

# ── dedupe on repository and branch, not the commit ──
run "same branch not resent" unchanged "$(inp s1 "$R1")" "$E"
git -C "$R1" -c user.name=t -c user.email=t@t commit -q --allow-empty -m two
run "new commit on the same branch not resent" unchanged "$(inp s1 "$R1")" "$E"
git -C "$R1" checkout -q -b issue-76-foo
run "branch change emits again" emitted "$(inp s1b "$R1")" "$E"
run "branch change emits again (same session)" emitted "$(inp s1 "$R1")" "$E"
for _ in $(seq 50); do [ "$(attr s1 vcs.ref.head.name)" = issue-76-foo ] && break; sleep 0.1; done
expect "second record carries the new branch" issue-76-foo "$(attr s1 vcs.ref.head.name)"
expect "hint from issue-<n>" 76 "$(attr s1 work.ref.hint)"
expect "no agent_type when absent" "" "$(attr s1 agent_type)"

# ── hint extraction (https remote) ──
R2="$TMP/r2"
repo "$R2" https://github.com/acme/widget
n=0
for pair in "gh-12-flaky:12" "pr/x-#31:31" "421-quick-fix:421" "issue/9:9" "feat/work-ref-telemetry:" "release/2026-11:"; do
  n=$((n + 1)); b=${pair%:*}; want=${pair##*:}
  git -C "$R2" checkout -q -b "$b"
  run "hint case $b" emitted "$(inp "h$n" "$R2")" "$E"
  expect "hint for $b" "$want" "$(attr "h$n" work.ref.hint)"
done
expect "https owner/repo" acme/widget "$(attr h1 vcs.owner.name)/$(attr h1 vcs.repository.name)"

# ── detached HEAD: no branch, still the revision ──
git -C "$R1" checkout -q --detach
run "detached HEAD emits" emitted "$(inp s3 "$R1")" "$E"
expect "detached: no branch attribute" "" "$(attr s3 vcs.ref.head.name)"
expect "detached: revision" "$(git -C "$R1" rev-parse HEAD | cut -c1-12)" "$(attr s3 vcs.ref.head.revision)"

# ── remotes ──
R3="$TMP/r3"; repo "$R3" "https://x-access-token:SECRETTOKEN@github.com/acme/creds.git" main2
run "https with credentials emits" emitted "$(inp s4 "$R3")" "$E"
expect "credentials: owner/repo" acme/creds "$(attr s4 vcs.owner.name)/$(attr s4 vcs.repository.name)"
grep -q SECRETTOKEN "$CAP" && bad "credentials leaked into a payload" || ok
R4="$TMP/r4"; repo "$R4" ssh://git@github.com/acme/thing
run "ssh:// remote emits" emitted "$(inp s5 "$R4")" "$E"
expect "ssh:// owner/repo" acme/thing "$(attr s5 vcs.owner.name)/$(attr s5 vcs.repository.name)"
R5="$TMP/r5"; repo "$R5" git@gitlab.com:acme/thing.git
run "non-github remote skipped" no-repo "$(inp s6 "$R5")" "$E"
R6="$TMP/r6"; repo "$R6" -
run "no origin skipped" no-repo "$(inp s7 "$R6")" "$E"
mkdir -p "$TMP/plain"
run "non-git cwd skipped" no-repo "$(inp s8 "$TMP/plain")" "$E"

# ── switches and bad input ──
run "endpoint unset sends nothing" no-endpoint "$(inp s9 "$R2")"
run "disable switch" disabled "$(inp s10 "$R2")" "$E" HARNESS_WORK_REF_DISABLE=1
run "malformed stdin" unparsed "not json {" "$E"
run "empty stdin" unparsed "" "$E"
run "no cwd" unparsed '{"session_id":"s11"}' "$E"
run "unreachable endpoint returns fast" emitted "$(inp s12 "$R2")" HARNESS_OTLP_ENDPOINT=http://10.255.255.1:9
FAST=$MS

# Without jq on PATH: still exit 0 and silent.
mkdir -p "$TMP/bin"
for t in bash cat env realpath date git curl timeout; do ln -sf "$(command -v "$t")" "$TMP/bin/$t"; done
printf '%s' "$(inp s13 "$R2")" | PATH="$TMP/bin" "$TMP/bin/env" "$E" "$HOOK" >"$TMP/out" 2>&1 && [ ! -s "$TMP/out" ] \
  && ok || bad "no jq: exit 0 and silent"

# Exactly the 12 emitted records arrived: nothing from a skipped, deduped or unreachable run.
sleep 0.5
expect "records received" 12 "$(grep -c . "$CAP")"

echo "---"
echo "slowest hook run ${SLOWEST} ms; unreachable endpoint ${FAST} ms"
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
