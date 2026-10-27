# Fixture suites for the shared task modules, as devenv tasks: each drives the real tasks with --option overrides
# against the Nix-built fakes (herdr with saved machines, gh) and the JSON fixtures under task-modules/fixtures.
{ config, lib, ... }:
{
  tasks = {
    "skills:test:tasks:herdr-inventory" = {
      description = "herdr:inventory over the fake herdr: this host plus saved machines through --machine";
      exec = ''
        set +e -uo pipefail   # the task runner enables errexit; these suites inspect exit codes themselves
        ROOT="$DEVENV_ROOT"; cd "$ROOT" || exit 1
        FX="$ROOT/task-modules/fixtures"; FAKES="${config.coordinator.fakes}/bin"
        TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
        export FAKE_LOG="$TMP/calls.log" FAKE_GH_DIR="$FX/gh"
        PASS=0; FAIL=0
        ok() { PASS=$((PASS+1)); }
        bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
        run() { # <task> [args]
          local task="$1"; shift
          devenv tasks run "$task" --option coordinator.herdrCommand:string "$FAKES/herdr" --option coordinator.ghCommand:string "$FAKES/gh" \
            --option coordinator.stateDir:string "$TMP/state" --option coordinator.timeoutSeconds:int 2 --option coordinator.messageTimeoutSeconds:int 3 --show-output "$@" > "$TMP/run.log" 2>&1; CODE=$?
          OUT=$(grep -E "^\s*\{\"(schema_version\":1|task\":\"$task\")" "$TMP/run.log" | grep -F "\"task\":\"$task\"" | tail -1 | sed -E 's/^\s+//'); [ -n "$OUT" ] || OUT='{}'
        }
        jqr() { jq -r "$1" <<<"$OUT"; }
        summary() { echo "passed=$PASS failed=$FAIL"; [ "$FAIL" -eq 0 ]; }

        # 1. a worker: no saved machines -> this host only, answered 1/1, nothing partial
        export FAKE_HERDR_LIST="$FX/herdr/local-two-agents.json" FAKE_HERDR_MACHINES='[]'
        run herdr:inventory
        [ "$CODE" -eq 0 ] && ok || bad "local: exit $CODE ($(tail -3 "$TMP/run.log"))"
        [ "$(jqr '.hosts|length')" = 1 ] && [ "$(jqr .answered_hosts)" = 1 ] && [ "$(jqr .hosts_total)" = 1 ] && [ "$(jqr .machines_configured)" = 0 ] && ok || bad "local: counts ($OUT)"
        [ "$(jqr '.hosts[0].host')" = "$(hostname -s 2>/dev/null || hostname)" ] && [ "$(jqr '.hosts[0].machine')" = null ] && ok || bad "local: host is this hostname, machine null"
        [ "$(jqr '.hosts[0].agents|length')" = 2 ] && [ "$(jqr '.hosts[0].agents[1].observed_state')" = done ] && [ "$(jqr '.hosts[0].agents[1].task_ref')" = "#42" ] && ok || bad "local: agent records"
        [ "$(jqr .partial)" = false ] && ok || bad "local: not partial"
        grep -q '^herdr machine list --json' "$FAKE_LOG" && ! grep -q 'herdr(machine=' "$FAKE_LOG" && ok || bad "local: machine list asked, no forwarding"
        # 2. the coordinator host: two saved machines, one unreachable -> forwarded reads, partial, errors as data
        : > "$FAKE_LOG"
        export FAKE_HERDR_MACHINES='[{"id":"e236150c763f9ca38a989be19feb0934","label":"acer-swift","target":"acer-swift","session":"default","enabled":true},{"id":"ab","label":"pi-down","target":"pi","enabled":true},{"id":"cd","label":"old","target":"old","enabled":false}]'
        export FAKE_HERDR_LIST_acer_swift="$FX/herdr/remote-ok.json"
        run herdr:inventory
        [ "$CODE" -eq 0 ] && ok || bad "machines: exit $CODE"
        [ "$(jqr .machines_configured)" = 2 ] && [ "$(jqr .hosts_total)" = 3 ] && [ "$(jqr .answered_hosts)" = 2 ] && [ "$(jqr .partial)" = true ] && ok || bad "machines: counts ($OUT)"
        [ "$(jqr '.hosts[] | select(.machine=="acer-swift") | .agents[0].agent_id')" = "wA:p2" ] && [ "$(jqr '.hosts[] | select(.machine=="acer-swift") | .agents[0].machine')" = acer-swift ] && [ "$(jqr '.hosts[] | select(.machine=="acer-swift") | .agents[0].approval_required')" = true ] && ok || bad "machines: remote blocked agent via --machine"
        [ "$(jqr '.hosts[] | select(.machine=="pi-down") | .reachable')" = false ] && [ "$(jqr '.hosts[] | select(.machine=="pi-down") | .error.kind')" = unreachable ] && ok || bad "machines: down machine reported, not hidden"
        grep -q '^herdr(machine=acer-swift) agent list' "$FAKE_LOG" && grep -q '^herdr(machine=pi-down) agent list' "$FAKE_LOG" && ! grep -q 'machine=old' "$FAKE_LOG" && ok || bad "machines: forwarded to enabled machines only"
        # 3. herdr machine list itself failing: this host still answers, the failure is data
        : > "$FAKE_LOG"; export FAKE_HERDR_MACHINES_EXIT=1
        run herdr:inventory
        [ "$CODE" -eq 0 ] && [ "$(jqr .answered_hosts)" = 1 ] && [ "$(jqr .partial)" = true ] && [ "$(jqr .machines_error.kind)" = herdr_error ] && ok || bad "machine list down: local answered, error as data ($OUT)"
        unset FAKE_HERDR_MACHINES_EXIT
        # 4. a machine label with unsafe characters is skipped, never passed to herdr
        : > "$FAKE_LOG"; export FAKE_HERDR_MACHINES='[{"id":"x","label":"a;rm -rf x","target":"t","enabled":true}]'
        run herdr:inventory
        [ "$CODE" -eq 0 ] && ! grep -q 'rm -rf' "$FAKE_LOG" && ok || bad "unsafe label must be skipped"
        # 5. the local server down -> unreachable local, exit 0 (observations never fail), answered 0
        unset FAKE_HERDR_MACHINES; export FAKE_HERDR_MACHINES='[]' FAKE_HERDR_EXIT=1
        run herdr:inventory
        [ "$CODE" -eq 0 ] && [ "$(jqr .answered_hosts)" = 0 ] && [ "$(jqr '.hosts[0].reachable')" = false ] && ok || bad "herdr down: exit 0 with unreachable local ($OUT)"
        unset FAKE_HERDR_EXIT
        summary
      '';
    };
    "skills:test:tasks:herdr-inspect" = {
      description = "herdr:inspect bounds, argv order and --machine forwarding";
      exec = ''
        set +e -uo pipefail   # the task runner enables errexit; these suites inspect exit codes themselves
        ROOT="$DEVENV_ROOT"; cd "$ROOT" || exit 1
        FX="$ROOT/task-modules/fixtures"; FAKES="${config.coordinator.fakes}/bin"
        TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
        export FAKE_LOG="$TMP/calls.log" FAKE_GH_DIR="$FX/gh"
        PASS=0; FAIL=0
        ok() { PASS=$((PASS+1)); }
        bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
        run() { # <task> [args]
          local task="$1"; shift
          devenv tasks run "$task" --option coordinator.herdrCommand:string "$FAKES/herdr" --option coordinator.ghCommand:string "$FAKES/gh" \
            --option coordinator.stateDir:string "$TMP/state" --option coordinator.timeoutSeconds:int 2 --option coordinator.messageTimeoutSeconds:int 3 --show-output "$@" > "$TMP/run.log" 2>&1; CODE=$?
          OUT=$(grep -E "^\s*\{\"(schema_version\":1|task\":\"$task\")" "$TMP/run.log" | grep -F "\"task\":\"$task\"" | tail -1 | sed -E 's/^\s+//'); [ -n "$OUT" ] || OUT='{}'
        }
        jqr() { jq -r "$1" <<<"$OUT"; }
        summary() { echo "passed=$PASS failed=$FAIL"; [ "$FAIL" -eq 0 ]; }

        export FAKE_HERDR_READ="$FX/herdr/read-long.txt" FAKE_HERDR_MACHINES='[{"id":"e236150c763f9ca38a989be19feb0934","label":"acer-swift","target":"acer-swift","enabled":true}]'
        run herdr:inspect --input-json '{"agent_id":"wF:p1","lines":1000,"source":"recent"}'
        [ "$CODE" -eq 0 ] && ok || bad "local read: exit $CODE ($(tail -2 "$TMP/run.log"))"
        [ "$(jqr .lines_returned)" -le 200 ] && [ "$(jqr .capped)" = true ] && [ "$(jqr .lines_requested)" = 1000 ] && ok || bad "cap at 200 lines"
        [ "$(jqr .machine)" = null ] && ok || bad "local read: machine null"
        grep -q '^herdr agent read wF:p1 --lines 200 --source recent --format text' "$FAKE_LOG" && ok || bad "local read: herdr argv (target first)"
        : > "$FAKE_LOG"; export FAKE_HERDR_READ="$FX/herdr/read-visible.txt"
        run herdr:inspect --input-json '{"machine":"acer-swift","agent_id":"wA:p2","lines":40}'
        [ "$CODE" -eq 0 ] && [ "$(jqr .machine)" = acer-swift ] && [ "$(jqr .host)" = acer-swift ] && grep -q '^herdr(machine=acer-swift) agent read wA:p2 --lines 40' "$FAKE_LOG" && ok || bad "remote read through --machine ($OUT)"
        run herdr:inspect --input-json '{"machine":"no-such","agent_id":"wA:p2"}'
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" != null ] && [ "$(jqr .error.kind)" != "" ] && ok || bad "unknown machine must fail (exit $CODE, $OUT)"
        run herdr:inspect --input-json '{"agent_id":"-x;y","lines":5}'
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = invalid_input ] && ok || bad "unsafe agent id rejected"
        run herdr:inspect --input-json '{"machine":"a b","agent_id":"wA:p2"}'
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = invalid_input ] && ok || bad "unsafe machine label rejected"
        run herdr:inspect --input-json '{"agent_id":"wF:p1","source":"everything"}'
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = invalid_input ] && ok || bad "bad source rejected"
        summary
      '';
    };
    "skills:test:tasks:herdr-message-await" = {
      description = "coord:handoff -> herdr:message (audit, duplicate, blocked) -> herdr:await through --machine";
      exec = ''
        set +e -uo pipefail   # the task runner enables errexit; these suites inspect exit codes themselves
        ROOT="$DEVENV_ROOT"; cd "$ROOT" || exit 1
        FX="$ROOT/task-modules/fixtures"; FAKES="${config.coordinator.fakes}/bin"
        TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
        export FAKE_LOG="$TMP/calls.log" FAKE_GH_DIR="$FX/gh"
        PASS=0; FAIL=0
        ok() { PASS=$((PASS+1)); }
        bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
        run() { # <task> [args]
          local task="$1"; shift
          devenv tasks run "$task" --option coordinator.herdrCommand:string "$FAKES/herdr" --option coordinator.ghCommand:string "$FAKES/gh" \
            --option coordinator.stateDir:string "$TMP/state" --option coordinator.timeoutSeconds:int 2 --option coordinator.messageTimeoutSeconds:int 3 --show-output "$@" > "$TMP/run.log" 2>&1; CODE=$?
          OUT=$(grep -E "^\s*\{\"(schema_version\":1|task\":\"$task\")" "$TMP/run.log" | grep -F "\"task\":\"$task\"" | tail -1 | sed -E 's/^\s+//'); [ -n "$OUT" ] || OUT='{}'
        }
        jqr() { jq -r "$1" <<<"$OUT"; }
        summary() { echo "passed=$PASS failed=$FAIL"; [ "$FAIL" -eq 0 ]; }

        export FAKE_HERDR_MACHINES='[{"id":"e236150c763f9ca38a989be19feb0934","label":"acer-swift","target":"acer-swift","enabled":true}]' FAKE_HERDR_SESSION=sess-1 FAKE_PROMPT_OUT="$TMP/prompt.txt"
        draft() { run coord:handoff --input-json "$1"; ID=$(jqr .handoff_id); }
        # a draft for a remote agent, sent through --machine, audited, duplicate refused
        draft '{"machine":"acer-swift","agent_id":"wA:p2","session_id":"sess-1","task_ref":"#7","scope":"fix the docs typo","expected_evidence":"a commit","acceptance":"typo gone"}'
        [ "$CODE" -eq 0 ] && [[ "$ID" =~ ^[a-f0-9]{12}$ ]] && [ "$(jqr .machine)" = acer-swift ] && [ "$(jqr .approval_required)" = true ] && ok || bad "draft: $CODE $OUT"
        [ ! -s "$FAKE_LOG" ] && ok || bad "draft must not touch herdr"
        export FAKE_HERDR_STATE=idle FAKE_HERDR_SEQ=5
        run herdr:message --input-json "{\"handoff_id\":\"$ID\",\"confirm\":\"wrong/wA:p2\"}"
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = not_confirmed ] && ok || bad "wrong confirm refused"
        run herdr:message --input-json "{\"handoff_id\":\"$ID\",\"confirm\":\"acer-swift/wA:p2\"}"
        [ "$CODE" -eq 0 ] && [ "$(jqr .outcome)" = delivered ] && [ "$(jqr .machine)" = acer-swift ] && ok || bad "send: $CODE $OUT"
        AID=$(jqr .audit_id)
        grep -q '^herdr(machine=acer-swift) agent get wA:p2' "$FAKE_LOG" && grep -q '^herdr(machine=acer-swift) agent prompt wA:p2' "$FAKE_LOG" && ok || bad "send went through --machine"
        grep -q 'fix the docs typo' "$FAKE_PROMPT_OUT" && ok || bad "prompt text delivered"
        [ "$(grep -c '"phase":"attempt"' "$TMP/state/audit.jsonl")" = 1 ] && [ "$(grep -c '"outcome":"delivered"' "$TMP/state/audit.jsonl")" = 1 ] && ok || bad "audit attempt+outcome"
        run herdr:message --input-json "{\"handoff_id\":\"$ID\",\"confirm\":\"acer-swift/wA:p2\"}"
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = duplicate ] && grep -q "$AID" <<<"$(jqr .error.message)" && ok || bad "duplicate refused naming the audit id"
        # blocked and busy agents are never prompted
        export FAKE_HERDR_STATE=blocked; : > "$FAKE_LOG"
        draft '{"machine":"acer-swift","agent_id":"wA:p3","task_ref":"#8","scope":"s","expected_evidence":"e","acceptance":"a"}'; ID2=$(jqr .handoff_id)
        run herdr:message --input-json "{\"handoff_id\":\"$ID2\",\"confirm\":\"acer-swift/wA:p3\"}"
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = agent_blocked ] && ! grep -q 'agent prompt' "$FAKE_LOG" && ok || bad "blocked agent not prompted"
        # a local agent: no --machine prefix
        export FAKE_HERDR_STATE=idle; : > "$FAKE_LOG"
        draft '{"agent_id":"wF:p1","session_id":"sess-1","task_ref":"#9","scope":"s","expected_evidence":"e","acceptance":"a"}'; ID3=$(jqr .handoff_id); H=$(jqr .host)
        [ "$H" = "$(hostname -s 2>/dev/null || hostname)" ] && [ "$(jqr .machine)" = null ] && ok || bad "local draft host/machine"
        run herdr:message --input-json "{\"handoff_id\":\"$ID3\",\"confirm\":\"$H/wF:p1\"}"
        [ "$CODE" -eq 0 ] && grep -q '^herdr agent prompt wF:p1' "$FAKE_LOG" && ! grep -q 'machine=' "$FAKE_LOG" && ok || bad "local send without --machine ($CODE)"
        # await by audit id: turn observed (working), then idle; through the same machine
        export FAKE_HERDR_STATE_SEQ="working,idle" ; rm -f "$FAKE_LOG.seq"; : > "$FAKE_LOG"
        run herdr:await --input-json "{\"audit_id\":\"$AID\",\"timeout_s\":5,\"start_timeout_s\":2}"
        [ "$CODE" -eq 0 ] && [ "$(jqr .herdr_state)" = idle ] && [ "$(jqr .worker_done)" = true ] && [ "$(jqr .accepted)" = false ] && [ "$(jqr .machine)" = acer-swift ] && ok || bad "await: $CODE $OUT"
        grep -q '^herdr(machine=acer-swift) agent wait wA:p2' "$FAKE_LOG" && ok || bad "await forwarded through --machine"
        unset FAKE_HERDR_STATE_SEQ
        run herdr:await --input-json '{"audit_id":"000000000000"}'
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = invalid_input ] && ok || bad "unknown audit id rejected"
        summary
      '';
    };
    "skills:test:tasks:evidence" = {
      description = "gh:work for one repo and git:recent for one checkout over fakes";
      exec = ''
        set +e -uo pipefail   # the task runner enables errexit; these suites inspect exit codes themselves
        ROOT="$DEVENV_ROOT"; cd "$ROOT" || exit 1
        FX="$ROOT/task-modules/fixtures"; FAKES="${config.coordinator.fakes}/bin"
        TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
        export FAKE_LOG="$TMP/calls.log" FAKE_GH_DIR="$FX/gh"
        PASS=0; FAIL=0
        ok() { PASS=$((PASS+1)); }
        bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
        run() { # <task> [args]
          local task="$1"; shift
          devenv tasks run "$task" --option coordinator.herdrCommand:string "$FAKES/herdr" --option coordinator.ghCommand:string "$FAKES/gh" \
            --option coordinator.stateDir:string "$TMP/state" --option coordinator.timeoutSeconds:int 2 --option coordinator.messageTimeoutSeconds:int 3 --show-output "$@" > "$TMP/run.log" 2>&1; CODE=$?
          OUT=$(grep -E "^\s*\{\"(schema_version\":1|task\":\"$task\")" "$TMP/run.log" | grep -F "\"task\":\"$task\"" | tail -1 | sed -E 's/^\s+//'); [ -n "$OUT" ] || OUT='{}'
        }
        jqr() { jq -r "$1" <<<"$OUT"; }
        summary() { echo "passed=$PASS failed=$FAIL"; [ "$FAIL" -eq 0 ]; }

        run gh:work --input-json '{"repo":"sammasak/skills"}'
        [ "$CODE" -eq 0 ] && [ "$(jqr '.issues|length')" = 2 ] && [ "$(jqr '.prs|length')" -ge 4 ] && [ "$(jqr .open_pr_count)" = 1 ] && ok || bad "gh:work: $CODE $OUT"
        [ "$(jqr '.prs[] | select(.number==15) | .closes[0]')" = 42 ] && ok || bad "gh:work: closes mapped"
        run gh:work --input-json '{"repo":"sammasak/skills; id"}'
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = invalid_input ] && ok || bad "gh:work: unsafe repo rejected"
        FAKE_GH_EXIT=1 run gh:work --input-json '{"repo":"sammasak/skills"}'
        [ "$CODE" -eq 0 ] && [ "$(jqr .error.kind)" = gh_error ] && ok || bad "gh:work: gh failure is data ($CODE $OUT)"
        git init -q "$TMP/repo" && (cd "$TMP/repo" && git config user.email t@t && git config user.name t && echo a > a && git add a && git commit -qm init && echo b > b)
        run git:recent --input-json "{\"checkout\":\"$TMP/repo\"}"
        [ "$CODE" -eq 0 ] && [ "$(jqr .dirty_files)" = 1 ] && [ "$(jqr '.commits|length')" = 1 ] && [ "$(jqr .repo)" = repo ] && ok || bad "git:recent: $CODE $OUT"
        run git:recent --input-json "{\"checkout\":\"$TMP/none\"}"
        [ "$CODE" -eq 0 ] && [ "$(jqr .error.kind)" = not_found ] && ok || bad "git:recent: missing checkout is data"
        run git:recent --input-json '{"checkout":"relative/path"}'
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = invalid_input ] && ok || bad "git:recent: relative path rejected"
        run git:recent --input-json "{\"checkout\":\"$TMP/../$(basename "$TMP")/repo\"}"
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = invalid_input ] && ok || bad "git:recent: .. rejected"
        summary
      '';
    };
    "skills:test:tasks:harness-session-summary" = {
      description = "harness:session-summary over local Claude and Pi fixtures";
      exec = ''
        set +e -uo pipefail   # the task runner enables errexit; these suites inspect exit codes themselves
        ROOT="$DEVENV_ROOT"; cd "$ROOT" || exit 1
        FX="$ROOT/task-modules/fixtures"; FAKES="${config.coordinator.fakes}/bin"
        TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
        export FAKE_LOG="$TMP/calls.log" FAKE_GH_DIR="$FX/gh"
        PASS=0; FAIL=0
        ok() { PASS=$((PASS+1)); }
        bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
        run() { # <task> [args]
          local task="$1"; shift
          devenv tasks run "$task" --option coordinator.herdrCommand:string "$FAKES/herdr" --option coordinator.ghCommand:string "$FAKES/gh" \
            --option coordinator.stateDir:string "$TMP/state" --option coordinator.timeoutSeconds:int 2 --option coordinator.messageTimeoutSeconds:int 3 --show-output "$@" > "$TMP/run.log" 2>&1; CODE=$?
          OUT=$(grep -E "^\s*\{\"(schema_version\":1|task\":\"$task\")" "$TMP/run.log" | grep -F "\"task\":\"$task\"" | tail -1 | sed -E 's/^\s+//'); [ -n "$OUT" ] || OUT='{}'
        }
        jqr() { jq -r "$1" <<<"$OUT"; }
        summary() { echo "passed=$PASS failed=$FAIL"; [ "$FAIL" -eq 0 ]; }

        H="$FX/harness"
        runh() { devenv tasks run harness:session-summary --option coordinator.claudeProjectsDir:string "$H/claude" --option coordinator.piSessionsDir:string "$H/pi" --show-output --input-json "$1" > "$TMP/run.log" 2>&1; CODE=$?; OUT=$(grep -E '^\s*\{"schema_version":1' "$TMP/run.log" | tail -1 | sed -E 's/^\s+//'); [ -n "$OUT" ] || OUT='{}'; }
        runh '{"harness":"claude","session_id":"aaaaaaaa-1111-4111-8111-111111111111","cwd":"/home/lukas/herman"}'
        [ "$CODE" -eq 0 ] && [ "$(jqr .event_count)" = 7 ] && [ "$(jqr .last_role)" = assistant ] && [ "$(jqr .awaiting_input)" = true ] && [ "$(jqr .task_ref)" = "#42" ] && ok || bad "claude: $CODE $OUT"
        [ "$(jqr .host)" = "$(hostname -s 2>/dev/null || hostname)" ] && ok || bad "claude: host is this host"
        runh '{"harness":"claude","session_id":"nope-1111","cwd":"/home/lukas/herman"}'
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = not_found ] && ok || bad "missing session -> not_found ($CODE $OUT)"
        runh '{"harness":"codex","session_id":"x","cwd":"/home/lukas/herman"}'
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = unsupported ] && ok || bad "codex unsupported, honestly ($CODE $OUT)"
        runh '{"harness":"pi","session_id":"pi-sess-1","cwd":"/home/lukas/karta"}'
        [ "$CODE" -eq 0 ] && [ "$(jqr .event_count)" -ge 1 ] && ok || bad "pi: $CODE $OUT"
        runh '{"harness":"claude","session_id":"a;b","cwd":"/home/lukas/herman"}'
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = invalid_input ] && ok || bad "unsafe session id rejected"
        summary
      '';
    };
  };
}
