# Fixture suites for the shared task modules, as devenv tasks: each drives the real tasks with --option overrides
# against the Nix-built fakes (herdr with saved machines, gh) and the JSON fixtures under task-modules/fixtures.
{ config, lib, ... }:
{
  tasks = {
    "skills:test:tasks:host-locks" = {
      description = "host:locks over the fake observer and fake ssh: this host's lanes (holder, waiters oldest first, ages, queue depth), a busy saved machine over its target, an unreachable one, an unsafe target never passed to ssh, a failing observer as data";
      exec = ''
        set +e -uo pipefail   # the task runner enables errexit; these suites inspect exit codes themselves
        ROOT="$DEVENV_ROOT"; cd "$ROOT" || exit 1
        FX="$ROOT/task-modules/fixtures"; FAKES="${config.coordinator.fakes}/bin"
        TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
        export FAKE_LOG="$TMP/calls.log"
        PASS=0; FAIL=0
        ok() { PASS=$((PASS+1)); }
        bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
        run() { # [args]
          devenv tasks run host:locks --option coordinator.herdrCommand:string "$FAKES/herdr" --option coordinator.sshCommand:string "$FAKES/ssh" \
            --option coordinator.locksCommand:string "''${LOCKS_CMD:-$FAKES/host-locks}" --option coordinator.timeoutSeconds:int 2 --show-output "$@" > "$TMP/run.log" 2>&1; CODE=$?
          OUT=$(grep -E "^\s*\{\"schema_version\":1" "$TMP/run.log" | grep -F '"task":"host:locks"' | tail -1 | sed -E 's/^\s+//'); [ -n "$OUT" ] || OUT='{}'
        }
        jqr() { jq -r "$1" <<<"$OUT"; }
        hq() { jq -r --arg h "$1" ".hosts[] | select(.host == \$h) | $2" <<<"$OUT"; }
        lane() { hq "$1" ".lanes[] | select(.lane == \"$2\") | $3"; }
        summary() { echo "passed=$PASS failed=$FAIL"; [ "$FAIL" -eq 0 ]; }
        H=$(hostname -s 2>/dev/null || hostname)

        # 1. this host only, nothing held: one reachable host with no lanes, never partial
        export FAKE_HERDR_MACHINES='[]' FAKE_LOCKS_OUT="$FX/locks/idle.tsv"
        run
        [ "$CODE" -eq 0 ] && [ "$(jqr '.hosts | length')" = 1 ] && [ "$(jqr .partial)" = false ] && ok || bad "idle local: exit $CODE ($(tail -3 "$TMP/run.log"))"
        [ "$(hq "$H" '"\(.reachable) \(.machine) \(.lanes | length)"')" = "true null 0" ] && ok || bad "idle local: reachable, no lanes ($(hq "$H" .))"
        grep -q '^host-locks' "$FAKE_LOG" && ! grep -q '^ssh' "$FAKE_LOG" && ok || bad "local observation runs the observer, never ssh"
        # 2. this host busy: the heavy lane's holder and two waiters (oldest first), the light lane's holder, ages and ISO since
        export FAKE_LOCKS_OUT="$FX/locks/busy.tsv"
        run
        [ "$(lane "$H" heavy-work '"\(.queue_depth) \(.holder.pid) \(.holder.age_s) \(.waiters | length) \(.waiters[0].pid) \(.waiters[1].pid)"')" = "3 3368030 2300 2 3368490 3378976" ] && ok || bad "busy heavy lane ($(lane "$H" heavy-work .))"
        [ "$(lane "$H" heavy-work .holder.what)" = "devenv tasks run platform:verify" ] && ok || bad "the flock prefix is stripped from what ($(lane "$H" heavy-work .holder.what))"
        [ "$(lane "$H" heavy-work .lock)" = "/tmp/$H-heavy-work.lock" ] && lane "$H" heavy-work .holder.since | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' && ok || bad "lock path and ISO since"
        [ "$(lane "$H" light-work '"\(.queue_depth) \(.waiters | length) \(.holder.age_s)"')" = "1 0 30" ] && ok || bad "light lane: one holder, no waiters ($(lane "$H" light-work .))"
        # 3. saved machines: worker-a (busy) over its ssh target, down-b unreachable, an unsafe target refused and never passed to ssh
        : > "$FAKE_LOG"; export FAKE_LOCKS_OUT="$FX/locks/idle.tsv" FAKE_SSH_OUT_lukas_worker_a="$FX/locks/busy.tsv"
        export FAKE_HERDR_MACHINES='[{"id":"a","label":"worker-a","target":"lukas@worker-a","enabled":true},{"id":"b","label":"down-b","target":"down-b","enabled":true},{"id":"c","label":"bad","target":"x;rm -rf /","enabled":true}]'
        run
        [ "$CODE" -eq 0 ] && [ "$(jqr '"\(.hosts_total) \(.answered_hosts) \(.partial)"')" = "4 2 true" ] && ok || bad "machines: counts ($(jqr '"\(.hosts_total) \(.answered_hosts) \(.partial)"'))"
        [ "$(lane worker-a heavy-work .queue_depth)" = 3 ] && [ "$(hq worker-a '"\(.reachable) \(.machine)"')" = "true worker-a" ] && ok || bad "worker-a observed over ssh ($(hq worker-a .))"
        [ "$(hq down-b '"\(.reachable) \(.error.kind)"')" = "false command_failed" ] && [ "$(hq down-b '.lanes | length')" = 0 ] && ok || bad "down-b: unreachable as data ($(hq down-b .))"
        [ "$(hq bad .error.kind)" = invalid_label ] && ! grep -q 'rm -rf' "$FAKE_LOG" && ok || bad "unsafe target never reaches ssh"
        grep -q '^ssh -o BatchMode=yes -o ConnectTimeout=5 lukas@worker-a sh -s' "$FAKE_LOG" && ok || bad "ssh is called with the target and the observer on stdin ($(grep ssh "$FAKE_LOG"))"
        # 4. a failing local observer is data, never a failed task
        export FAKE_HERDR_MACHINES='[]'; LOCKS_CMD=false run
        [ "$CODE" -eq 0 ] && [ "$(hq "$H" '"\(.reachable) \(.error.kind)"')" = "false command_failed" ] && ok || bad "observer failure: exit $CODE, reachable false ($(hq "$H" .))"
        summary
      '';
    };
    "skills:test:tasks:herdr-inventory" = {
      description = "herdr:inventory over the fake herdr: this host plus saved machines through --machine";
      exec = ''
        set +e -uo pipefail   # the task runner enables errexit; these suites inspect exit codes themselves
        ROOT="$DEVENV_ROOT"; cd "$ROOT" || exit 1
        export HERDR_PANE_ID=coord:p0   # the suite runs its tasks from the Coordinator's own pane, never a target
        # hermetic: a devenv.local.nix in the checkout (the coordinator host writes the owner's delegation and panes there)
        # must not reach the suites; the last --option wins, so each case still sets its own
        devenv() { command devenv "$1" "$2" --option coordinator.mayApprove:bool false --option coordinator.approvalDecision:string "" --option coordinator.panes:string "" "''${@:3}"; }
        FX="$ROOT/task-modules/fixtures"; FAKES="${config.coordinator.fakes}/bin"
        TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
        export FAKE_LOG="$TMP/calls.log" FAKE_GH_DIR="$FX/gh"
        PASS=0; FAIL=0
        ok() { PASS=$((PASS+1)); }
        bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
        run() { # <task> [args]
          local task="$1"; shift
          devenv tasks run "$task" --option coordinator.herdrCommand:string "$FAKES/herdr" --option coordinator.sshCommand:string "$FAKES/ssh" --option coordinator.locksCommand:string "$FAKES/host-locks" --option coordinator.ghCommand:string "$FAKES/gh" \
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
        [ "$(jqr '[.hosts[0].agents[].unavailable] | map(tostring) | join(",")')" = "null,null" ] && ok || bad "local: an unreadable pane is not a usage limit ($OUT)"
        # 1b. usage limits: the done agent's pane ends on the harness's Fable limit line -> unavailable with that line; the
        # working agent is never read; a pane that only quotes the phrase mid-line, and the weekly-limit form
        : > "$FAKE_LOG"; export FAKE_HERDR_READ_wT_p1="$FX/herdr/read-fable-limit.txt" FAKE_HERDR_READ_wF_p1="$FX/herdr/read-fable-limit.txt"
        run herdr:inventory
        [ "$CODE" -eq 0 ] && [ "$(jqr '.hosts[0].agents[1] | "\(.observed_state) \(.unavailable.reason)"')" = "done usage_limit" ] && ok || bad "usage limit: the done agent is unavailable ($OUT)"
        [ "$(jqr '.hosts[0].agents[1].unavailable.line')" = "You've reached your Fable limit. Run /usage-credits to continue or switch models with /model." ] && ok || bad "usage limit: the exact Fable line is kept ($(jqr '.hosts[0].agents[1].unavailable'))"
        [ "$(jqr '.hosts[0].agents[0].unavailable')" = null ] && grep -q '^herdr agent read wT:p1 --lines 30 --source visible' "$FAKE_LOG" && ! grep -q 'agent read wF:p1' "$FAKE_LOG" && ok || bad "usage limit: a working agent is not read ($(grep 'agent read' "$FAKE_LOG"))"
        export FAKE_HERDR_READ_wT_p1="$FX/herdr/read-quoted-limit.txt"; run herdr:inventory
        [ "$(jqr '.hosts[0].agents[1].unavailable')" = null ] && ok || bad "usage limit: a quoted phrase is not a limit ($(jqr '.hosts[0].agents[1].unavailable'))"
        export FAKE_HERDR_READ_wT_p1="$FX/herdr/read-weekly-limit.txt"; run herdr:inventory
        jqr '.hosts[0].agents[1].unavailable.line' | grep -q "You've hit your weekly limit · resets Nov 9" && ok || bad "usage limit: the weekly form ($(jqr '.hosts[0].agents[1].unavailable'))"
        # #70: a stale limit -- the owner ran /model after it (a later "Set model to …" line) -- is not reported, so the
        # worker whose limit has reset or whose model was switched is available again without 30 lines scrolling off
        export FAKE_HERDR_READ_wT_p1="$FX/herdr/read-fable-limit-cleared.txt"; run herdr:inventory
        [ "$(jqr '.hosts[0].agents[1].unavailable')" = null ] && ok || bad "usage limit: a limit the owner cleared with /model is stale, the worker is available ($(jqr '.hosts[0].agents[1].unavailable'))"
        unset FAKE_HERDR_READ_wT_p1 FAKE_HERDR_READ_wF_p1
        # 2. the coordinator host: two saved machines, one unreachable -> forwarded reads, partial, errors as data
        : > "$FAKE_LOG"
        export FAKE_HERDR_MACHINES='[{"id":"e236150c763f9ca38a989be19feb0934","label":"acer-swift","target":"acer-swift","session":"default","enabled":true},{"id":"ab","label":"pi-down","target":"pi","enabled":true},{"id":"cd","label":"old","target":"old","enabled":false}]'
        export FAKE_HERDR_LIST_acer_swift="$FX/herdr/remote-ok.json"
        run herdr:inventory
        [ "$CODE" -eq 0 ] && ok || bad "machines: exit $CODE"
        [ "$(jqr .machines_configured)" = 2 ] && [ "$(jqr .hosts_total)" = 3 ] && [ "$(jqr .answered_hosts)" = 2 ] && [ "$(jqr .partial)" = true ] && ok || bad "machines: counts ($OUT)"
        [ "$(jqr '.hosts[] | select(.machine=="acer-swift") | .agents[0].agent_id')" = "wA:p2" ] && [ "$(jqr '.hosts[] | select(.machine=="acer-swift") | .agents[0].machine')" = acer-swift ] && [ "$(jqr '.hosts[] | select(.machine=="acer-swift") | .agents[0].approval_required')" = true ] && ok || bad "machines: remote blocked agent via --machine"
        [ "$(jqr '.hosts[] | select(.machine=="pi-down") | .reachable')" = false ] && [ "$(jqr '.hosts[] | select(.machine=="pi-down") | .error.kind')" = command_failed ] && [[ "$(jqr '.hosts[] | select(.machine=="pi-down") | .error.message')" == *"failed to connect"* ]] && ok || bad "machines: down machine reported, not hidden"
        grep -q '^herdr(machine=acer-swift) agent list' "$FAKE_LOG" && grep -q '^herdr(machine=pi-down) agent list' "$FAKE_LOG" && ! grep -q 'machine=old' "$FAKE_LOG" && ok || bad "machines: forwarded to enabled machines only"
        # Runtime titles carry provenance; the same pane/runtime id on two hosts is not one agent.
        export FAKE_HERDR_MACHINES='[{"label":"acer-swift","enabled":true},{"label":"msi-ms7758","enabled":true}]'
        export FAKE_HERDR_LIST_acer_swift="$FX/herdr/runtime.json"
        jq '.result.agents[0] |= (.title = "sammasak/nixos-config#186 rt=coder tpl=abcdef012345" | .agent_status = "blocked" | .tokens.blocked_reason = "runtime failed: exit 1")' "$FX/herdr/runtime.json" > "$TMP/msi.json"
        export FAKE_HERDR_LIST_msi_ms7758="$TMP/msi.json"
        run herdr:inventory
        [ "$CODE" -eq 0 ] && [ "$(jqr '[.hosts[] | select(.machine != null) | .agents[] | select(.runtime_id=="coder" and .agent_id=="wR:p1")] | length')" = 2 ] && ok || bad "same runtime/pane ids retain both hosts ($OUT)"
        [ "$(jqr '.hosts[] | select(.machine=="acer-swift") | .agents[0] | "\(.task_ref) \(.runtime_task_ref) \(.template)"')" = '#42 sammasak/skills#42 0123456789ab' ] && ok || bad "runtime title beats misleading terminal title ($OUT)"
        [ "$(jqr '.hosts[] | select(.machine=="msi-ms7758") | .agents[0] | "\(.task_ref) \(.template) \(.blocked_reason)"')" = '#186 abcdef012345 runtime failed: exit 1' ] && ok || bad "MSI runtime provenance and blocked reason ($OUT)"
        unset FAKE_HERDR_LIST_msi_ms7758
        # 3. herdr machine list itself failing: this host still answers, the failure is data
        : > "$FAKE_LOG"; export FAKE_HERDR_MACHINES_EXIT=1
        run herdr:inventory
        [ "$CODE" -eq 0 ] && [ "$(jqr .answered_hosts)" = 1 ] && [ "$(jqr .partial)" = true ] && [ "$(jqr .machines_error.kind)" = herdr_error ] && ok || bad "machine list down: local answered, error as data ($OUT)"
        unset FAKE_HERDR_MACHINES_EXIT
        # 4. a machine label with unsafe characters (herdr's default `host/session` label, or worse) is shown as a
        #    host the coordinator refuses to forward to, counted in hosts_total and partial, never passed to herdr
        : > "$FAKE_LOG"; export FAKE_HERDR_MACHINES='[{"id":"x","label":"a;rm -rf x","target":"t","enabled":true},{"id":"y","label":"acer/main","target":"acer","enabled":true}]'
        run herdr:inventory
        [ "$CODE" -eq 0 ] && ! grep -q 'rm -rf\|acer/main' "$FAKE_LOG" && ok || bad "unsafe label must never reach herdr"
        [ "$(jqr .hosts_total)" = 3 ] && [ "$(jqr .answered_hosts)" = 1 ] && [ "$(jqr .partial)" = true ] && [ "$(jqr '[.hosts[] | select(.error.kind=="invalid_label")] | length')" = 2 ] && [ "$(jqr '.hosts[] | select(.machine=="acer/main") | .reachable')" = false ] && ok || bad "unsafe labels are visible as invalid_label hosts ($OUT)"
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
        export HERDR_PANE_ID=coord:p0   # the suite runs its tasks from the Coordinator's own pane, never a target
        # hermetic: a devenv.local.nix in the checkout (the coordinator host writes the owner's delegation and panes there)
        # must not reach the suites; the last --option wins, so each case still sets its own
        devenv() { command devenv "$1" "$2" --option coordinator.mayApprove:bool false --option coordinator.approvalDecision:string "" --option coordinator.panes:string "" "''${@:3}"; }
        FX="$ROOT/task-modules/fixtures"; FAKES="${config.coordinator.fakes}/bin"
        TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
        export FAKE_LOG="$TMP/calls.log" FAKE_GH_DIR="$FX/gh"
        PASS=0; FAIL=0
        ok() { PASS=$((PASS+1)); }
        bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
        run() { # <task> [args]
          local task="$1"; shift
          devenv tasks run "$task" --option coordinator.herdrCommand:string "$FAKES/herdr" --option coordinator.sshCommand:string "$FAKES/ssh" --option coordinator.locksCommand:string "$FAKES/host-locks" --option coordinator.ghCommand:string "$FAKES/gh" \
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
        # the excerpt bound must hold past the kernel's 128 KiB single-argument limit and past 200 lines: a record, truncated
        head -c 140000 /dev/zero | tr '\0' a | fold -w 700 > "$TMP/wide.txt"; export FAKE_HERDR_READ="$TMP/wide.txt"
        run herdr:inspect --input-json '{"agent_id":"wF:p1","lines":200,"source":"recent-unwrapped"}'
        [ "$CODE" -eq 0 ] && [ "$(jqr .truncated)" = true ] && [ "$(jqr '.excerpt|length')" = 65536 ] && [ "$(jqr .error)" = null ] && ok || bad "140 KB excerpt: bounded record, not lost ($CODE $(tail -c 300 "$TMP/run.log"))"
        seq 1 300 > "$TMP/tall.txt"; export FAKE_HERDR_READ="$TMP/tall.txt"
        run herdr:inspect --input-json '{"agent_id":"wF:p1","lines":200}'
        [ "$CODE" -eq 0 ] && [ "$(jqr .truncated)" = true ] && [ "$(jqr .lines_returned)" = 200 ] && ok || bad "300-line excerpt cut at 200 ($OUT)"
        export FAKE_HERDR_READ="$FX/herdr/read-visible.txt"
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
      description = "coord:handoff -> herdr:message (authorized_by label gate through gh, allowed_actions in the audit, duplicate, blocked) -> herdr:await through --machine";
      exec = ''
        set +e -uo pipefail   # the task runner enables errexit; these suites inspect exit codes themselves
        ROOT="$DEVENV_ROOT"; cd "$ROOT" || exit 1
        export HERDR_PANE_ID=coord:p0   # the suite runs its tasks from the Coordinator's own pane, never a target
        # hermetic: a devenv.local.nix in the checkout (the coordinator host writes the owner's delegation and panes there)
        # must not reach the suites; the last --option wins, so each case still sets its own
        devenv() { command devenv "$1" "$2" --option coordinator.mayApprove:bool false --option coordinator.approvalDecision:string "" --option coordinator.panes:string "" "''${@:3}"; }
        FX="$ROOT/task-modules/fixtures"; FAKES="${config.coordinator.fakes}/bin"
        TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
        export FAKE_LOG="$TMP/calls.log" FAKE_GH_DIR="$FX/gh"
        PASS=0; FAIL=0
        ok() { PASS=$((PASS+1)); }
        bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
        run() { # <task> [args]
          local task="$1"; shift
          devenv tasks run "$task" --option coordinator.herdrCommand:string "$FAKES/herdr" --option coordinator.sshCommand:string "$FAKES/ssh" --option coordinator.locksCommand:string "$FAKES/host-locks" --option coordinator.ghCommand:string "$FAKES/gh" \
            --option coordinator.stateDir:string "$TMP/state" --option coordinator.timeoutSeconds:int 2 --option coordinator.messageTimeoutSeconds:int 3 --show-output "$@" > "$TMP/run.log" 2>&1; CODE=$?
          OUT=$(grep -E "^\s*\{\"(schema_version\":1|task\":\"$task\")" "$TMP/run.log" | grep -F "\"task\":\"$task\"" | tail -1 | sed -E 's/^\s+//'); [ -n "$OUT" ] || OUT='{}'
        }
        jqr() { jq -r "$1" <<<"$OUT"; }
        summary() { echo "passed=$PASS failed=$FAIL"; [ "$FAIL" -eq 0 ]; }

        export FAKE_HERDR_MACHINES='[{"id":"e236150c763f9ca38a989be19feb0934","label":"acer-swift","target":"acer-swift","enabled":true}]' FAKE_HERDR_SESSION=sess-1 FAKE_PROMPT_OUT="$TMP/prompt.txt"
        export FAKE_GH_LABELS='["epic","assign:implementer","deployment-ready"]' FAKE_GH_EVENTS='[{"event":"labeled","label":{"name":"assign:implementer"},"actor":{"login":"sammasak"},"created_at":"2026-10-27T20:00:00Z"},{"event":"labeled","label":{"name":"epic"},"actor":{"login":"x"},"created_at":"2026-10-01T00:00:00Z"}]'
        draft() { run coord:handoff --input-json "$1"; ID=$(jqr .handoff_id); }
        AUTH='"authorized_by":{"issue_url":"https://github.com/sammasak/skills/issues/7","label":"assign:implementer"}'
        # a draft for a remote agent, sent through --machine, audited, duplicate refused
        draft '{"machine":"acer-swift","agent_id":"wA:p2","session_id":"sess-1","task_ref":"#7","scope":"fix the docs typo","expected_evidence":"a commit","acceptance":"typo gone","allowed_actions":["comment","deploy:none"]}'
        [ "$CODE" -eq 0 ] && [[ "$ID" =~ ^[a-f0-9]{12}$ ]] && [ "$(jqr .machine)" = acer-swift ] && [ "$(jqr .approval_required)" = true ] && ok || bad "draft: $CODE $OUT"
        [ ! -s "$FAKE_LOG" ] && ok || bad "draft must not touch herdr"
        export FAKE_HERDR_STATE=idle FAKE_HERDR_SEQ=5
        run herdr:message --input-json "{\"handoff_id\":\"$ID\",\"confirm\":\"wrong/wA:p2\",$AUTH}"
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = not_confirmed ] && ok || bad "wrong confirm refused"
        # authorized_by (issue URL + owner label) is required and checked before any herdr call
        for bad_auth in "" ',"authorized_by":"label"' ',"authorized_by":{"label":"assign:implementer"}' ',"authorized_by":{"issue_url":"https://github.com/sammasak/skills/issues/7"}' ',"authorized_by":{"issue_url":"https://example.com/sammasak/skills/issues/7","label":"assign:implementer"}' \
            ',"authorized_by":{"issue_url":"https://github.com/sammasak/skills/issues/7","label":"bad\nlabel"}' ',"authorized_by":{"issue_url":"https://github.com/sammasak/skills/issues/7","label":"lbl\n"}' ',"authorized_by":{"issue_url":"https://github.com/sammasak/skills/issues/7\n","label":"assign:implementer"}'; do
          run herdr:message --input-json "{\"handoff_id\":\"$ID\",\"confirm\":\"acer-swift/wA:p2\"$bad_auth}"
          [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = invalid_input ] && jqr .error.message | grep -q authorized_by && [ ! -s "$FAKE_LOG" ] && ok || bad "authorized_by '$bad_auth' refused before herdr ($OUT)"
        done
        # the GitHub gate: the label must be on the issue; absent => authorization_missing, unreadable => gh_error, no herdr call either way
        : > "$FAKE_LOG"
        run herdr:message --input-json "{\"handoff_id\":\"$ID\",\"confirm\":\"acer-swift/wA:p2\",\"authorized_by\":{\"issue_url\":\"https://github.com/sammasak/skills/issues/7\",\"label\":\"approved\"}}"
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = authorization_missing ] && jqr .error.message | grep -q 'assign:implementer' && ! grep -q '^herdr' "$FAKE_LOG" && grep -q '^gh api repos/sammasak/skills/issues/7/labels' "$FAKE_LOG" && [ ! -s "$TMP/state/audit.jsonl" ] && ok || bad "label absent => authorization_missing, nothing sent, no audit attempt ($OUT)"
        : > "$FAKE_LOG"
        FAKE_GH_API_EXIT=1 run herdr:message --input-json "{\"handoff_id\":\"$ID\",\"confirm\":\"acer-swift/wA:p2\",$AUTH}"
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = gh_error ] && ! grep -q '^herdr' "$FAKE_LOG" && ok || bad "gh failure => gh_error, nothing sent ($OUT)"
        : > "$FAKE_LOG"
        run herdr:message --input-json "{\"handoff_id\":\"$ID\",\"confirm\":\"acer-swift/wA:p2\",\"authorized_by\":{\"issue_url\":\"https://github.com/sammasak/skills/issues/7\",\"label\":\"blocked\"}}"
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = authorization_missing ] && [ ! -s "$FAKE_LOG" ] && ok || bad "a label the coordinator can write is refused as authorization even though present ($OUT)"
        for u in 'https://github.com/sammasak/skills/issues/007' 'https://github.com/../skills/issues/7' 'https://github.com/sammasak/./issues/7'; do
          run herdr:message --input-json "{\"handoff_id\":\"$ID\",\"confirm\":\"acer-swift/wA:p2\",\"authorized_by\":{\"issue_url\":\"$u\",\"label\":\"assign:implementer\"}}"
          [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = invalid_input ] && [ ! -s "$FAKE_LOG" ] && ok || bad "issue_url $u refused ($OUT)"
        done
        : > "$FAKE_LOG"
        run herdr:message --input-json "{\"handoff_id\":\"$ID\",\"confirm\":\"acer-swift/wA:p2\",$AUTH}"
        [ "$CODE" -eq 0 ] && [ "$(jqr .outcome)" = delivered ] && [ "$(jqr .machine)" = acer-swift ] && ok || bad "send: $CODE $OUT"
        AID=$(jqr .audit_id)
        [ "$(jqr '.allowed_actions | join(",")')" = "comment,deploy:none" ] && [ "$(jqr .authorized_by.label)" = "assign:implementer" ] && [ "$(jqr .authorized_by.issue_url)" = "https://github.com/sammasak/skills/issues/7" ] && [ "$(jqr .authorized_by.verified)" = true ] && [[ "$(jqr .authorized_by.verified_at)" =~ ^20[0-9]{2}-[0-9]{2}-[0-9]{2}T ]] && ok || bad "send record carries allowed_actions and verified authorized_by"
        [ "$(jqr '.authorized_by.labeled_by + " " + .authorized_by.labeled_at')" = "sammasak 2026-10-27T20:00:00Z" ] && ok || bad "label event actor and time recorded ($OUT)"
        grep -q '^gh api repos/sammasak/skills/issues/7/labels?per_page=100' "$FAKE_LOG" && grep -q '^gh api repos/sammasak/skills/issues/7/events?per_page=100' "$FAKE_LOG" && ok || bad "labels and events fetched through gh before sending"
        grep -q '^herdr(machine=acer-swift) agent get wA:p2' "$FAKE_LOG" && grep -q '^herdr(machine=acer-swift) agent prompt wA:p2' "$FAKE_LOG" && ok || bad "send went through --machine"
        grep -q 'fix the docs typo' "$FAKE_PROMPT_OUT" && grep -q '^Allowed actions: comment, deploy:none\. Reading, committing and opening a PR are always implied; anything else, deleting included, is not allowed\.$' "$FAKE_PROMPT_OUT" && ok || bad "prompt text and allowed-actions line delivered"
        [ "$(grep -c '"phase":"attempt"' "$TMP/state/audit.jsonl")" = 1 ] && [ "$(grep -c '"outcome":"delivered"' "$TMP/state/audit.jsonl")" = 1 ] && ok || bad "audit attempt+outcome"
        H=$(hostname -s 2>/dev/null || hostname)
        [ "$(jq -r 'select(.phase == "attempt") | .from' "$TMP/state/audit.jsonl")" = "$H/coord:p0" ] && ok || bad "the attempt line names the sending pane (from) ($(jq -c 'select(.phase == "attempt") | .from' "$TMP/state/audit.jsonl"))"
        # a Coordinator pane is never a handoff target: the configured list, the pane running the task, and any past sender
        D='"task_ref":"#7","scope":"s","expected_evidence":"e","acceptance":"a","allowed_actions":["comment"]'
        : > "$FAKE_LOG"
        run coord:handoff --option coordinator.panes:string "acer-swift/wC:p1,$H/wC:p2" --input-json "{\"machine\":\"acer-swift\",\"agent_id\":\"wC:p1\",$D}"
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = invalid_input ] && jqr .error.message | grep -q 'Coordinator pane' && [ ! -s "$FAKE_LOG" ] && ok || bad "handoff: a configured Coordinator pane (remote) is refused ($CODE $OUT)"
        run coord:handoff --option coordinator.panes:string "acer-swift/wC:p1,$H/wC:p2" --input-json "{\"agent_id\":\"wC:p2\",$D}"
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = invalid_input ] && jqr .error.message | grep -q 'Coordinator pane' && ok || bad "handoff: a configured Coordinator pane (local) is refused ($CODE $OUT)"
        HERDR_PANE_ID=wS:p1 run coord:handoff --input-json "{\"agent_id\":\"wS:p1\",$D}"
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = invalid_input ] && jqr .error.message | grep -q 'Coordinator pane' && ok || bad "handoff: the pane running the task (HERDR_PANE_ID) is refused as a target ($CODE $OUT)"
        run coord:handoff --input-json "{\"agent_id\":\"coord:p0\",$D}"
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = invalid_input ] && jqr .error.message | grep -q 'Coordinator pane' && ok || bad "handoff: a pane that sent a handoff before (audit from) is refused as a target ($CODE $OUT)"
        RID=$ID; draft "{\"agent_id\":\"wS:p1\",$D}"; SID=$ID; ID=$RID
        : > "$FAKE_LOG"; run herdr:message --option coordinator.panes:string "$H/wS:p1" --input-json "{\"handoff_id\":\"$SID\",\"confirm\":\"$H/wS:p1\",$AUTH}"
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = invalid_input ] && jqr .error.message | grep -q 'Coordinator pane' && [ ! -s "$FAKE_LOG" ] && ok || bad "send: a draft to a pane now listed as a Coordinator pane is refused before gh or herdr ($CODE $OUT)"
        ATT=$(jq -c 'select(.phase == "attempt")' "$TMP/state/audit.jsonl")
        [ "$(jq -r '.allowed_actions | join(",")' <<<"$ATT")" = "comment,deploy:none" ] && [ "$(jq -r '.authorized_by.issue_url + " " + .authorized_by.label + " " + (.authorized_by.verified|tostring)' <<<"$ATT")" = "https://github.com/sammasak/skills/issues/7 assign:implementer true" ] && ok || bad "audit attempt records allowed_actions and verified authorized_by ($ATT)"
        run herdr:message --input-json "{\"handoff_id\":\"$ID\",\"confirm\":\"acer-swift/wA:p2\",$AUTH}"
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = duplicate ] && grep -q "$AID" <<<"$(jqr .error.message)" && ok || bad "duplicate refused naming the audit id"
        # an edited draft (retargeted machine, changed text or widened actions) no longer matches its content-addressed id: refused before any herdr call
        D="$TMP/state/handoffs/$ID.json"; cp "$D" "$D.orig"; : > "$FAKE_LOG"
        jq -c '.machine = "other-box" | .host = "other-box"' "$D.orig" > "$D"
        run herdr:message --input-json "{\"handoff_id\":\"$ID\",\"confirm\":\"other-box/wA:p2\",$AUTH}"
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = invalid_input ] && [ ! -s "$FAKE_LOG" ] && ok || bad "retargeted draft refused ($OUT)"
        jq -c '.text += " and also deploy"' "$D.orig" > "$D"
        run herdr:message --input-json "{\"handoff_id\":\"$ID\",\"confirm\":\"acer-swift/wA:p2\",$AUTH}"
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = invalid_input ] && [ ! -s "$FAKE_LOG" ] && ok || bad "edited draft text refused ($OUT)"
        jq -c '.allowed_actions += ["merge"]' "$D.orig" > "$D"
        run herdr:message --input-json "{\"handoff_id\":\"$ID\",\"confirm\":\"acer-swift/wA:p2\",$AUTH}"
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = invalid_input ] && [ ! -s "$FAKE_LOG" ] && ok || bad "widened allowed_actions refused ($OUT)"
        jq -c 'del(.allowed_actions)' "$D.orig" > "$D"
        run herdr:message --input-json "{\"handoff_id\":\"$ID\",\"confirm\":\"acer-swift/wA:p2\",$AUTH}"
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = invalid_input ] && jqr .error.message | grep -q redraft && [ ! -s "$FAKE_LOG" ] && ok || bad "draft without allowed_actions refused ($OUT)"
        mv "$D.orig" "$D"
        # blocked and busy agents are never prompted
        export FAKE_HERDR_STATE=blocked; : > "$FAKE_LOG"
        draft '{"machine":"acer-swift","agent_id":"wA:p3","task_ref":"#8","scope":"s","expected_evidence":"e","acceptance":"a","allowed_actions":["comment"]}'; ID2=$(jqr .handoff_id)
        run herdr:message --input-json "{\"handoff_id\":\"$ID2\",\"confirm\":\"acer-swift/wA:p3\",$AUTH}"
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = agent_blocked ] && ! grep -q 'agent prompt' "$FAKE_LOG" && ok || bad "blocked agent not prompted"
        # a local agent: no --machine prefix
        export FAKE_HERDR_STATE=idle; : > "$FAKE_LOG"
        draft '{"agent_id":"wF:p1","session_id":"sess-1","task_ref":"#9","scope":"s","expected_evidence":"e","acceptance":"a","allowed_actions":["comment","deploy:acer-swift"]}'; ID3=$(jqr .handoff_id); H=$(jqr .host)
        [ "$H" = "$(hostname -s 2>/dev/null || hostname)" ] && [ "$(jqr .machine)" = null ] && ok || bad "local draft host/machine"
        run herdr:message --input-json "{\"handoff_id\":\"$ID3\",\"confirm\":\"$H/wF:p1\",\"authorized_by\":{\"issue_url\":\"https://github.com/sammasak/skills/issues/9\",\"label\":\"deployment-ready\"}}"
        [ "$CODE" -eq 0 ] && grep -q '^herdr agent prompt wF:p1' "$FAKE_LOG" && ! grep -q 'machine=' "$FAKE_LOG" && [ "$(jqr .authorized_by.label)" = deployment-ready ] && ok || bad "local send without --machine ($CODE)"
        # a PR URL reads its labels through the issues path; a deploy:* is never PR-scoped (skills#28), so this one is refused
        : > "$FAKE_LOG"
        draft '{"agent_id":"wF:p1","session_id":"sess-1","task_ref":"#9","scope":"s via PR","expected_evidence":"e","acceptance":"a","allowed_actions":["comment","deploy:acer-swift"]}'; ID3P=$(jqr .handoff_id)
        run herdr:message --input-json "{\"handoff_id\":\"$ID3P\",\"confirm\":\"$H/wF:p1\",\"authorized_by\":{\"issue_url\":\"https://github.com/sammasak/skills/pull/9\",\"label\":\"deployment-ready\"}}"
        grep -q '^gh api repos/sammasak/skills/issues/9/labels' "$FAKE_LOG" && [ "$CODE" -ne 0 ] && ! grep -q 'agent prompt' "$FAKE_LOG" && ok || bad "a PR URL is checked through the issues labels path, and a PR-scoped deploy is refused ($CODE $OUT)"
        # only the trailing /pull/N is mapped: an owner or repo named pull keeps its name
        : > "$FAKE_LOG"
        draft '{"agent_id":"wF:p1","session_id":"sess-1","task_ref":"#11","scope":"s","expected_evidence":"e","acceptance":"a","allowed_actions":["comment"]}'; ID4=$(jqr .handoff_id)
        run herdr:message --input-json "{\"handoff_id\":\"$ID4\",\"confirm\":\"$H/wF:p1\",\"authorized_by\":{\"issue_url\":\"https://github.com/pull/pull/pull/11\",\"label\":\"deployment-ready\"}}"
        grep -q '^gh api repos/pull/pull/issues/11/labels' "$FAKE_LOG" && [ "$(jqr .error.kind)" = authorization_missing ] && ok || bad "pull-named owner and repo survive the URL mapping; PR-scoped, it is then refused for naming no head ($(grep '^gh' "$FAKE_LOG"))"
        # a worker at its usage limit is refused (worker_unavailable) before any attempt line or prompt
        : > "$FAKE_LOG"; draft '{"agent_id":"wF:p1","session_id":"sess-1","task_ref":"#12","scope":"s","expected_evidence":"e","acceptance":"a","allowed_actions":["comment"]}'; ID5=$(jqr .handoff_id)
        FAKE_HERDR_READ_wF_p1="$FX/herdr/read-fable-limit.txt" run herdr:message --input-json "{\"handoff_id\":\"$ID5\",\"confirm\":\"$H/wF:p1\",$AUTH}"
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = worker_unavailable ] && jqr .error.message | grep -q "reached your Fable limit" && ! grep -q 'agent prompt' "$FAKE_LOG" \
          && ! jq -e --arg i "$ID5" 'select(.handoff_id == $i)' "$TMP/state/audit.jsonl" >/dev/null && ok || bad "usage-limited worker refused, nothing sent or audited ($CODE $OUT)"
        # #70 author-merge is keyed on the authorship of the PR being merged, not the authorizing item: the owner labels the
        # issue, so an item's implement, review and merge handoffs all carry the same authorized_by.issue_url. The draft is
        # composed freely; the send is the gate. pr_url renders into the text and is merge-only.
        run coord:handoff --input-json '{"machine":"acer-swift","agent_id":"wA:p2","task_ref":"#7","scope":"merge it","expected_evidence":"e","acceptance":"a","allowed_actions":["merge","comment"],"pr_url":"https://github.com/sammasak/skills/pull/41"}'
        [ "$CODE" -eq 0 ] && [ "$(jqr .pr_url)" = "https://github.com/sammasak/skills/pull/41" ] && jqr .text | grep -q 'Merge target: https://github.com/sammasak/skills/pull/41' && ok || bad "handoff: a merge draft names its PR (pr_url) and composes freely ($CODE $OUT)"
        run coord:handoff --input-json '{"machine":"acer-swift","agent_id":"wA:p2","task_ref":"#7","scope":"review","expected_evidence":"e","acceptance":"a","allowed_actions":["comment"],"pr_url":"https://github.com/sammasak/skills/pull/41"}'
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = invalid_input ] && jqr .error.message | grep -q 'only for a merge' && ok || bad "handoff: pr_url without merge is refused ($CODE $OUT)"
        # a merge handoff that names no PR (no pr_url, no review) drafts freely but the send refuses it: the implementer is unknowable
        draft '{"agent_id":"wF:p1","session_id":"sess-1","task_ref":"#7","scope":"merge unnamed","expected_evidence":"e","acceptance":"a","allowed_actions":["merge"]}'; IDN=$(jqr .handoff_id)
        [ -n "$IDN" ] && [ "$IDN" != null ] || bad "handoff: a merge draft without a PR still composes ($OUT)"
        : > "$FAKE_LOG"; run herdr:message --input-json "{\"handoff_id\":\"$IDN\",\"confirm\":\"$H/wF:p1\",$AUTH}"
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = invalid_input ] && jqr .error.message | grep -q 'name the PR it merges' && ! grep -q 'agent prompt' "$FAKE_LOG" && ok || bad "send: a merge naming no PR is refused ($CODE $OUT)"
        # The real flow (implement, review and merge all authorized by the issue the owner labelled). PRs and audit: wB:p1
        # implemented PR #40 and only reviewed/graded PR #41; wF:p1 implemented PR #41 (the PR being merged); lenovo/wF:p1
        # implemented PR #42. The send attributes a PR from the audit the way correlate.jq does (refs + handoff window),
        # except a pane that only graded it -- so an independent reviewer, who grades, is never taken for the author.
        mkdir -p "$TMP/gh2"
        # #41 carries wB's real 9/10 and, from wF (the author), a comment quoting other reviewers' grades in the host+short
        # "lenovo wN ... Grade: 7/10" wording (no pane:pN token). Authorship is now structural -- a pane is an implementer by
        # its implement handoff, never by a grade in its comments -- so no comment of wF's can drop it from the implementers.
        jq -cn --arg h "$H" '[
          {number:40, state:"OPEN", createdAt:"2026-11-06T10:30:00Z", title:"item for #40", body:"closes #7", headRefName:"wB/40", closingIssuesReferences:[{number:7}], commits:[]},
          {number:41, state:"OPEN", createdAt:"2026-11-06T12:00:00Z", title:"item for #41", body:"closes #7", headRefName:"wF/41", closingIssuesReferences:[{number:7}], commits:[],
           comments:[{body:("Grade: 9/10 on its head. -- " + $h + " wB:p1")}, {body:("Responding to the three independent reviews, including lenovo wN independent Grade: 7/10 and acer-swift wW 7/10, now addressed. -- " + $h + " wF:p1")}]},
          {number:42, state:"OPEN", createdAt:"2026-11-06T09:30:00Z", title:"item for #42", body:"closes #7", headRefName:"wF/42", closingIssuesReferences:[{number:7}], commits:[]},
          {number:50, state:"OPEN", createdAt:"2026-11-06T09:30:00Z", title:"orphan", body:"closes #99", headRefName:"x/50", closingIssuesReferences:[{number:99}], commits:[]}
        ]' > "$TMP/gh2/sammasak__skills.prs.json"
        # cross-repo: an rf-proto PR implementing nixos-config#42 (wW finding 2: the PR's issue is in another repo)
        jq -cn '[
          {number:4, state:"OPEN", createdAt:"2026-11-06T12:45:00Z", title:"slice 6", body:"Implements sammasak/nixos-config#42", headRefName:"slice6", closingIssuesReferences:[], commits:[]}
        ]' > "$TMP/gh2/sammasak__rf-proto.prs.json"
        # seed <host> <agent> <id> <at> [review-pr]: an implement handoff, or (with the 5th arg) a #77 review handoff whose
        # structured review field excludes it from the implementers regardless of any comment its pane leaves
        seed() { jq -cn --arg h "$1" --arg ag "$2" --arg aid "$3" --arg at "$4" --arg rv "''${5:-}" '{phase:"attempt",audit_id:$aid,handoff_id:($aid+"hh"),task_ref:"#7",host:$h,agent_id:$ag,allowed_actions:["comment"],authorized_by:{issue_url:"https://github.com/sammasak/skills/issues/7",label:"assign:implementer",verified:true},at:$at} + (if $rv == "" then {} else {review:{pr:$rv, head:"4141414141414141414141414141414141414141"}} end)'; echo "{\"phase\":\"outcome\",\"audit_id\":\"$3\",\"outcome\":\"delivered\"}"; }
        { seed "$H" wB:p1 im40 "2026-11-06T10:00:00Z"; seed "$H" wB:p1 rv41 "2026-11-06T11:00:00Z" "sammasak/skills#41"; seed "$H" wF:p1 im41 "2026-11-06T11:30:00Z"; seed lenovo wF:p1 im42 "2026-11-06T09:00:00Z"; } >> "$TMP/state/audit.jsonl"
        # wF's implement handoff for nixos-config#42 (a different repo than the rf-proto PR it produced), window opens 12:30
        printf '%s\n%s\n' \
          "$(jq -cn --arg h "$H" '{phase:"attempt",audit_id:"ncim42",handoff_id:"ncim42hhhh",task_ref:"#28",host:$h,agent_id:"wF:p1",allowed_actions:["comment"],authorized_by:{issue_url:"https://github.com/sammasak/nixos-config/issues/42",label:"assign:implementer",verified:true},at:"2026-11-06T12:30:00Z"}')" \
          '{"phase":"outcome","audit_id":"ncim42","outcome":"delivered"}' >> "$TMP/state/audit.jsonl"
        export FAKE_GH_DIR="$TMP/gh2"
        MERGE41='"authorized_by":{"issue_url":"https://github.com/sammasak/skills/issues/7","label":"deployment-ready"}'
        PRMERGE41='"authorized_by":{"issue_url":"https://github.com/sammasak/skills/pull/41","label":"deployment-ready"}'
        # (a) an independent reviewer -- wB:p1 implemented a different PR (#40) and got a #77 review handoff for #41 -- may
        # merge #41, though its handoffs share the issue; its review handoff excludes it from the implementers structurally
        : > "$FAKE_LOG"
        draft '{"agent_id":"wB:p1","session_id":"sess-1","task_ref":"#7","scope":"merge #41","expected_evidence":"e","acceptance":"a","allowed_actions":["merge"],"pr_url":"https://github.com/sammasak/skills/pull/41"}'; IDA=$(jqr .handoff_id)
        run herdr:message --input-json "{\"handoff_id\":\"$IDA\",\"confirm\":\"$H/wB:p1\",$MERGE41}"
        [ "$CODE" -eq 0 ] && grep -q 'agent prompt' "$FAKE_LOG" && ok || bad "send: an independent reviewer (its #41 handoff is a review handoff) merges the PR it did not implement ($CODE $OUT)"
        # (b) the PR's author -- wF:p1's implement handoff produced #41 -- is refused. wF also left a comment on #41 quoting
        # other reviewers' grades in the "lenovo wN ... Grade: 7/10" form (no pane:pN token): own_grade would have read that
        # as wF's own grade and dropped it; authorship is now structural (the implement handoff), so wF is still refused.
        : > "$FAKE_LOG"
        draft '{"agent_id":"wF:p1","session_id":"sess-1","task_ref":"#7","scope":"merge #41","expected_evidence":"e","acceptance":"a","allowed_actions":["merge"],"pr_url":"https://github.com/sammasak/skills/pull/41"}'; IDB=$(jqr .handoff_id)
        run herdr:message --input-json "{\"handoff_id\":\"$IDB\",\"confirm\":\"$H/wF:p1\",$MERGE41}"
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = author_merge ] && ! grep -q 'agent prompt' "$FAKE_LOG" && ok || bad "send: the PR's author, whose own comment quotes another reviewer's grade (lenovo wN form), is still refused ($CODE $OUT)"
        # (c) the author is refused even when the merge is authorized by the PR URL -- the authorizing item cannot excuse it
        : > "$FAKE_LOG"
        # (skills#28: a PR-scoped authorization is the owner's label on that PR, for a handoff naming it at its head)
        H41=4141414141414141414141414141414141414141
        draft "{\"agent_id\":\"wF:p1\",\"session_id\":\"sess-1\",\"task_ref\":\"#7\",\"scope\":\"merge #41 by pr url\",\"expected_evidence\":\"e\",\"acceptance\":\"a\",\"allowed_actions\":[\"merge\"],\"review\":\"sammasak/skills#41@$H41\"}"; IDC=$(jqr .handoff_id)
        FAKE_GH_PR_HEAD=$H41 FAKE_GH_EVENTS='[{"event":"labeled","label":{"name":"deployment-ready"},"actor":{"login":"sammasak"},"created_at":"2026-11-09T10:00:00Z"}]' \
          run herdr:message --input-json "{\"handoff_id\":\"$IDC\",\"confirm\":\"$H/wF:p1\",$PRMERGE41}"
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = author_merge ] && ! grep -q 'agent prompt' "$FAKE_LOG" && ok || bad "send: the author is refused even when the merge is authorized by the PR URL ($CODE $OUT)"
        # host-qualified: lenovo/wF:p1 implemented PR #42; the same agent id on THIS host, which did not, may merge it
        : > "$FAKE_LOG"
        draft '{"agent_id":"wF:p1","session_id":"sess-1","task_ref":"#7","scope":"merge #42","expected_evidence":"e","acceptance":"a","allowed_actions":["merge"],"pr_url":"https://github.com/sammasak/skills/pull/42"}'; IDD=$(jqr .handoff_id)
        run herdr:message --input-json "{\"handoff_id\":\"$IDD\",\"confirm\":\"$H/wF:p1\",$MERGE41}"
        [ "$CODE" -eq 0 ] && grep -q 'agent prompt' "$FAKE_LOG" && ok || bad "send: the same agent id on another host did not implement it here, so the merge is allowed ($CODE $OUT)"
        # cross-repo (wW finding 2): rf-proto PR #4 implements nixos-config#42; wF:p1's implement handoff is authorized by the
        # nixos-config issue, in a different repo than the PR. Attribution matches the handoff because the PR names the
        # qualified sammasak/nixos-config#42, so the author wF is refused...
        NCMERGE='"authorized_by":{"issue_url":"https://github.com/sammasak/nixos-config/issues/42","label":"deployment-ready"}'
        : > "$FAKE_LOG"
        draft '{"agent_id":"wF:p1","session_id":"sess-1","task_ref":"#28","scope":"merge rf-proto#4 (implements nixos-config#42)","expected_evidence":"e","acceptance":"a","allowed_actions":["merge"],"pr_url":"https://github.com/sammasak/rf-proto/pull/4"}'; IDX=$(jqr .handoff_id)
        run herdr:message --input-json "{\"handoff_id\":\"$IDX\",\"confirm\":\"$H/wF:p1\",$NCMERGE}"
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = author_merge ] && ! grep -q 'agent prompt' "$FAKE_LOG" && ok || bad "send: a cross-repo PR's author is refused (PR names OWNER/REPO#N of the handoff's issue) ($CODE $OUT)"
        # ...and an unrelated reviewer (wB:p1 has no nixos-config#42 handoff) may merge the same cross-repo PR
        : > "$FAKE_LOG"
        draft '{"agent_id":"wB:p1","session_id":"sess-1","task_ref":"#28","scope":"merge rf-proto#4","expected_evidence":"e","acceptance":"a","allowed_actions":["merge"],"pr_url":"https://github.com/sammasak/rf-proto/pull/4"}'; IDY=$(jqr .handoff_id)
        run herdr:message --input-json "{\"handoff_id\":\"$IDY\",\"confirm\":\"$H/wB:p1\",$NCMERGE}"
        [ "$CODE" -eq 0 ] && grep -q 'agent prompt' "$FAKE_LOG" && ok || bad "send: an unrelated reviewer may merge the cross-repo PR ($CODE $OUT)"
        # a merge whose PR gh cannot read at all fails closed (implementer unknown, might be the author): nothing is sent
        : > "$FAKE_LOG"
        draft '{"agent_id":"wF:p1","session_id":"sess-1","task_ref":"#7","scope":"merge gh down","expected_evidence":"e","acceptance":"a","allowed_actions":["merge"],"pr_url":"https://github.com/sammasak/skills/pull/41"}'; IDE=$(jqr .handoff_id)
        FAKE_GH_LIST_EXIT=1 run herdr:message --input-json "{\"handoff_id\":\"$IDE\",\"confirm\":\"$H/wF:p1\",$MERGE41}"
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = gh_error ] && ! grep -q 'agent prompt' "$FAKE_LOG" && ok || bad "send: a merge whose PR gh cannot read fails closed ($CODE $OUT)"
        # (wW should-fix 3) a PR the audit attributes to no implementer is not silently allowed: it sends but flags author_check,
        # whether the PR is absent from the list (#999) or present but orphan (#50 closes #99, which no handoff references)
        : > "$FAKE_LOG"
        draft '{"agent_id":"wF:p1","session_id":"sess-1","task_ref":"#7","scope":"merge unlisted","expected_evidence":"e","acceptance":"a","allowed_actions":["merge"],"pr_url":"https://github.com/sammasak/skills/pull/999"}'; IDF=$(jqr .handoff_id)
        run herdr:message --input-json "{\"handoff_id\":\"$IDF\",\"confirm\":\"$H/wF:p1\",$MERGE41}"
        [ "$CODE" -eq 0 ] && grep -q 'agent prompt' "$FAKE_LOG" && [ "$(jqr .author_check)" != null ] && jqr .author_check | grep -q 'not in' && ok || bad "send: a merge for a PR absent from the list is allowed but flagged ($CODE $(jqr .author_check))"
        : > "$FAKE_LOG"
        draft '{"agent_id":"wF:p1","session_id":"sess-1","task_ref":"#7","scope":"merge orphan #50","expected_evidence":"e","acceptance":"a","allowed_actions":["merge"],"pr_url":"https://github.com/sammasak/skills/pull/50"}'; IDG=$(jqr .handoff_id)
        run herdr:message --input-json "{\"handoff_id\":\"$IDG\",\"confirm\":\"$H/wF:p1\",$MERGE41}"
        [ "$CODE" -eq 0 ] && grep -q 'agent prompt' "$FAKE_LOG" && [ "$(jqr .author_check)" != null ] && jqr .author_check | grep -q 'no implementer' && ok || bad "send: a merge for an orphan PR is allowed but flagged ($CODE $(jqr .author_check))"
        export FAKE_GH_DIR="$FX/gh"
        # await by audit id: turn observed (working), then idle; through the same machine
        export FAKE_HERDR_STATE_SEQ="working,idle" ; rm -f "$FAKE_LOG.seq"; : > "$FAKE_LOG"
        run herdr:await --input-json "{\"audit_id\":\"$AID\",\"timeout_s\":5,\"start_timeout_s\":2}"
        [ "$CODE" -eq 0 ] && [ "$(jqr .herdr_state)" = idle ] && [ "$(jqr .worker_done)" = true ] && [ "$(jqr .accepted)" = false ] && [ "$(jqr .machine)" = acer-swift ] && ok || bad "await: $CODE $OUT"
        grep -q '^herdr(machine=acer-swift) agent wait wA:p2' "$FAKE_LOG" && ok || bad "await forwarded through --machine"
        unset FAKE_HERDR_STATE_SEQ
        run herdr:await --input-json '{"audit_id":"000000000000"}'
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = invalid_input ] && ok || bad "unknown audit id rejected"
        # skills#77: a review handoff's key reaches the audit's attempt line, where coord:changed and coord:brief read it; a draft
        #   whose review field no longer matches its text (edited) is refused before herdr
        HEAD77=9090909090909090909090909090909090909090
        export FAKE_HERDR_STATE=idle FAKE_HERDR_SEQ=40
        draft "{\"machine\":\"acer-swift\",\"agent_id\":\"wA:p2\",\"session_id\":\"sess-1\",\"task_ref\":\"#7\",\"scope\":\"review PR #90 at its head\",\"expected_evidence\":\"Grade comment\",\"acceptance\":\"graded\",\"allowed_actions\":[\"comment\",\"merge\"],\"review\":\"sammasak/skills#90@$HEAD77\"}"
        RID=$ID
        run herdr:message --input-json "{\"handoff_id\":\"$RID\",\"confirm\":\"acer-swift/wA:p2\",$AUTH}"
        [ "$CODE" -eq 0 ] && [ "$(jqr .outcome)" = delivered ] && [ "$(jq -r --arg i "$RID" 'select(.handoff_id == $i and .phase == "attempt") | .review | "\(.pr) \(.head)"' "$TMP/state/audit.jsonl")" = "sammasak/skills#90 $HEAD77" ] \
          && ok || bad "skills#77: the review key reaches the attempt line ($OUT)"
        draft "{\"machine\":\"acer-swift\",\"agent_id\":\"wA:p2\",\"session_id\":\"sess-1\",\"task_ref\":\"#7\",\"scope\":\"review PR #91\",\"expected_evidence\":\"Grade comment\",\"acceptance\":\"graded\",\"allowed_actions\":[\"comment\"],\"review\":\"sammasak/skills#91@$HEAD77\"}"
        jq '.review.pr = "sammasak/skills#92"' "$TMP/state/handoffs/$ID.json" > "$TMP/d.json" && mv "$TMP/d.json" "$TMP/state/handoffs/$ID.json"
        : > "$FAKE_LOG"
        run herdr:message --input-json "{\"handoff_id\":\"$ID\",\"confirm\":\"acer-swift/wA:p2\",$AUTH}"
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = invalid_input ] && jqr .error.message | grep -q 'review its text does not state' && ! grep -q 'agent prompt' "$FAKE_LOG" && ok || bad "skills#77: an edited review key is refused ($OUT)"
        # ── skills#28: scope-aware holds and PR-scoped authorization ──
        export FAKE_HERDR_STATE=idle FAKE_HERDR_SEQ=60
        sc_draft() { draft "{\"machine\":\"acer-swift\",\"agent_id\":\"wA:p2\",\"session_id\":\"sess-1\",\"task_ref\":\"#7\",\"scope\":\"$1\",\"expected_evidence\":\"e\",\"acceptance\":\"a\",\"allowed_actions\":$2''${3:-}}"; }
        sc_send() { : > "$FAKE_LOG"; run herdr:message --input-json "{\"handoff_id\":\"$ID\",\"confirm\":\"acer-swift/wA:p2\",$1}"; }
        # (1) needs-live holds only a live scope: routine actions proceed and the attempt line records the hold decision
        export FAKE_GH_LABELS='["assign:implementer","needs-live"]'
        sc_draft "routine under needs-live" '["comment","merge"]'; sc_send "$AUTH"
        [ "$CODE" -eq 0 ] && [ "$(jqr .outcome)" = delivered ] && [ "$(jq -r --arg i "$ID" 'select(.handoff_id == $i and .phase == "attempt") | .authorized_by.hold | "\(.labels | join(",")) \(.decision | test("live scopes only"))"' "$TMP/state/audit.jsonl")" = "needs-live true" ] \
          && ok || bad "skills#28: needs-live holds no routine handoff (comment, merge); the attempt line records the hold and the decision ($CODE $OUT)"
        sc_draft "deploy under needs-live" '["comment","deploy:acer-swift"]'; sc_send "$AUTH"
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = owner_hold ] && jqr .error.message | grep -q "'needs-live'" && jqr .error.message | grep -q 'deploy:acer-swift' && jqr .error.message | grep -q 'issues/7' && ! grep -q 'agent prompt' "$FAKE_LOG" \
          && ok || bad "skills#28: needs-live holds a live scope (deploy:acer-swift), and the refusal names the label, the issue and the scope ($CODE $OUT)"
        sc_draft "deploy:none under needs-live" '["comment","deploy:none"]'; sc_send "$AUTH"
        [ "$CODE" -eq 0 ] && ok || bad "skills#28: deploy:none is not a live scope ($CODE $OUT)"
        # blocked and needs-decision stay full holds, even for routine actions
        for hold in blocked needs-decision; do
          export FAKE_GH_LABELS="[\"assign:implementer\",\"$hold\"]"
          sc_draft "routine under $hold" '["comment"]'; sc_send "$AUTH"
          [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = owner_hold ] && jqr .error.message | grep -q "'$hold', a full hold" && jqr .error.message | grep -q 'owner removing' && ! grep -q 'agent prompt' "$FAKE_LOG" \
            && ok || bad "skills#28: $hold is a full hold, routine actions too; the refusal names the owner's action ($CODE $OUT)"
        done
        # (2) PR-scoped authorization: the owner's label on the PR authorizes routine actions on exactly that PR at its head
        HEAD28=2828282828282828282828282828282828282828
        PRAUTH='"authorized_by":{"issue_url":"https://github.com/sammasak/skills/pull/90","label":"approved"}'
        export FAKE_GH_LABELS='["approved"]' FAKE_GH_PR_HEAD=$HEAD28
        export FAKE_GH_EVENTS='[{"event":"labeled","label":{"name":"approved"},"actor":{"login":"sammasak"},"created_at":"2026-11-09T10:00:00Z"}]'
        sc_draft "review+merge #90" '["comment","merge"]' ",\"review\":\"sammasak/skills#90@$HEAD28\""; sc_send "$PRAUTH"
        [ "$CODE" -eq 0 ] && [ "$(jqr .outcome)" = delivered ] && [ "$(jqr .authorized_by.pr_scoped)" = true ] && [ "$(jqr .authorized_by.labeled_by)" = sammasak ] && grep -q '^gh api repos/sammasak/skills/pulls/90$' "$FAKE_LOG" \
          && ok || bad "skills#28: the owner's approved on a PR authorizes a review+merge handoff naming that PR at its head ($CODE $OUT)"
        sc_draft "deploy via PR auth" '["comment","deploy:acer-swift"]' ",\"review\":\"sammasak/skills#90@$HEAD28\""; sc_send "$PRAUTH"
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = authorization_missing ] && jqr .error.message | grep -q 'issue-level live authorization' && ! grep -q 'agent prompt' "$FAKE_LOG" \
          && ok || bad "skills#28: a PR-scoped approval refuses deploy:*, naming the missing issue-level live authorization ($CODE $OUT)"
        sc_draft "label via PR auth" '["comment","label"]' ",\"review\":\"sammasak/skills#90@$HEAD28\""; sc_send "$PRAUTH"
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = authorization_missing ] && jqr .error.message | grep -q 'only comment, merge, close and review' && ok || bad "skills#28: a PR-scoped approval authorizes routine actions only ($CODE $OUT)"
        sc_draft "other PR" '["comment"]' ",\"review\":\"sammasak/skills#91@$HEAD28\""; sc_send "$PRAUTH"
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = authorization_missing ] && jqr .error.message | grep -q 'naming that PR and its head' && ok || bad "skills#28: a PR-scoped approval covers exactly that PR ($CODE $OUT)"
        sc_draft "no head named" '["comment"]'; sc_send "$PRAUTH"
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = authorization_missing ] && jqr .error.message | grep -q 'sammasak/skills#90@<head sha>' && ok || bad "skills#28: a PR-scoped approval needs the handoff to name the PR's head ($CODE $OUT)"
        sc_draft "moved head" '["comment"]' ",\"review\":\"sammasak/skills#90@$HEAD77\""; sc_send "$PRAUTH"
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = authorization_missing ] && jqr .error.message | grep -q "at head $HEAD28, not the handoff's $HEAD77" && ok || bad "skills#28: a PR whose head moved is not covered ($CODE $OUT)"
        sc_draft "not the owner's label" '["comment"]' ",\"review\":\"sammasak/skills#90@$HEAD28\""
        FAKE_GH_EVENTS='[{"event":"labeled","label":{"name":"approved"},"actor":{"login":"someone-else"},"created_at":"2026-11-09T10:00:00Z"}]' sc_send "$PRAUTH"
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = authorization_missing ] && jqr .error.message | grep -q "applied by sammasak" && jqr .error.message | grep -q 'someone-else' && ok || bad "skills#28: a PR label not applied by the owner never authorizes, naming who did ($CODE $OUT)"
        jq -cn '{audit_id:"dddddddddddd", phase:"gh", stage:"outcome", task:"gh:label", repo:"sammasak/skills", number:90, label:"approved", action:"add", outcome:"done", at:"2026-11-09T09:00:00Z"}' >> "$TMP/state/audit.jsonl"
        sc_send "$PRAUTH"
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = authorization_missing ] && jqr .error.message | grep -q 'added by the coordinator' && ! grep -q 'agent prompt' "$FAKE_LOG" && ok || bad "skills#28: an approved on a PR that the coordinator added never authorizes (no self-authorization) ($CODE $OUT)"
        unset FAKE_GH_PR_HEAD
        export FAKE_GH_LABELS='["epic","assign:implementer","deployment-ready"]'
        summary
      '';
    };

    "skills:test:tasks:gh-act" = {
      description = "gh:label, gh:comment and gh:issue: bounded targets, handoff-or-reason, canonical Coordinator signature, attempt+outcome audit lines, gh failures as data, never a label that authorizes a send";
      exec = ''
        set +e -uo pipefail   # the task runner enables errexit; these suites inspect exit codes themselves
        ROOT="$DEVENV_ROOT"; cd "$ROOT" || exit 1
        export HERDR_PANE_ID=coord:p0   # the suite runs its tasks from the Coordinator's own pane, never a target
        # hermetic: a devenv.local.nix in the checkout (the coordinator host writes the owner's delegation and panes there)
        # must not reach the suites; the last --option wins, so each case still sets its own
        devenv() { command devenv "$1" "$2" --option coordinator.mayApprove:bool false --option coordinator.approvalDecision:string "" --option coordinator.panes:string "" "''${@:3}"; }
        FX="$ROOT/task-modules/fixtures"; FAKES="${config.coordinator.fakes}/bin"
        TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
        export FAKE_LOG="$TMP/calls.log" FAKE_GH_DIR="$FX/gh" FAKE_GH_COMMENT_OUT="$TMP/comment.txt"
        PASS=0; FAIL=0
        ok() { PASS=$((PASS+1)); }
        bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
        run() { # <task> [args]
          local task="$1"; shift
          devenv tasks run "$task" --option coordinator.herdrCommand:string "$FAKES/herdr" --option coordinator.sshCommand:string "$FAKES/ssh" --option coordinator.locksCommand:string "$FAKES/host-locks" --option coordinator.ghCommand:string "$FAKES/gh" \
            --option coordinator.stateDir:string "$TMP/state" --option coordinator.timeoutSeconds:int 2 --option coordinator.messageTimeoutSeconds:int 3 --show-output "$@" > "$TMP/run.log" 2>&1; CODE=$?
          OUT=$(grep -E "^\s*\{\"(schema_version\":1|task\":\"$task\")" "$TMP/run.log" | grep -F "\"task\":\"$task\"" | tail -1 | sed -E 's/^\s+//'); [ -n "$OUT" ] || OUT='{}'
        }
        jqr() { jq -r "$1" <<<"$OUT"; }
        summary() { echo "passed=$PASS failed=$FAIL"; [ "$FAIL" -eq 0 ]; }
        AUDIT="$TMP/state/audit.jsonl"
        audit_lines() { [ -s "$AUDIT" ] && grep -c . "$AUDIT" || echo 0; }

        # a draft to serve: gh acts may name it instead of a reason
        run coord:handoff --input-json '{"agent_id":"wF:p1","task_ref":"#43","scope":"s","expected_evidence":"e","acceptance":"a","allowed_actions":["comment"]}'
        HID=$(jqr .handoff_id); [[ "$HID" =~ ^[a-f0-9]{12}$ ]] && ok || bad "draft for the gh acts"
        # gh:label add, serving the handoff: one POST through the issues API, one audit line
        : > "$FAKE_LOG"
        run gh:label --input-json "{\"repo\":\"sammasak/skills\",\"number\":43,\"label\":\"blocked\",\"action\":\"add\",\"handoff_id\":\"$HID\"}"
        [ "$CODE" -eq 0 ] && [ "$(jqr .outcome)" = done ] && [ "$(jqr .error)" = null ] && [ "$(jqr .handoff_id)" = "$HID" ] && [ "$(jqr .reason)" = null ] && ok || bad "label add: $CODE $OUT"
        grep -q '^gh api -X POST repos/sammasak/skills/issues/43/labels --input -' "$FAKE_LOG" && [ "$(grep -c '^gh' "$FAKE_LOG")" = 1 ] && ok || bad "label add is one POST ($(cat "$FAKE_LOG"))"
        AID=$(jqr .audit_id); [[ "$AID" =~ ^[a-f0-9]{12}$ ]] && [ "$(audit_lines)" = 2 ] && [ "$(jq -r 'select(.audit_id == "'"$AID"'" and .stage == "attempt") | .phase + " " + .task + " " + .repo + " " + (.number|tostring) + " " + .label + " " + .action + " " + .handoff_id' "$AUDIT")" = "gh gh:label sammasak/skills 43 blocked add $HID" ] \
          && [ "$(jq -r 'select(.audit_id == "'"$AID"'" and .stage == "outcome") | .task + " " + .label + " " + .outcome' "$AUDIT")" = "gh:label blocked done" ] && ok || bad "attempt then outcome audit lines for the label add ($(cat "$AUDIT"))"
        # the attempt line precedes the GitHub write: it is already there when gh runs (gh's call is logged after it was written)
        [ "$(head -1 "$AUDIT" | jq -r .stage)" = attempt ] && ok || bad "attempt line first"
        # skills#28 (3): the coordinator lifts only a hold it added (the add above: attempt + done outcome), citing the evidence
        : > "$FAKE_LOG"; before=$(audit_lines)
        run gh:label --input-json '{"repo":"sammasak/skills","number":43,"label":"needs-live","action":"remove","reason":"live check done","evidence":"https://github.com/sammasak/skills/pull/80"}'
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = owner_hold ] && jqr .error.message | grep -q "the owner removes 'needs-live' from sammasak/skills#43" && [ ! -s "$FAKE_LOG" ] && [ "$(audit_lines)" = "$before" ] \
          && ok || bad "skills#28: an owner-applied hold (no gh:label add in the audit) is not removed; the refusal names the owner's action ($CODE $OUT)"
        for ev in "" '"evidence":"https://github.com/sammasak/skills/issues/43",' '"evidence":"https://example.com/x/pull/1",'; do
          run gh:label --input-json "{\"repo\":\"sammasak/skills\",\"number\":43,\"label\":\"blocked\",\"action\":\"remove\",$ev\"reason\":\"resolved\"}"
          [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = invalid_input ] && jqr .error.message | grep -q 'needs evidence' && [ ! -s "$FAKE_LOG" ] && [ "$(audit_lines)" = "$before" ] \
            && ok || bad "skills#28: removing a hold without a PR/commit evidence URL is refused (${ev:-none}) ($CODE $OUT)"
        done
        run gh:label --input-json '{"repo":"sammasak/skills","number":43,"label":"blocked","action":"remove","reason":"resolved by the merged fix","evidence":"https://github.com/sammasak/skills/commit/0123abc"}'
        [ "$CODE" -eq 0 ] && [ "$(jqr .outcome)" = done ] && [ "$(jqr .evidence)" = "https://github.com/sammasak/skills/commit/0123abc" ] && grep -q '^gh api -X DELETE repos/sammasak/skills/issues/43/labels/blocked$' "$FAKE_LOG" \
          && [ "$(jq -r 'select(.action == "remove" and .stage == "attempt") | .evidence' "$AUDIT")" = "https://github.com/sammasak/skills/commit/0123abc" ] \
          && ok || bad "skills#28: the coordinator removes a hold it added, citing the resolving commit; the audit records the evidence ($CODE $OUT)"
        # refusals before any gh call or audit line: a label outside the three (approved without delegation is its own case below), unknown action, bad target,
        # dot segments, both or neither of handoff_id/reason, unknown draft, long reason
        for bad_in in '{"repo":"sammasak/skills","number":43,"label":"assign:implementer","action":"add","reason":"r"}' '{"repo":"sammasak/skills","number":43,"label":"wontfix","action":"add","reason":"r"}' '{"repo":"sammasak/skills","number":43,"label":"blocked","action":"toggle","reason":"r"}' \
            '{"repo":"skills","number":43,"label":"blocked","action":"add","reason":"r"}' '{"repo":"../skills","number":43,"label":"blocked","action":"add","reason":"r"}' '{"repo":"sammasak/..","number":43,"label":"blocked","action":"add","reason":"r"}' '{"repo":"sammasak/skills","number":"43; rm","label":"blocked","action":"add","reason":"r"}' '{"repo":"sammasak/skills","number":0,"label":"blocked","action":"add","reason":"r"}' \
            "{\"repo\":\"sammasak/skills\",\"number\":43,\"label\":\"blocked\",\"action\":\"add\",\"handoff_id\":\"$HID\",\"reason\":\"r\"}" '{"repo":"sammasak/skills","number":43,"label":"blocked","action":"add"}' \
            '{"repo":"sammasak/skills","number":43,"label":"blocked","action":"add","handoff_id":"000000000000"}' "{\"repo\":\"sammasak/skills\",\"number\":43,\"label\":\"blocked\",\"action\":\"add\",\"reason\":\"$(printf 'r%.0s' $(seq 1 4001))\"}"; do
          : > "$FAKE_LOG"; before=$(audit_lines)
          run gh:label --input-json "$bad_in"
          [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = invalid_input ] && [ ! -s "$FAKE_LOG" ] && [ "$(audit_lines)" = "$before" ] && ok || bad "gh:label refused without gh or audit: $(cut -c1-90 <<<"$bad_in") ($OUT)"
        done
        # gh failing: recorded as data (attempt + outcome lines), non-zero exit, error.kind names it; a hang is a timeout
        : > "$FAKE_LOG"; before=$(audit_lines)
        FAKE_GH_API_EXIT=1 run gh:label --input-json '{"repo":"sammasak/skills","number":43,"label":"needs-decision","action":"add","reason":"r"}'
        [ "$CODE" -ne 0 ] && [ "$(jqr .outcome)" = command_failed ] && [ "$(jqr .error.kind)" = command_failed ] && jqr .error.message | grep -q 'HTTP 404' && [ "$(audit_lines)" = $((before + 2)) ] && [ "$(tail -1 "$AUDIT" | jq -r '.stage + " " + .outcome')" = "outcome command_failed" ] && ok || bad "gh failure recorded ($CODE $OUT)"
        before=$(audit_lines)
        FAKE_GH_SLEEP=5 run gh:label --input-json '{"repo":"sammasak/skills","number":43,"label":"needs-decision","action":"add","reason":"r"}'
        [ "$CODE" -ne 0 ] && [ "$(jqr .outcome)" = timeout ] && [ "$(audit_lines)" = $((before + 2)) ] && [ "$(tail -1 "$AUDIT" | jq -r .outcome)" = timeout ] && ok || bad "gh hang => timeout recorded ($CODE $OUT)"
        # a failed or timed-out add is no proof the coordinator put the hold there
        : > "$FAKE_LOG"
        run gh:label --input-json '{"repo":"sammasak/skills","number":43,"label":"needs-decision","action":"remove","reason":"r","evidence":"https://github.com/sammasak/skills/pull/80"}'
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = owner_hold ] && [ ! -s "$FAKE_LOG" ] && ok || bad "skills#28: an add that failed (command_failed/timeout) does not let the coordinator remove the hold ($CODE $OUT)"
        # gh:comment: body delivered with the Coordinator signature, url in the record and the audit line
        : > "$FAKE_LOG"; rm -f "$FAKE_GH_COMMENT_OUT"
        run gh:comment --input-json "{\"repo\":\"sammasak/skills\",\"number\":43,\"body\":\"Status: wF:p1 is idle; the owner has not decided yet.\",\"handoff_id\":\"$HID\"}"
        [ "$CODE" -eq 0 ] && [ "$(jqr .outcome)" = done ] && [ "$(jqr .comment_url)" = "https://github.com/sammasak/skills/issues/43#issuecomment-1" ] && ok || bad "comment: $CODE $OUT"
        grep -q '^gh api -X POST repos/sammasak/skills/issues/43/comments --input -' "$FAKE_LOG" && ok || bad "comment is one POST"
        [ "$(head -1 "$FAKE_GH_COMMENT_OUT")" = "Status: wF:p1 is idle; the owner has not decided yet." ] && [ "$(tail -1 "$FAKE_GH_COMMENT_OUT")" = "-- Coordinator (automated; not the owner)" ] && ok || bad "comment body signed Coordinator ($(cat "$FAKE_GH_COMMENT_OUT"))"
        [ "$(tail -1 "$AUDIT" | jq -r '.task + " " + .stage + " " + .outcome + " " + .comment_url')" = "gh:comment outcome done https://github.com/sammasak/skills/issues/43#issuecomment-1" ] && [ "$(tail -2 "$AUDIT" | head -1 | jq -r '.task + " " + .stage + " " + .handoff_id')" = "gh:comment attempt $HID" ] && ok || bad "attempt and outcome audit lines for the comment"
        # a caller's own "-- Coordinator" line (short or full) is replaced by the one canonical signature, exactly once
        for pre in 'done\n\n-- Coordinator' 'done\n\n-- Coordinator (automated; not the owner)' 'done\n-- Coordinator\n\n-- Coordinator (automated; not the owner)\n'; do
          run gh:comment --input-json "{\"repo\":\"sammasak/skills\",\"number\":43,\"body\":\"$pre\",\"reason\":\"r\"}"
          [ "$CODE" -eq 0 ] && [ "$(grep -c 'Coordinator' "$FAKE_GH_COMMENT_OUT")" = 1 ] && [ "$(printf '%s' "$(cat "$FAKE_GH_COMMENT_OUT")")" = "$(printf 'done\n\n-- Coordinator (automated; not the owner)')" ] && ok || bad "canonical signature once for '$pre' ($(cat "$FAKE_GH_COMMENT_OUT"))"
        done
        # gh:issue: one issue in an owner repo, signed body, labels only from the issue vocabulary, audited attempt+outcome
        export FAKE_GH_ISSUE_OUT="$TMP/issue.json"; : > "$FAKE_LOG"; before=$(audit_lines)
        run gh:issue --input-json '{"repo":"sammasak/skills","title":"Coordinator: a new item","body":"What and why.","labels":["enhancement"],"reason":"found in triage"}'
        [ "$CODE" -eq 0 ] && [ "$(jqr '"\(.outcome) \(.number) \(.issue_url) \(.labels | join(","))"')" = "done 99 https://github.com/sammasak/skills/issues/99 enhancement" ] && ok || bad "issue: created, the record has the url and number ($CODE $OUT)"
        [ "$(grep -c '^gh api' "$FAKE_LOG")" = 2 ] && grep -q '^gh api repos/sammasak/skills/issues?state=open&per_page=100$' "$FAKE_LOG" && grep -q '^gh api -X POST repos/sammasak/skills/issues --input -$' "$FAKE_LOG" && ok || bad "issue: one open-issue read, then one POST ($(cat "$FAKE_LOG"))"
        [ "$(jq -r '"\(.title)|\(.labels | join(","))"' "$FAKE_GH_ISSUE_OUT")" = "Coordinator: a new item|enhancement" ] && [ "$(jq -r .body "$FAKE_GH_ISSUE_OUT" | tail -1)" = "-- Coordinator (automated; not the owner)" ] && [ "$(jq -r .body "$FAKE_GH_ISSUE_OUT" | head -1)" = "What and why." ] && ok || bad "issue: the request carries title, labels and the signed body ($(cat "$FAKE_GH_ISSUE_OUT"))"
        IAID=$(jqr .audit_id); [ "$(audit_lines)" = $((before + 2)) ] && [ "$(jq -r --arg a "$IAID" 'select(.audit_id == $a) | "\(.task) \(.stage) \(.repo) \(.title) \(.reason)"' "$AUDIT" | paste -sd'|')" = "gh:issue attempt sammasak/skills Coordinator: a new item found in triage|gh:issue outcome sammasak/skills Coordinator: a new item null" ] && [ "$(tail -1 "$AUDIT" | jq -r '"\(.outcome) \(.issue_url)"')" = "done https://github.com/sammasak/skills/issues/99" ] && ok || bad "issue: attempt and outcome audit lines ($(tail -2 "$AUDIT"))"
        # refusals before any gh call or audit line: an authorizing label, a label outside the vocabulary, another owner's
        # repo, a number, an empty, multi-line or long title, a long body, too many labels, both or neither of handoff_id/reason
        : > "$FAKE_LOG"; before=$(audit_lines)
        run gh:issue --input-json '{"repo":"sammasak/skills","title":"t","body":"b","labels":["approved"],"reason":"r"}'
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = invalid_input ] && jqr .error.message | grep -q 'authorizes a send' && ok || bad "issue: never an authorizing label ($CODE $OUT)"
        L5='"labels":["enhancement","blocked","needs-live","needs-decision","enhancement"]'
        for bad_in in '{"repo":"sammasak/skills","title":"t","body":"b","labels":["wontfix"],"reason":"r"}' '{"repo":"someone-else/skills","title":"t","body":"b","reason":"r"}' '{"repo":"sammasak/skills","number":5,"title":"t","body":"b","reason":"r"}' \
            '{"repo":"sammasak/skills","title":"","body":"b","reason":"r"}' '{"repo":"sammasak/skills","title":"two\nlines","body":"b","reason":"r"}' "{\"repo\":\"sammasak/skills\",\"title\":\"$(printf 't%.0s' $(seq 1 257))\",\"body\":\"b\",\"reason\":\"r\"}" \
            "{\"repo\":\"sammasak/skills\",\"title\":\"t\",\"body\":\"$(printf 'b%.0s' $(seq 1 8001))\",\"reason\":\"r\"}" "{\"repo\":\"sammasak/skills\",\"title\":\"t\",\"body\":\"b\",$L5,\"reason\":\"r\"}" '{"repo":"sammasak/skills","title":"t","body":"b","labels":"enhancement","reason":"r"}' \
            "{\"repo\":\"sammasak/skills\",\"title\":\"t\",\"body\":\"b\",\"handoff_id\":\"$HID\",\"reason\":\"r\"}" '{"repo":"sammasak/skills","title":"t","body":"b"}'; do
          run gh:issue --input-json "$bad_in"
          [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = invalid_input ] && ok || bad "issue: refused $bad_in ($CODE $(jqr .error.message))"
        done
        [ ! -s "$FAKE_LOG" ] && [ "$(audit_lines)" = "$before" ] && ok || bad "issue: no refusal reached gh or the audit log ($(cat "$FAKE_LOG"))"
        # an open issue with the same title: refused after the one read, nothing created, nothing audited
        FAKE_GH_OPEN_ISSUES='[{"number":12,"title":"Coordinator: a new item"},{"number":13,"title":"Coordinator: a new item","pull_request":{}}]' run gh:issue --input-json '{"repo":"sammasak/skills","title":"Coordinator: a new item","body":"b","reason":"r"}'
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = duplicate ] && jqr .error.message | grep -q 'sammasak/skills#12' && ! grep -q POST "$FAKE_LOG" && [ "$(audit_lines)" = "$before" ] && ok || bad "issue: a duplicate open title is refused ($CODE $OUT)"
        FAKE_GH_OPEN_ISSUES='[{"number":13,"title":"Coordinator: a PR, not an issue","pull_request":{}}]' run gh:issue --input-json '{"repo":"sammasak/skills","title":"Coordinator: a PR, not an issue","body":"b","reason":"r"}'
        [ "$CODE" -eq 0 ] && [ "$(jqr .outcome)" = done ] && ok || bad "issue: an open PR with the same title is not a duplicate issue ($CODE $OUT)"
        # gh failing: the list read refuses before any audit line; the create failing is recorded, never retried
        before=$(audit_lines)
        FAKE_GH_API_EXIT=1 run gh:issue --input-json '{"repo":"sammasak/skills","title":"t2","body":"b","reason":"r"}'
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = command_failed ] && [ "$(audit_lines)" = "$before" ] && ok || bad "issue: a failed open-issue read creates nothing and audits nothing ($CODE $OUT)"
        FAKE_GH_POST_ISSUE_EXIT=1 run gh:issue --input-json '{"repo":"sammasak/skills","title":"t3","body":"b","reason":"r"}'
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = command_failed ] && [ "$(audit_lines)" = $((before + 2)) ] && [ "$(tail -1 "$AUDIT" | jq -r '.task + " " + .outcome')" = "gh:issue command_failed" ] && ok || bad "issue: a failed create is recorded ($CODE $OUT)"
        FAKE_GH_ISSUE_RAW='{}' run gh:issue --input-json '{"repo":"sammasak/skills","title":"t4","body":"b","reason":"r"}'
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = malformed ] && ok || bad "issue: an answer without url or number is malformed, not done ($CODE $OUT)"
        unset FAKE_GH_ISSUE_OUT
        # gh failing or answering without a url: recorded, not retried, error.kind says which
        before=$(audit_lines)
        FAKE_GH_API_EXIT=1 run gh:comment --input-json '{"repo":"sammasak/skills","number":43,"body":"x","reason":"r"}'
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = command_failed ] && [ "$(audit_lines)" = $((before + 2)) ] && ok || bad "comment gh failure recorded ($CODE $OUT)"
        FAKE_GH_COMMENT_RAW='{}' run gh:comment --input-json '{"repo":"sammasak/skills","number":43,"body":"x","reason":"r"}'
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = malformed ] && jqr .error.message | grep -q 'may or may not exist' && [ "$(tail -1 "$AUDIT" | jq -r .outcome)" = malformed ] && ok || bad "comment without html_url => malformed ($CODE $OUT)"
        # a 4000-character body passes, 4001 and empty do not, nothing posted
        LONG=$(printf 'b%.0s' $(seq 1 4000))
        run gh:comment --input-json "{\"repo\":\"sammasak/skills\",\"number\":43,\"body\":\"$LONG\",\"reason\":\"r\"}"
        [ "$CODE" -eq 0 ] && [ "$(jqr .body_chars)" -gt 4000 ] && ok || bad "4000-character body accepted ($CODE)"
        for bad_in in "{\"repo\":\"sammasak/skills\",\"number\":43,\"body\":\"''${LONG}b\",\"reason\":\"r\"}" '{"repo":"sammasak/skills","number":43,"body":"","reason":"r"}' '{"repo":"sammasak/skills","number":43,"reason":"r"}' '{"repo":"sammasak/skills","number":43,"body":"x"}'; do
          : > "$FAKE_LOG"; before=$(audit_lines)
          run gh:comment --input-json "$bad_in"
          [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = invalid_input ] && [ ! -s "$FAKE_LOG" ] && [ "$(audit_lines)" = "$before" ] && ok || bad "gh:comment refused without gh or audit: $(cut -c1-60 <<<"$bad_in") ($OUT)"
        done
        # the shared audit log stays readable by herdr:message after gh lines were written; a label the coordinator wrote (blocked, above)
        # cannot authorize the send even though it is on the issue, and neither can one a hand-written gh line says the coordinator added
        export FAKE_HERDR_STATE=idle FAKE_HERDR_SEQ=5 FAKE_HERDR_SESSION=sess-1 FAKE_GH_LABELS='["blocked","approved","assign:implementer"]'
        H=$(hostname -s 2>/dev/null || hostname); : > "$FAKE_LOG"
        run herdr:message --input-json "{\"handoff_id\":\"$HID\",\"confirm\":\"$H/wF:p1\",\"authorized_by\":{\"issue_url\":\"https://github.com/sammasak/skills/issues/43\",\"label\":\"blocked\"}}"
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = authorization_missing ] && jqr .error.message | grep -q 'writes itself' && [ ! -s "$FAKE_LOG" ] && ok || bad "a gh:label label cannot authorize a send ($OUT)"
        echo '{"audit_id":"aaaaaaaaaaaa","phase":"gh","stage":"outcome","task":"gh:label","repo":"sammasak/skills","number":43,"label":"approved","action":"add","outcome":"done","at":"2026-10-27T00:00:00Z"}' >> "$AUDIT"
        run herdr:message --input-json "{\"handoff_id\":\"$HID\",\"confirm\":\"$H/wF:p1\",\"authorized_by\":{\"issue_url\":\"https://github.com/sammasak/skills/issues/43\",\"label\":\"approved\"}}"
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = authorization_missing ] && jqr .error.message | grep -q 'added by the coordinator' && [ ! -s "$FAKE_LOG" ] && ok || bad "a label the audit log shows the coordinator added cannot authorize ($OUT)"
        FAKE_GH_LABELS='["approved","assign:implementer"]' run herdr:message --input-json "{\"handoff_id\":\"$HID\",\"confirm\":\"$H/wF:p1\",\"authorized_by\":{\"issue_url\":\"https://github.com/sammasak/skills/issues/43\",\"label\":\"assign:implementer\"}}"
        [ "$CODE" -eq 0 ] && [ "$(jqr .outcome)" = delivered ] && ok || bad "herdr:message accepts an audit log with gh lines ($CODE $OUT)"
        # --- delegated approval (the owner's decision, skills#28 comment 6629911996): approved is writable only under
        #     coordinator.mayApprove, on an issue of the owner's repos that carries no owner hold, never on a PR; the act cites
        #     the decision in both audit lines, and only such a line lets the send gate accept a coordinator-added approved
        DEC='https://github.com/sammasak/skills/issues/28#issuecomment-6629911996'
        DELEG=(--option coordinator.mayApprove:bool true --option coordinator.approvalDecision:string "$DEC")
        APPROVE='{"repo":"sammasak/skills","number":44,"label":"approved","action":"add","reason":"fits a worker: no live hardware"}'
        export FAKE_GH_LABELS='["enhancement"]'; unset FAKE_GH_ISSUE_IS_PR
        : > "$FAKE_LOG"; before=$(audit_lines)
        run gh:label --input-json "$APPROVE"
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = not_delegated ] && [ ! -s "$FAKE_LOG" ] && [ "$(audit_lines)" = "$before" ] && ok || bad "approve: refused when delegation is off (the default) ($CODE $OUT)"
        run gh:label --option coordinator.approvalDecision:string "$DEC" --input-json "$APPROVE"
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = not_delegated ] && jqr .error.message | grep -q 'mayApprove is off' && [ ! -s "$FAKE_LOG" ] && [ "$(audit_lines)" = "$before" ] && ok || bad "approve: refused when the flag is off even with a decision reference configured ($CODE $OUT)"
        run gh:label --option coordinator.mayApprove:bool true --input-json "$APPROVE"
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = not_delegated ] && [ ! -s "$FAKE_LOG" ] && [ "$(audit_lines)" = "$before" ] && ok || bad "approve: refused when the flag is on but no decision reference is configured ($CODE $OUT)"
        run gh:label "''${DELEG[@]}" --input-json '{"repo":"someone-else/skills","number":44,"label":"approved","action":"add","reason":"r"}'
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = not_delegated ] && [ ! -s "$FAKE_LOG" ] && [ "$(audit_lines)" = "$before" ] && ok || bad "approve: refused outside the owner's repositories ($CODE $OUT)"
        run gh:label "''${DELEG[@]}" --input-json '{"repo":"sammasak/skills","number":44,"label":"approved","action":"remove","reason":"r"}'
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = invalid_input ] && [ ! -s "$FAKE_LOG" ] && [ "$(audit_lines)" = "$before" ] && ok || bad "approve: removing approved is refused ($CODE $OUT)"
        : > "$FAKE_LOG"; FAKE_GH_ISSUE_IS_PR=1 run gh:label "''${DELEG[@]}" --input-json "$APPROVE"
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = invalid_input ] && [ "$(grep -c '^gh api' "$FAKE_LOG")" = 1 ] && ! grep -q POST "$FAKE_LOG" && [ "$(audit_lines)" = "$before" ] && ok || bad "approve: refused on a PR after one read, nothing written ($CODE $OUT $(cat "$FAKE_LOG"))"
        for hold in needs-live blocked needs-decision; do
          : > "$FAKE_LOG"; FAKE_GH_LABELS="[\"enhancement\",\"$hold\"]" run gh:label "''${DELEG[@]}" --input-json "$APPROVE"
          [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = owner_hold ] && jqr .error.message | grep -q "$hold" && ! grep -q POST "$FAKE_LOG" && [ "$(audit_lines)" = "$before" ] && ok || bad "approve: refused on an issue carrying $hold ($CODE $OUT)"
        done
        : > "$FAKE_LOG"; run gh:label --option coordinator.mayApprove:bool true --option coordinator.approvalDecision:string 'https://github.com/someone-else/x/issues/1#issuecomment-5' --input-json "$APPROVE"
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = not_delegated ] && [ ! -s "$FAKE_LOG" ] && [ "$(audit_lines)" = "$before" ] && ok || bad "approve: refused when the decision reference is outside the owner's repositories ($CODE $OUT)"
        : > "$FAKE_LOG"; FAKE_GH_ISSUE_USER=someone-else run gh:label "''${DELEG[@]}" --input-json "$APPROVE"
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = not_delegated ] && jqr .error.message | grep -q "not the owner's" && ! grep -q POST "$FAKE_LOG" && [ "$(audit_lines)" = "$before" ] && ok || bad "approve: refused on an issue someone else wrote (public repos accept issues from anyone) ($CODE $OUT)"
        : > "$FAKE_LOG"; FAKE_GH_ISSUE_STATE=closed run gh:label "''${DELEG[@]}" --input-json "$APPROVE"
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = invalid_input ] && jqr .error.message | grep -q 'not open' && ! grep -q POST "$FAKE_LOG" && [ "$(audit_lines)" = "$before" ] && ok || bad "approve: refused on a closed issue ($CODE $OUT)"
        : > "$FAKE_LOG"; run gh:label "''${DELEG[@]}" --input-json "$APPROVE"
        [ "$CODE" -eq 0 ] && [ "$(jqr .outcome)" = done ] && [ "$(jqr '.owner_delegation | "\(.may_approve) \(.decision) \(.author)"')" = "true $DEC sammasak" ] && ok || bad "approve: allowed when delegated, the record cites the decision and the issue's author ($CODE $OUT)"
        grep -q '^gh api repos/sammasak/skills/issues/44$' "$FAKE_LOG" && grep -q '^gh api -X POST repos/sammasak/skills/issues/44/labels --input -' "$FAKE_LOG" && [ "$(grep -c '^gh' "$FAKE_LOG")" = 2 ] && ok || bad "approve: one issue read, then one POST ($(cat "$FAKE_LOG"))"
        APP_AID=$(jqr .audit_id); [ "$(audit_lines)" = $((before + 2)) ] && [ "$(jq -r --arg a "$APP_AID" 'select(.audit_id == $a) | "\(.stage) \(.label) \(.action) \(.owner_delegation.may_approve) \(.owner_delegation.decision) \(.owner_delegation.author)"' "$AUDIT" | paste -sd'|')" = "attempt approved add true $DEC sammasak|outcome approved add true $DEC sammasak" ] && ok || bad "approve: attempt and outcome audit lines both carry owner_delegation ($(tail -2 "$AUDIT"))"
        # the send gate: the delegated approved authorizes, and the record says so (applied_by, the gh:label audit_id)
        run coord:handoff --input-json '{"agent_id":"wF:p1","task_ref":"#44","scope":"s","expected_evidence":"e","acceptance":"a","allowed_actions":["comment"]}'
        H44=$(jqr .handoff_id)
        export FAKE_GH_LABELS='["enhancement","approved"]'; : > "$FAKE_LOG"
        A44="{\"handoff_id\":\"$H44\",\"confirm\":\"$H/wF:p1\",\"authorized_by\":{\"issue_url\":\"https://github.com/sammasak/skills/issues/44\",\"label\":\"approved\"}}"
        # the owner's brakes reach the send gate: a hold added after the approval, the delegation withdrawn (flag off, or the
        # decision changed) and an issue that is not the owner's all refuse a coordinator-delegated label, nothing sent
        FAKE_GH_LABELS='["enhancement","approved","blocked"]' run herdr:message "''${DELEG[@]}" --input-json "$A44"
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = owner_hold ] && jqr .error.message | grep -q blocked && ! grep -q '^herdr' "$FAKE_LOG" && ok || bad "send: a hold added after a delegated approval stops the send ($CODE $OUT)"
        run herdr:message --input-json "$A44"
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = not_delegated ] && jqr .error.message | grep -q withdrawn && ! grep -q '^herdr' "$FAKE_LOG" && ok || bad "send: delegation switched off withdraws earlier delegated approvals ($CODE $OUT)"
        run herdr:message --option coordinator.mayApprove:bool true --option coordinator.approvalDecision:string 'https://github.com/sammasak/skills/issues/28#issuecomment-1' --input-json "$A44"
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = not_delegated ] && jqr .error.message | grep -q withdrawn && ! grep -q '^herdr' "$FAKE_LOG" && ok || bad "send: a changed decision reference withdraws earlier delegated approvals ($CODE $OUT)"
        FAKE_GH_ISSUE_USER=someone-else run herdr:message "''${DELEG[@]}" --input-json "$A44"
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = not_delegated ] && jqr .error.message | grep -q "not the owner's" && ! grep -q '^herdr' "$FAKE_LOG" && ok || bad "send: a delegated label on an issue that is not the owner's never authorizes ($CODE $OUT)"
        : > "$FAKE_LOG"; run herdr:message "''${DELEG[@]}" --input-json "$A44"
        [ "$CODE" -eq 0 ] && [ "$(jqr .outcome)" = delivered ] && [ "$(jqr '.authorized_by | "\(.verified) \(.applied_by) \(.delegation_audit_id) \(.owner_delegation.decision)"')" = "true coordinator-delegated $APP_AID $DEC" ] && grep -q '^gh api repos/sammasak/skills/issues/44$' "$FAKE_LOG" && ok || bad "send: a delegated approved authorizes while the delegation is in force, the issue is the owner's and carries no hold; applied_by coordinator-delegated with the gh:label audit_id ($CODE $OUT $(grep '^gh' "$FAKE_LOG" | tr '\n' ' '))"
        [ "$(jq -r --arg h "$H44" 'select(.handoff_id == $h and .phase == "attempt") | .authorized_by.applied_by + " " + .authorized_by.delegation_audit_id' "$AUDIT")" = "coordinator-delegated $APP_AID" ] && ok || bad "send: the attempt audit line records the delegation chain ($(grep "$H44" "$AUDIT" | head -1))"
        # an owner-applied label still reads applied_by owner; a delegated needs-decision and a malformed delegation never authorize
        run coord:handoff --input-json '{"agent_id":"wF:p1","task_ref":"#45","scope":"s","expected_evidence":"e","acceptance":"a","allowed_actions":["comment"]}'
        H45=$(jqr .handoff_id)
        echo "{\"audit_id\":\"bbbbbbbbbbbb\",\"phase\":\"gh\",\"stage\":\"outcome\",\"task\":\"gh:label\",\"repo\":\"sammasak/skills\",\"number\":45,\"label\":\"needs-decision\",\"action\":\"add\",\"outcome\":\"done\",\"at\":\"2026-11-04T00:00:00Z\",\"owner_delegation\":{\"may_approve\":true,\"decision\":\"$DEC\"}}" >> "$AUDIT"
        echo "{\"audit_id\":\"cccccccccccc\",\"phase\":\"gh\",\"stage\":\"outcome\",\"task\":\"gh:label\",\"repo\":\"sammasak/skills\",\"number\":45,\"label\":\"approved\",\"action\":\"add\",\"outcome\":\"done\",\"at\":\"2026-11-04T00:00:00Z\",\"owner_delegation\":{\"may_approve\":true}}" >> "$AUDIT"
        export FAKE_GH_LABELS='["epic","needs-decision","approved"]'; : > "$FAKE_LOG"
        run herdr:message --input-json "{\"handoff_id\":\"$H45\",\"confirm\":\"$H/wF:p1\",\"authorized_by\":{\"issue_url\":\"https://github.com/sammasak/skills/issues/45\",\"label\":\"needs-decision\"}}"
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = authorization_missing ] && jqr .error.message | grep -q 'writes itself' && [ ! -s "$FAKE_LOG" ] && ok || bad "send: a delegated needs-decision is still refused ($OUT)"
        run herdr:message --input-json "{\"handoff_id\":\"$H45\",\"confirm\":\"$H/wF:p1\",\"authorized_by\":{\"issue_url\":\"https://github.com/sammasak/skills/issues/45\",\"label\":\"approved\"}}"
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = authorization_missing ] && jqr .error.message | grep -q 'added by the coordinator' && [ ! -s "$FAKE_LOG" ] && ok || bad "send: a coordinator-added approved whose delegation lacks the decision is refused ($OUT)"
        FAKE_GH_LABELS='["epic","approved"]' run herdr:message --input-json "{\"handoff_id\":\"$H45\",\"confirm\":\"$H/wF:p1\",\"authorized_by\":{\"issue_url\":\"https://github.com/sammasak/skills/issues/45\",\"label\":\"epic\"}}"
        [ "$CODE" -eq 0 ] && [ "$(jqr '.authorized_by | "\(.applied_by) \(.delegation_audit_id)"')" = "owner null" ] && ok || bad "send: an owner-applied label reads applied_by owner ($CODE $OUT)"
        run coord:handoff --input-json '{"agent_id":"wF:p1","task_ref":"#46","scope":"s","expected_evidence":"e","acceptance":"a","allowed_actions":["comment"]}'
        H46=$(jqr .handoff_id)
        echo "{\"audit_id\":\"dddddddddddd\",\"phase\":\"gh\",\"stage\":\"outcome\",\"task\":\"gh:label\",\"repo\":\"sammasak/skills\",\"number\":46,\"label\":\"epic\",\"action\":\"add\",\"outcome\":\"done\",\"at\":\"2026-11-04T00:00:00Z\",\"owner_delegation\":{\"may_approve\":true,\"decision\":\"$DEC\"}}" >> "$AUDIT"
        export FAKE_GH_LABELS='["epic"]'; : > "$FAKE_LOG"
        run herdr:message --input-json "{\"handoff_id\":\"$H46\",\"confirm\":\"$H/wF:p1\",\"authorized_by\":{\"issue_url\":\"https://github.com/sammasak/skills/issues/46\",\"label\":\"epic\"}}"
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = authorization_missing ] && jqr .error.message | grep -q 'added by the coordinator' && [ ! -s "$FAKE_LOG" ] && ok || bad "send: a delegated line for a label that is not an authorizing one never authorizes ($OUT)"
        # a corrupt audit log stops gh acts too
        echo 'not json' >> "$AUDIT"; : > "$FAKE_LOG"
        run gh:label --input-json '{"repo":"sammasak/skills","number":43,"label":"blocked","action":"remove","reason":"r"}'
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = audit_corrupt ] && [ ! -s "$FAKE_LOG" ] && ok || bad "corrupt audit refuses gh acts ($OUT)"
        summary
      '';
    };
    "skills:test:tasks:evidence" = {
      description = "gh:work for one repo, git:recent for one checkout, gh:repos for the owner's portfolio, over fakes";
      exec = ''
        set +e -uo pipefail   # the task runner enables errexit; these suites inspect exit codes themselves
        ROOT="$DEVENV_ROOT"; cd "$ROOT" || exit 1
        export HERDR_PANE_ID=coord:p0   # the suite runs its tasks from the Coordinator's own pane, never a target
        # hermetic: a devenv.local.nix in the checkout (the coordinator host writes the owner's delegation and panes there)
        # must not reach the suites; the last --option wins, so each case still sets its own
        devenv() { command devenv "$1" "$2" --option coordinator.mayApprove:bool false --option coordinator.approvalDecision:string "" --option coordinator.panes:string "" "''${@:3}"; }
        FX="$ROOT/task-modules/fixtures"; FAKES="${config.coordinator.fakes}/bin"
        TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
        export FAKE_LOG="$TMP/calls.log" FAKE_GH_DIR="$FX/gh"
        PASS=0; FAIL=0
        ok() { PASS=$((PASS+1)); }
        bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
        run() { # <task> [args]
          local task="$1"; shift
          devenv tasks run "$task" --option coordinator.herdrCommand:string "$FAKES/herdr" --option coordinator.sshCommand:string "$FAKES/ssh" --option coordinator.locksCommand:string "$FAKES/host-locks" --option coordinator.ghCommand:string "$FAKES/gh" \
            --option coordinator.stateDir:string "$TMP/state" --option coordinator.timeoutSeconds:int 2 --option coordinator.messageTimeoutSeconds:int 3 --show-output "$@" > "$TMP/run.log" 2>&1; CODE=$?
          OUT=$(grep -E "^\s*\{\"(schema_version\":1|task\":\"$task\")" "$TMP/run.log" | grep -F "\"task\":\"$task\"" | tail -1 | sed -E 's/^\s+//'); [ -n "$OUT" ] || OUT='{}'
        }
        jqr() { jq -r "$1" <<<"$OUT"; }
        summary() { echo "passed=$PASS failed=$FAIL"; [ "$FAIL" -eq 0 ]; }

        run gh:work --input-json '{"repo":"sammasak/skills"}'
        [ "$CODE" -eq 0 ] && [ "$(jqr '.issues|length')" = 2 ] && [ "$(jqr '.prs|length')" -ge 4 ] && [ "$(jqr .open_pr_count)" = 1 ] && ok || bad "gh:work: $CODE $OUT"
        [ "$(jqr '.prs[] | select(.number==15) | .closes[0]')" = 42 ] && ok || bad "gh:work: closes mapped"
        [ "$(jqr .truncated)" = false ] && [ "$(jqr .limit)" = 20 ] && [ "$(jqr '.truncated_lists|length')" = 0 ] && ok || bad "gh:work: below the limit nothing is truncated ($OUT)"
        # at the limit gh may have cut the list: say so, name the lists, keep the records (fixture: 2 issues, 1 open PR, 4 merged PRs)
        run gh:work --option coordinator.ghLimit:int 2 --input-json '{"repo":"sammasak/skills"}'
        [ "$CODE" -eq 0 ] && [ "$(jqr .truncated)" = true ] && [ "$(jqr .limit)" = 2 ] && [ "$(jqr '.truncated_lists|join(",")')" = "issues,merged_prs" ] && [ "$(jqr '.issues|length')" = 2 ] && [ "$(jqr '.prs|length')" = 3 ] && ok || bad "gh:work: truncation flagged per list at the limit ($OUT)"
        grep -q -- '--limit 2' "$FAKE_LOG" && ok || bad "gh:work: the limit reaches gh"
        run gh:work --input-json '{"repo":"sammasak/skills; id"}'
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = invalid_input ] && ok || bad "gh:work: unsafe repo rejected"
        FAKE_GH_EXIT=1 run gh:work --input-json '{"repo":"sammasak/skills"}'
        [ "$CODE" -eq 0 ] && [ "$(jqr .error.kind)" = gh_error ] && jqr .error.message | grep -q 'Bad credentials' && ok || bad "gh:work: gh failure is data and keeps gh's own message ($CODE $OUT)"
        git init -q "$TMP/repo" && (cd "$TMP/repo" && git config user.email t@t && git config user.name t && echo a > a && git add a && git commit -qm init && echo b > b)
        run git:recent --input-json "{\"checkout\":\"$TMP/repo\"}"
        [ "$CODE" -eq 0 ] && [ "$(jqr .dirty_files)" = 1 ] && [ "$(jqr '.commits|length')" = 1 ] && [ "$(jqr .repo)" = repo ] && ok || bad "git:recent: $CODE $OUT"
        run git:recent --input-json "{\"checkout\":\"$TMP/none\"}"
        [ "$CODE" -eq 0 ] && [ "$(jqr .error.kind)" = not_found ] && ok || bad "git:recent: missing checkout is data"
        run git:recent --input-json '{"checkout":"relative/path"}'
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = invalid_input ] && ok || bad "git:recent: relative path rejected"
        run git:recent --input-json "{\"checkout\":\"$TMP/../$(basename "$TMP")/repo\"}"
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = invalid_input ] && ok || bad "git:recent: .. rejected"
        # gh:repos: the owner's portfolio in one GraphQL call; projected, sorted by push, archived excluded, capped, failures as data
        # fixture nodes carry issue_labels (one label list per open issue); the fake counts them against the labels[] the
        # query sends, so approved_issues is only right when the list variable really reaches gh
        export FAKE_GH_REPOS='[{"name":"skills","pushedAt":"2026-11-03T10:18:03Z","isArchived":false,"isPrivate":false,"pullRequests":{"totalCount":1},"issues":{"totalCount":4},"issue_labels":[["approved"],["approved","epic"],["epic"],[]]},{"name":"nixos-config","pushedAt":"2026-11-03T11:19:56Z","isArchived":false,"isPrivate":false,"pullRequests":{"totalCount":2},"issues":{"totalCount":12},"issue_labels":[["bug"],["needs-decision"]]},{"name":"labelled-only","pushedAt":"2026-10-20T00:00:00Z","isArchived":false,"isPrivate":true,"pullRequests":{"totalCount":0},"issues":{"totalCount":1},"issue_labels":[["approved"]]},{"name":"quiet","pushedAt":"2026-10-01T00:00:00Z","isArchived":false,"isPrivate":true,"pullRequests":{"totalCount":0},"issues":{"totalCount":3},"issue_labels":[["bug"],[],["blocked"]]},{"name":"old-thing","pushedAt":"2026-11-02T00:00:00Z","isArchived":true,"isPrivate":true,"pullRequests":{"totalCount":9},"issues":{"totalCount":9},"issue_labels":[["approved"]]}]'
        : > "$FAKE_LOG"; run gh:repos
        [ "$CODE" -eq 0 ] && [ "$(jqr .owner)" = sammasak ] && [ "$(jqr '.repos|length')" = 4 ] && [ "$(jqr '[.repos[].name] | join(",")')" = "nixos-config,skills,labelled-only,quiet" ] && ok || bad "gh:repos: projection sorted by pushed_at ($OUT)"
        # the blocker from the #38 re-review: the label list must reach GitHub as a list, or every count reads 0
        [ "$(jqr '.repos[] | select(.name=="labelled-only") | "\(.open_prs) \(.approved_issues) \(.active)"')" = "0 1 true" ] && ok || bad "gh:repos: a repo with only a labelled issue is active (labels[] reached gh as a list) ($OUT)"
        grep -q -- "-F labels\[\]=approved" "$FAKE_LOG" && ! grep -q -- "-f labels=" "$FAKE_LOG" && ok || bad "gh:repos: labels sent as repeated -F labels[]=, never as one -f string ($(grep -o 'labels[^ ]*' "$FAKE_LOG" | paste -sd' '))"
        [ "$(jqr '[.repos[].name] | index("old-thing")')" = null ] && ok || bad "gh:repos: archived repo excluded even when the server returns it"
        [ "$(jqr '.repos[] | select(.name=="skills") | "\(.repo) \(.open_prs) \(.open_issues) \(.approved_issues) \(.active) \(.private)"')" = "sammasak/skills 1 4 2 true false" ] && [ "$(jqr '.repos[] | select(.name=="quiet") | .active')" = false ] && ok || bad "gh:repos: counts and active flag ($OUT)"
        [ "$(jqr .truncated)" = false ] && [ "$(jqr .total)" = 5 ] && [ "$(jqr .listed)" = 4 ] && [ "$(jqr .limit)" = 20 ] && ok || bad "gh:repos: below the cap nothing is truncated ($OUT)"
        grep -q -- '-F owner=sammasak' "$FAKE_LOG" && grep -q -- '-F n=20' "$FAKE_LOG" && [ "$(grep -c '^gh ' "$FAKE_LOG")" = 2 ] && grep -q '^gh search issues --owner sammasak --label approved --state open --archived=false --limit 100 --json repository,number,title,url$' "$FAKE_LOG" && ok || bad "gh:repos: exactly two gh calls, the GraphQL page (owner and cap reach it) and one issue search per authorizing label, archived repos excluded ($(cat "$FAKE_LOG"))"
        [ "$(jqr '.search | "\(.error) \(.found) \(.repos_added | length)"')" = "null 0 0" ] && ok || bad "gh:repos: an empty search adds nothing and is not an error ($(jqr .search))"
        run gh:repos --option coordinator.mayApprove:bool true
        [ "$CODE" -eq 0 ] && [ "$(jqr '[.repos[] | select(.open_prs == 0 and .approved_issues == 0 and .open_issues > 0)] | length > 0 and all(.active)')" = true ] && [ "$(jqr '[.repos[] | select(.open_issues == 0 and .open_prs == 0)] | all(.active | not)')" = true ] && ok || bad "gh:repos: under the delegation a repo with open issues is active, one with none is not ($(jqr '[.repos[] | {name, open_issues, active}]'))"
        grep -q 'labels:$labels' "$FAKE_LOG" && [ "$(jqr '.authorizing_labels|join(",")')" = approved ] && ok || bad "gh:repos: the query uses the $labels variable and the record echoes the configured list ($(grep -o 'labels[^ ]*' "$FAKE_LOG" | head -2 | paste -sd' '))"
        # the cap holds even when the server ignores first:n and returns the whole list (client-side .[:limit])
        FAKE_GH_IGNORE_N=1 run gh:repos --option coordinator.ghLimit:int 2
        [ "$CODE" -eq 0 ] && [ "$(jqr '.repos|length')" = 2 ] && [ "$(jqr '.listed')" = 2 ] && [ "$(jqr .truncated)" = true ] && ok || bad "gh:repos: client-side cap holds against a server that ignores n ($OUT)"
        run gh:repos --option coordinator.ghLimit:int 2
        [ "$CODE" -eq 0 ] && [ "$(jqr '[.repos[].name] | join(",")')" = "nixos-config,skills" ] && [ "$(jqr .truncated)" = true ] && [ "$(jqr .total)" = 5 ] && ok || bad "gh:repos: capped at the limit and flagged truncated ($OUT)"
        run gh:repos --input-json '{"limit":101}'
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = invalid_input ] && jqr .error.message | grep -q '100' && ok || bad "gh:repos: limit above GitHub's page cap rejected before any call"
        run gh:repos --input-json '{"owner":"sammasak; id"}'
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = invalid_input ] && ok || bad "gh:repos: unsafe owner rejected"
        FAKE_GH_API_EXIT=1 run gh:repos
        [ "$CODE" -eq 0 ] && [ "$(jqr .error.kind)" = gh_error ] && jqr .error.message | grep -q 'HTTP 404' && ok || bad "gh:repos: gh failure is data with gh's own message ($CODE $OUT)"
        FAKE_GH_GRAPHQL_RAW='{"data":null,"errors":[{"message":"rate limited"}]}' run gh:repos
        [ "$CODE" -eq 0 ] && [ "$(jqr .error.kind)" = malformed ] && ok || bad "gh:repos: a GraphQL error body is data, not a list ($OUT)"
        # the blind spot: an approved issue in a repo pushed earlier than the newest `limit` (dormant, outside the page) is
        # found by the search; a hit in a listed repo adds nothing, a hit under another owner is ignored
        export FAKE_GH_SEARCH='[{"repository":{"name":"dormant","nameWithOwner":"sammasak/dormant"},"number":7,"title":"approved but dormant","url":"https://github.com/sammasak/dormant/issues/7"},{"repository":{"name":"dormant","nameWithOwner":"sammasak/dormant"},"number":9,"title":"second one","url":"https://github.com/sammasak/dormant/issues/9"},{"repository":{"name":"skills","nameWithOwner":"sammasak/skills"},"number":28,"title":"listed already","url":"https://github.com/sammasak/skills/issues/28"},{"repository":{"name":"x","nameWithOwner":"someone-else/x"},"number":1,"title":"not ours","url":"https://github.com/someone-else/x/issues/1"}]'
        run gh:repos --option coordinator.ghLimit:int 2
        [ "$CODE" -eq 0 ] && [ "$(jqr '[.repos[].repo] | join(",")')" = "sammasak/nixos-config,sammasak/skills,sammasak/dormant" ] && [ "$(jqr '.repos[] | select(.repo=="sammasak/dormant") | "\(.active) \(.approved_issues) \(.open_prs) \(.found_by)"')" = "true 2 0 search" ] && ok || bad "gh:repos: an approved issue in a dormant repo outside the page is discovered ($(jqr '.repos'))"
        [ "$(jqr '.search | "\(.error) \(.found) \(.repos_added | join(","))"')" = "null 3 sammasak/dormant" ] && [ "$(jqr '.repos[] | select(.repo=="sammasak/skills") | .approved_issues')" = 2 ] && [ "$(jqr '.repos | map(.repo) | unique | length')" = 3 ] && ok || bad "gh:repos: listed repos keep their GraphQL counts, another owner's hit is ignored, nothing is duplicated ($(jqr .search))"
        FAKE_GH_SEARCH_EXIT=1 run gh:repos --option coordinator.ghLimit:int 2
        [ "$CODE" -eq 0 ] && [ "$(jqr .error)" = null ] && [ "$(jqr '.repos | length')" = 2 ] && [ "$(jqr '.search.error.kind')" = gh_error ] && jqr '.search.error.message' | grep -q 'rate limit' && ok || bad "gh:repos: a failing search is data under .search and the page stands ($(jqr '{search, n:(.repos|length)}'))"
        unset FAKE_GH_SEARCH FAKE_GH_REPOS
        summary
      '';
    };
    "skills:test:tasks:harness-session-summary" = {
      description = "harness:session-summary over local Claude and Pi fixtures";
      exec = ''
        set +e -uo pipefail   # the task runner enables errexit; these suites inspect exit codes themselves
        ROOT="$DEVENV_ROOT"; cd "$ROOT" || exit 1
        export HERDR_PANE_ID=coord:p0   # the suite runs its tasks from the Coordinator's own pane, never a target
        # hermetic: a devenv.local.nix in the checkout (the coordinator host writes the owner's delegation and panes there)
        # must not reach the suites; the last --option wins, so each case still sets its own
        devenv() { command devenv "$1" "$2" --option coordinator.mayApprove:bool false --option coordinator.approvalDecision:string "" --option coordinator.panes:string "" "''${@:3}"; }
        FX="$ROOT/task-modules/fixtures"; FAKES="${config.coordinator.fakes}/bin"
        TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
        export FAKE_LOG="$TMP/calls.log" FAKE_GH_DIR="$FX/gh"
        PASS=0; FAIL=0
        ok() { PASS=$((PASS+1)); }
        bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
        run() { # <task> [args]
          local task="$1"; shift
          devenv tasks run "$task" --option coordinator.herdrCommand:string "$FAKES/herdr" --option coordinator.sshCommand:string "$FAKES/ssh" --option coordinator.locksCommand:string "$FAKES/host-locks" --option coordinator.ghCommand:string "$FAKES/gh" \
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
