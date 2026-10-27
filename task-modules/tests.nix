# Fixture suites for the shared task modules, as devenv tasks (no scripts): each drives the real tasks with
# --option overrides against the Nix-built fakes and the JSON fixtures under task-modules/fixtures.
{ config, lib, ... }:
{
  tasks = {
    "skills:test:tasks:evidence" = {
      description = "gh:work and git:recent over fake gh and a throwaway repo";
      exec = ''
        # Drives gh:work:<repo> / git:recent:<repo> and their aggregates with a fake gh and a throwaway git repo.
        set +e -uo pipefail   # the task runner enables errexit; these suites inspect exit codes themselves
        ROOT="$DEVENV_ROOT"; cd "$ROOT" || exit 1
        FX="$ROOT/task-modules/fixtures"
        TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
        export FAKE_LOG="$TMP/calls.log" FAKE_GH_DIR="$FX/gh"
        PASS=0; FAIL=0
        ok() { PASS=$((PASS+1)); }
        bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
        run() { # <task> <fleet> [devenv args...]
          local task="$1" fleet="$2"; shift 2
          devenv tasks run "$task" --option coordinator.fleetFile:path "$fleet" --option coordinator.ghCommand:string "${config.coordinator.fakes}/bin/gh" \
            --option coordinator.timeoutSeconds:int 2 --show-output "$@" > "$TMP/run.log" 2>&1; CODE=$?
          OUT=$(grep -E "^\s*\{\"schema_version\":1,\"task\":\"$task\"" "$TMP/run.log" | tail -1 | sed -E 's/^\s+//'); [ -n "$OUT" ] || OUT='{}'
        }
        jqr() { jq -r "$1" <<<"$OUT"; }

        # a throwaway git repo with an upstream, one unpushed commit and a dirty file
        git init -q "$TMP/origin" --bare
        git init -q "$TMP/co" && (cd "$TMP/co" && git config user.email t@t && git config user.name t && echo a > a && git add a && git commit -qm "feat: first (#42)" && git remote add origin "$TMP/origin" && git push -q -u origin HEAD && echo b > b && git add b && git commit -qm "fix: second" && echo c > c)
        printf '{"schema_version":1,"hosts":[],"repos":[{"name":"skills","gh":"sammasak/skills","checkout":"%s"},{"name":"ghonly","gh":"sammasak/ghonly","checkout":null},{"name":"gone","gh":null,"checkout":"%s/nowhere"}]}' "$TMP/co" "$TMP" > "$TMP/fleet.json"

        run gh:work "$TMP/fleet.json"
        [ "$CODE" -eq 0 ] && ok || bad "gh: exit $CODE ($(tail -3 "$TMP/run.log"))"
        [ "$(jqr '.repos|length')" = 2 ] && ok || bad "gh: two gh repos aggregated ($OUT)"
        [ "$(jqr '.repos[] | select(.repo=="skills") | .issues | length')" = 2 ] && ok || bad "gh: issues parsed"
        [ "$(jqr '.repos[] | select(.repo=="skills") | .prs[] | select(.number==15) | .merged_at')" = "2026-10-26T13:30:00Z" ] && ok || bad "gh: merged_at"
        [ "$(jqr '.repos[] | select(.repo=="skills") | .prs[] | select(.number==15) | .closes[0]')" = 42 ] && ok || bad "gh: closes"
        [ "$(jqr '.repos[] | select(.repo=="skills") | .prs[] | select(.number==15) | .checks[0]')" = SUCCESS ] && ok || bad "gh: checks"
        [ "$(jqr '.repos[] | select(.repo=="ghonly") | .issues | length')" = 0 ] && ok || bad "gh: repo without fixture gives empty lists"
        [ "$(jqr .partial)" = false ] && ok || bad "gh: not partial"
        grep -q 'issue list -R sammasak/skills --state open --limit 20' "$FAKE_LOG" && ok || bad "gh: bounded argv ($(head -1 "$FAKE_LOG"))"
        grep -q 'pr list -R sammasak/skills --state open --limit 20' "$FAKE_LOG" && grep -q 'pr list -R sammasak/skills --state merged --limit 20' "$FAKE_LOG" && ok || bad "gh: open and merged PR lists fetched separately"
        [ "$(jqr '.repos[] | select(.repo=="skills") | .open_pr_count')" = 1 ] && ok || bad "gh: open_pr_count ($(jqr '.repos[] | select(.repo=="skills") | .open_pr_count'))"

        FAKE_GH_EXIT=1 run gh:work "$TMP/fleet.json"
        [ "$CODE" -eq 0 ] && [ "$(jqr '.repos|length')" = 0 ] && ok || bad "gh down: record still emitted, no repos (exit $CODE)"
        [ "$(jqr '.failed_sources[0].error.kind')" = gh_error ] && ok || bad "gh down: error kind ($OUT)"
        [ "$(jqr .partial)" = true ] && ok || bad "gh down: partial"

        run git:recent "$TMP/fleet.json"
        [ "$CODE" -eq 0 ] && ok || bad "git: exit $CODE ($(tail -3 "$TMP/run.log"))"
        [ "$(jqr '.repos|length')" = 1 ] && ok || bad "git: one usable checkout ($OUT)"
        [ "$(jqr '.failed_sources[0].repo')" = gone ] && ok || bad "git: missing checkout reported as failed source"
        [ "$(jqr '.failed_sources[0].error.kind')" = not_found ] && ok || bad "git: not_found kind"
        [ "$(jqr .partial)" = true ] && ok || bad "git: partial because one checkout is gone"
        [ "$(jqr '.repos[0].dirty_files')" = 1 ] && ok || bad "git: dirty_files ($(jqr '.repos[0]'))"
        [ "$(jqr '.repos[0].ahead')" = 1 ] && ok || bad "git: ahead"
        [ "$(jqr '.repos[0].unpushed[0].subject')" = "fix: second" ] && ok || bad "git: unpushed subject"
        [ "$(jqr '.repos[0].commits|length')" = 2 ] && ok || bad "git: commits in window"
        [ "$(jqr '.repos[0].upstream')" = "origin/master" ] || [ "$(jqr '.repos[0].upstream')" = "origin/main" ] && ok || bad "git: upstream ($(jqr '.repos[0].upstream'))"

        # the graph contains exactly the fleet's repos
        listed=$(devenv tasks list --option coordinator.fleetFile:path "$TMP/fleet.json" 2>/dev/null | grep -oE '(gh:work|git:recent):[a-z]+' | sort -u | paste -sd,)
        [ "$listed" = "gh:work:ghonly,gh:work:skills,git:recent:gone,git:recent:skills" ] && ok || bad "graph: '$listed'"
        # unsafe gh value or checkout path is refused at evaluation
        printf '{"schema_version":1,"hosts":[],"repos":[{"name":"x","gh":"sammasak/skills'"'"'; id","checkout":null}]}' > "$TMP/badgh.json"
        run gh:work "$TMP/badgh.json"; [ "$CODE" -ne 0 ] && grep -q 'unsafe characters' "$TMP/run.log" && ok || bad "unsafe gh must fail evaluation"
        printf '{"schema_version":1,"hosts":[],"repos":[{"name":"x","gh":null,"checkout":"relative/path"}]}' > "$TMP/badco.json"
        run git:recent "$TMP/badco.json"; [ "$CODE" -ne 0 ] && grep -q 'unsafe characters' "$TMP/run.log" && ok || bad "relative checkout must fail evaluation"
        # unsafe checkout path is refused at evaluation
        printf '{"schema_version":1,"hosts":[],"repos":[{"name":"x","gh":null,"checkout":"/tmp/a; id"}]}' > "$TMP/bad.json"
        run git:recent "$TMP/bad.json"; [ "$CODE" -ne 0 ] && grep -q 'unsafe characters' "$TMP/run.log" && ok || bad "unsafe checkout must fail evaluation"

        echo "passed=$PASS failed=$FAIL"; [ "$FAIL" -eq 0 ]
      '';
    };
    "skills:test:tasks:harness-session-summary" = {
      description = "harness:session-summary over Claude and Pi fixtures";
      exec = ''
        # Drives the real harness:session-summary task against fixture session stores.
        set +e -uo pipefail   # the task runner enables errexit; these suites inspect exit codes themselves
        ROOT="$DEVENV_ROOT"; cd "$ROOT" || exit 1
        FX="$ROOT/task-modules/fixtures/harness"
        TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
        PASS=0; FAIL=0
        ok() { PASS=$((PASS+1)); }
        bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
        printf '{"schema_version":1,"hosts":[{"name":"acer-swift","ssh":null},{"name":"lenovo","ssh":"lukas@lenovo.lan"}],"repos":[]}' > "$TMP/fleet.json"
        export FAKE_LOG="$TMP/calls.log"
        run() {
          devenv tasks run harness:session-summary --option coordinator.fleetFile:path "$TMP/fleet.json" --option coordinator.sshCommand:string "${config.coordinator.fakes}/bin/ssh" \
            --option coordinator.claudeProjectsDir:string "$FX/claude" --option coordinator.piSessionsDir:string "$FX/pi" \
            --show-output --input-json "$1" > "$TMP/run.log" 2>&1; CODE=$?
          OUT=$(grep -E '^\s*\{"schema_version":1' "$TMP/run.log" | tail -1 | sed -E 's/^\s+//'); [ -n "$OUT" ] || OUT='{}'
        }
        jqr() { jq -r "$1" <<<"$OUT"; }

        run '{"host":"acer-swift","harness":"claude","session_id":"aaaaaaaa-1111-4111-8111-111111111111","cwd":"/home/lukas/herman"}'
        [ "$CODE" -eq 0 ] && ok || bad "claude: exit $CODE ($(tail -3 "$TMP/run.log"))"
        [ "$(jqr .event_count)" = 7 ] && ok || bad "claude: event_count ($OUT)"
        [ "$(jqr .last_event_at)" = "2026-10-26T14:04:01.000Z" ] && ok || bad "claude: last_event_at"
        [ "$(jqr .last_role)" = assistant ] && ok || bad "claude: last_role"
        [ "$(jqr .awaiting_input)" = true ] && ok || bad "claude: question at the end => awaiting_input"
        jqr .last_user_prompt_excerpt | grep -q 'settlement rounding tests' && ok || bad "claude: user prompt excerpt"
        jqr .last_assistant_excerpt | grep -q 'property test' && ok || bad "claude: assistant excerpt"
        [ "$(jqr '.last_tools | join(",")')" = "Read,Bash" ] && ok || bad "claude: last_tools ($(jqr .last_tools))"
        [ "$(jqr .task_ref)" = "#42" ] && ok || bad "claude: task_ref from prompt"
        [ "$(jqr '.last_assistant_excerpt | length')" -le 400 ] && ok || bad "claude: excerpt bounded"

        # remote host: same summary over the fake ssh (which joins argv into one shell string like real ssh)
        : > "$FAKE_LOG"
        run '{"host":"lenovo","harness":"claude","session_id":"aaaaaaaa-1111-4111-8111-111111111111","cwd":"/home/lukas/herman"}'
        [ "$CODE" -eq 0 ] && [ "$(jqr .event_count)" = 7 ] && ok || bad "remote claude: exit $CODE count $(jqr .event_count) ($(tail -2 "$TMP/run.log"))"
        grep -q "^ssh .*lukas@lenovo.lan bash -c '.*' _ " "$FAKE_LOG" && ok || bad "remote: ssh bash -c argv"
        # a half-written trailing line is skipped and counted, not fatal
        cp "$FX/claude/-home-lukas-herman/aaaaaaaa-1111-4111-8111-111111111111.jsonl" "$TMP/partial.jsonl"; printf '{"type":"assistant","timestamp":"2026-10-26T14:0' >> "$TMP/partial.jsonl"
        mkdir -p "$TMP/claude/-home-lukas-herman" && cp "$TMP/partial.jsonl" "$TMP/claude/-home-lukas-herman/bbbbbbbb-1111-4111-8111-111111111111.jsonl"
        devenv tasks run harness:session-summary --option coordinator.fleetFile:path "$TMP/fleet.json" --option coordinator.claudeProjectsDir:string "$TMP/claude" --show-output --input-json '{"host":"acer-swift","harness":"claude","session_id":"bbbbbbbb-1111-4111-8111-111111111111","cwd":"/home/lukas/herman"}' > "$TMP/run.log" 2>&1; CODE=$?
        OUT=$(grep -E '^\s*\{"schema_version":1' "$TMP/run.log" | tail -1 | sed -E 's/^\s+//')
        [ "$CODE" -eq 0 ] && [ "$(jqr .skipped_lines)" = 1 ] && [ "$(jqr .event_count)" = 7 ] && ok || bad "partial line: exit $CODE skipped $(jqr .skipped_lines) ($OUT)"
        # a user turn after the question clears awaiting_input
        jq -c '.' "$FX/claude/-home-lukas-herman/aaaaaaaa-1111-4111-8111-111111111111.jsonl" > "$TMP/claude/-home-lukas-herman/cccccccc-1111-4111-8111-111111111111.jsonl"
        printf '%s\n' '{"type":"user","timestamp":"2026-10-26T14:05:00.000Z","message":{"role":"user","content":[{"type":"text","text":"<system-reminder>ignored</system-reminder>"},{"type":"text","text":"yes, add it (#42)"}]}}' >> "$TMP/claude/-home-lukas-herman/cccccccc-1111-4111-8111-111111111111.jsonl"
        devenv tasks run harness:session-summary --option coordinator.fleetFile:path "$TMP/fleet.json" --option coordinator.claudeProjectsDir:string "$TMP/claude" --show-output --input-json '{"host":"acer-swift","harness":"claude","session_id":"cccccccc-1111-4111-8111-111111111111","cwd":"/home/lukas/herman"}' > "$TMP/run.log" 2>&1; CODE=$?
        OUT=$(grep -E '^\s*\{"schema_version":1' "$TMP/run.log" | tail -1 | sed -E 's/^\s+//')
        [ "$(jqr .awaiting_input)" = false ] && [ "$(jqr .last_role)" = user ] && ok || bad "answered question: awaiting $(jqr .awaiting_input) role $(jqr .last_role)"
        [ "$(jqr .last_user_prompt_excerpt)" = "yes, add it (#42)" ] && ok || bad "system-reminder text skipped ($(jqr .last_user_prompt_excerpt))"

        run '{"host":"acer-swift","harness":"pi","session_id":"pi-sess-1","cwd":"/home/lukas/karta"}'
        [ "$CODE" -eq 0 ] && ok || bad "pi: exit $CODE ($(tail -3 "$TMP/run.log"))"
        [ "$(jqr .event_count)" = 3 ] && ok || bad "pi: event_count ($OUT)"
        [ "$(jqr .awaiting_input)" = false ] && ok || bad "pi: statement at the end => not awaiting"
        jqr .last_assistant_excerpt | grep -q 'clippy is clean' && ok || bad "pi: assistant excerpt"

        run '{"host":"acer-swift","harness":"claude","session_id":"aaaaaaaa-1111-4111-8111-111111111111","cwd":"/home/lukas/nowhere"}'
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = not_found ] && ok || bad "missing: kind $(jqr .error.kind)"
        run '{"host":"acer-swift","harness":"codex","session_id":"thr_1","cwd":"/home/lukas/herman"}'
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = unsupported ] && ok || bad "codex: unsupported until a store exists ($(jqr .error.kind))"
        run '{"host":"acer-swift","harness":"claude","session_id":"../../etc/passwd","cwd":"/home/lukas/herman"}'
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = invalid_input ] && ok || bad "traversal: kind $(jqr .error.kind)"
        run '{"host":"acer-swift","harness":"claude","session_id":"x","cwd":"/home/lukas/herman; id"}'
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = invalid_input ] && ok || bad "cwd injection: kind $(jqr .error.kind)"

        echo "passed=$PASS failed=$FAIL"; [ "$FAIL" -eq 0 ]
      '';
    };
    "skills:test:tasks:herdr-inspect" = {
      description = "herdr:inspect bounds and argv order over the fake herdr";
      exec = ''
        # Drives the real herdr:inspect task (bounded terminal read) with fake ssh/herdr.
        set +e -uo pipefail   # the task runner enables errexit; these suites inspect exit codes themselves
        ROOT="$DEVENV_ROOT"; cd "$ROOT" || exit 1
        FX="$ROOT/task-modules/fixtures"
        TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
        export FAKE_LOG="$TMP/calls.log"
        PASS=0; FAIL=0
        ok() { PASS=$((PASS+1)); }
        bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
        printf '{"schema_version":1,"hosts":[{"name":"acer-swift","ssh":null},{"name":"lenovo","ssh":"lukas@lenovo.lan"}],"repos":[]}' > "$TMP/fleet.json"
        run() { # <input-json> ; OUT, CODE
          devenv tasks run herdr:inspect --option coordinator.fleetFile:path "$TMP/fleet.json" \
            --option coordinator.sshCommand:string "${config.coordinator.fakes}/bin/ssh" --option coordinator.herdrCommand:string "${config.coordinator.fakes}/bin/herdr" \
            --option coordinator.timeoutSeconds:int 1 --show-output --input-json "$1" > "$TMP/run.log" 2>&1; CODE=$?
          OUT=$(grep -E '^\s*\{"schema_version":1' "$TMP/run.log" | tail -1 | sed -E 's/^\s+//'); [ -n "$OUT" ] || OUT='{}'
        }
        jqr() { jq -r "$1" <<<"$OUT"; }

        # local bounded read
        : > "$FAKE_LOG"
        FAKE_HERDR_READ="$FX/herdr/read-visible.txt" run '{"host":"acer-swift","agent_id":"wF:p1","lines":40}'
        [ "$CODE" -eq 0 ] && ok || bad "local: exit $CODE ($(tail -3 "$TMP/run.log"))"
        [ "$(jqr .lines_returned)" = 4 ] && ok || bad "local: lines_returned ($OUT)"
        jqr .excerpt | grep -q 'property test' && ok || bad "local: excerpt content"
        [ "$(jqr .agent_id)" = "wF:p1" ] && ok || bad "local: agent_id echoed"
        grep -q 'herdr agent read wF:p1 --lines 40 --source visible --format text' "$FAKE_LOG" && ok || bad "local: expected bounded read argv ($(cat "$FAKE_LOG"))"
        grep -q '^ssh' "$FAKE_LOG" && bad "local: no ssh for local host" || ok

        # remote read goes through ssh with the same bounded argv
        : > "$FAKE_LOG"
        FAKE_HERDR_READ="$FX/herdr/read-visible.txt" run '{"host":"lenovo","agent_id":"wA:p2","lines":10,"source":"recent"}'
        [ "$CODE" -eq 0 ] && ok || bad "remote: exit $CODE"
        grep -q "^ssh .*-- lukas@lenovo.lan bash -c '.*' _ " "$FAKE_LOG" && grep -q 'herdr agent read wA:p2 --lines 10 --source recent --format text' "$FAKE_LOG" && ok || bad "remote: argv ($(cat "$FAKE_LOG"))"

        # the cap holds: 1000 requested -> 200 asked for and at most 200 returned
        : > "$FAKE_LOG"
        FAKE_HERDR_READ="$FX/herdr/read-long.txt" run '{"host":"acer-swift","agent_id":"wF:p1","lines":1000}'
        grep -q -- '--lines 200 ' "$FAKE_LOG" && ok || bad "cap: requested lines must be capped at 200"
        [ "$(jqr .lines_returned)" -le 200 ] && ok || bad "cap: lines_returned <= 200"
        [ "$(jqr .truncated)" = true ] && [ "$(jqr .capped)" = true ] && ok || bad "cap: truncated+capped flags"
        FAKE_HERDR_READ="$FX/herdr/read-visible.txt" run '{"host":"acer-swift","agent_id":"wF:p1","lines":500}'
        [ "$(jqr .truncated)" = false ] && [ "$(jqr .capped)" = true ] && ok || bad "short pane with capped request: capped but not truncated"
        run '{"host":"acer-swift","agent_id":"wF:p1","lines":99999999999}'; [ "$(jqr .error.kind)" = invalid_input ] && ok || bad "huge lines rejected"

        # invalid input is refused before any call
        for bad_input in '{"host":"acer-swift","agent_id":"wF:p1; rm -rf /"}' '{"host":"nothere","agent_id":"wF:p1"}' '{"host":"acer-swift"}' '{"host":"acer-swift","agent_id":"wF:p1","source":"detection; id"}' '{"host":"acer-swift","agent_id":"wF:p1","lines":"abc"}'; do
          : > "$FAKE_LOG"; run "$bad_input"
          [ "$CODE" -ne 0 ] && [ "$(jqr '.error.kind')" = invalid_input ] && ok || bad "invalid: $bad_input -> exit $CODE kind $(jqr '.error.kind')"
          [ -s "$FAKE_LOG" ] && bad "invalid: no herdr/ssh call may happen for $bad_input" || ok
        done

        # agent missing / herdr error is a structured error
        FAKE_HERDR_READ="$FX/herdr/read-visible.txt" FAKE_HERDR_EXIT=1 run '{"host":"acer-swift","agent_id":"wZ:p9"}'
        [ "$CODE" -ne 0 ] && [ "$(jqr '.error.kind')" = command_failed ] && ok || bad "missing agent: kind $(jqr '.error.kind')"
        # timeout
        run '{"host":"slow","agent_id":"wF:p1"}'; [ "$(jqr '.error.kind')" = invalid_input ] && ok || bad "unknown host slow must be invalid_input"
        printf '{"schema_version":1,"hosts":[{"name":"slow","ssh":"lukas@timeout.lan"}],"repos":[]}' > "$TMP/fleet.json"
        run '{"host":"slow","agent_id":"wF:p1"}'
        [ "$CODE" -ne 0 ] && [ "$(jqr '.error.kind')" = timeout ] && ok || bad "timeout: kind $(jqr '.error.kind')"

        echo "passed=$PASS failed=$FAIL"; [ "$FAIL" -eq 0 ]
      '';
    };
    "skills:test:tasks:herdr-inventory" = {
      description = "herdr:inventory over fake herdr/ssh, snapshots and the fleet file";
      exec = ''
        # Drives the real herdr:list:<host> / herdr:inventory tasks with fixture fleets and
        # fake ssh/herdr injected through devenv options. Run from the repo root inside
        # the devenv: bash task-modules/tests/test-herdr-inventory.sh
        set +e -uo pipefail   # the task runner enables errexit; these suites inspect exit codes themselves
        unset COORDINATOR_SSH_IDENTITY  # a leaked value would flip the no-key-options case
        ROOT="$DEVENV_ROOT"; cd "$ROOT" || exit 1
        FX="$ROOT/task-modules/fixtures"
        TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
        export FAKE_LOG="$TMP/calls.log"
        PASS=0; FAIL=0
        ok() { PASS=$((PASS+1)); }
        bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
        fleet() { printf '{"schema_version":1,"hosts":%s,"repos":[]}' "$2" > "$1"; }
        # run <fleet-file> [extra devenv args...]: OUT = herdr:inventory output, CODE = devenv exit
        run() {
          local f="$1"; shift
          local log="$TMP/run.log"
          devenv tasks run herdr:inventory --option coordinator.fleetFile:path "$f" \
            --option coordinator.sshCommand:string "${config.coordinator.fakes}/bin/ssh" --option coordinator.herdrCommand:string "${config.coordinator.fakes}/bin/herdr" \
            --option coordinator.stateDir:string "$TMP/state" --option coordinator.timeoutSeconds:int 1 --show-output "$@" > "$log" 2>&1; CODE=$?
          OUT=$(grep -E '^\s*\{"schema_version":1' "$log" | tail -1 | sed -E 's/^\s+//'); [ -n "$OUT" ] || OUT='{}'
        }
        jqr() { jq -r "$1" <<<"$OUT"; }

        # 1. local host only: both fixture agents become records
        fleet "$TMP/local.json" '[{"name":"acer-swift","ssh":null}]'
        FAKE_HERDR_LIST="$FX/herdr/local-two-agents.json" run "$TMP/local.json"
        [ "$CODE" -eq 0 ] && ok || bad "local: exit $CODE"
        [ "$(jqr .schema_version)" = 1 ] && ok || bad "local: schema_version"
        [ "$(jqr '.hosts[0].agents|length')" = 2 ] && ok || bad "local: 2 agents ($OUT)"
        [ "$(jqr '.hosts[0].agents[0].agent_id')" = "wF:p1" ] && ok || bad "local: agent_id"
        [ "$(jqr '.hosts[0].agents[0].observed_state')" = working ] && ok || bad "local: observed_state"
        [ "$(jqr '.hosts[0].agents[0].harness')" = claude ] && ok || bad "local: harness"
        [ "$(jqr '.hosts[0].agents[0].session_id')" = "11111111-1111-4111-8111-111111111111" ] && ok || bad "local: session_id"
        [ "$(jqr '.hosts[0].agents[0].task_ref')" = "#16" ] && ok || bad "local: task_ref"
        [ "$(jqr '.hosts[0].agents[1].observed_state')" = "done" ] && ok || bad "local: second state"
        [ "$(jqr '.hosts[0].agents[1].approval_required')" = false ] && ok || bad "local: done is not approval_required"
        [ "$(jqr '.hosts[0].agents[0].stale')" = false ] && ok || bad "local: fresh read not stale"
        [ "$(jqr .partial)" = false ] && ok || bad "local: partial"
        grep -q '^ssh' "$FAKE_LOG" && bad "local: ssh must not be called for a local host" || ok

        # 2. state_age_s grows while state_change_seq is unchanged; resets when it changes
        sleep 1
        FAKE_HERDR_LIST="$FX/herdr/local-two-agents.json" run "$TMP/local.json"
        age=$(jqr '.hosts[0].agents[0].state_age_s'); [ "$age" -ge 1 ] 2>/dev/null && ok || bad "age: expected >=1, got $age"
        jq '.result.agents[0].state_change_seq = 999' "$FX/herdr/local-two-agents.json" > "$TMP/changed.json"
        FAKE_HERDR_LIST="$TMP/changed.json" run "$TMP/local.json"
        [ "$(jqr '.hosts[0].agents[0].state_age_s')" = 0 ] && ok || bad "age: expected reset to 0"

        # 3. remote host over fake ssh; blocked agent is approval_required
        fleet "$TMP/remote.json" '[{"name":"lenovo","ssh":"lukas@lenovo.lan"}]'
        FAKE_HERDR_LIST="$FX/herdr/remote-ok.json" run "$TMP/remote.json"
        [ "$CODE" -eq 0 ] && ok || bad "remote: exit $CODE"
        grep -q "^ssh .*-- lukas@lenovo.lan bash -c '.*' _ " "$FAKE_LOG" && grep -q '^herdr agent list' "$FAKE_LOG" && ok || bad "remote: expected ssh <target> herdr agent list"
        [ "$(jqr '.hosts[0].agents[0].approval_required')" = true ] && ok || bad "remote: blocked => approval_required"
        [ "$(jqr '.hosts[0].agents[0].host')" = lenovo ] && ok || bad "remote: host field"
        grep -qE '^ssh .* (-F |-i |-o IdentitiesOnly)' "$FAKE_LOG" && bad "remote: no key options without COORDINATOR_SSH_IDENTITY" || ok
        # with the identity set, exactly one key is offered: -F none (no ssh_config read) -i <key> -o IdentitiesOnly=yes,
        # all before -- and the target; the remote command must still run and its agents come back
        : > "$FAKE_LOG"; COORDINATOR_SSH_IDENTITY=/keys/coordinator FAKE_HERDR_LIST="$FX/herdr/remote-ok.json" run "$TMP/remote.json"
        grep -q "^ssh .* -F none -i /keys/coordinator -o IdentitiesOnly=yes -- lukas@lenovo.lan " "$FAKE_LOG" && ok || bad "remote: expected -F none -i <key> -o IdentitiesOnly=yes before --"
        grep -q '^herdr agent list' "$FAKE_LOG" && [ "$(jqr '.hosts[0].agents | length')" -ge 1 ] && ok || bad "remote: the remote herdr call must still run with the key options"

        # 4. one host times out: its error is reported, the other host still returned, exit 0, partial true
        fleet "$TMP/mixed.json" '[{"name":"acer-swift","ssh":null},{"name":"slow","ssh":"lukas@timeout.lan"}]'
        FAKE_HERDR_LIST="$FX/herdr/local-two-agents.json" run "$TMP/mixed.json"
        [ "$CODE" -eq 0 ] && ok || bad "timeout: exit $CODE"
        [ "$(jqr '.hosts[1].error.kind')" = timeout ] && ok || bad "timeout: error.kind ($(jqr '.hosts[1]'))"
        [ "$(jqr '.hosts[1].reachable')" = false ] && ok || bad "timeout: reachable false"
        [ "$(jqr '.hosts[0].agents|length')" = 2 ] && ok || bad "timeout: healthy host still present"
        [ "$(jqr .partial)" = true ] && ok || bad "timeout: partial true"

        # 5. unreachable host falls back to its last snapshot, marked stale; too old => dropped
        fleet "$TMP/down.json" '[{"name":"lenovo","ssh":"lukas@lenovo.lan"}]'
        FAKE_HERDR_LIST="$FX/herdr/remote-ok.json" run "$TMP/down.json"
        fleet "$TMP/down.json" '[{"name":"lenovo","ssh":"lukas@down.lan"}]'
        run "$TMP/down.json"
        [ "$CODE" -eq 0 ] && [ "$(jqr .answered_hosts)" = 0 ] && ok || bad "down: inventory still emits its record (exit $CODE, answered $(jqr .answered_hosts))"
        [ "$(jqr '.hosts[0].error.kind')" = unreachable ] && ok || bad "down: error.kind"
        [ "$(jqr '.hosts[0].agents[0].stale')" = true ] && ok || bad "down: snapshot agents are stale"
        [ "$(jqr '.hosts[0].agents[0].observed_state')" = blocked ] && ok || bad "down: snapshot state kept"
        [ "$(jqr '.hosts[0].agents[0].snapshot_age_s')" -ge 0 ] 2>/dev/null && ok || bad "down: snapshot_age_s present"
        sleep 1; run "$TMP/down.json" --option coordinator.maxAgeSeconds:int 0
        [ "$(jqr '.hosts[0].agents|length')" = 0 ] && ok || bad "down: snapshot older than max age is dropped"
        jqr '.hosts[0].error.message' | grep -q discarded && ok || bad "down: discard noted in error"

        # 6. malformed herdr output is an error, not a crash
        fleet "$TMP/bad.json" '[{"name":"acer-swift","ssh":null}]'
        FAKE_HERDR_LIST="$FX/herdr/malformed.json" run "$TMP/bad.json"
        [ "$CODE" -eq 0 ] && [ "$(jqr .partial)" = true ] && ok || bad "malformed: partial record, exit 0"
        [ "$(jqr '.hosts[0].error.kind')" = malformed ] && ok || bad "malformed: error.kind"

        # 7. invalid fleet entries are refused at evaluation, before any call
        : > "$FAKE_LOG"
        fleet "$TMP/inj.json" '[{"name":"evil; rm -rf /","ssh":"lukas@x"}]'
        run "$TMP/inj.json"
        [ "$CODE" -ne 0 ] && ok || bad "inject: must fail evaluation"
        grep -q 'does not match' "$TMP/run.log" && ok || bad "inject: assertion message expected"
        [ -s "$FAKE_LOG" ] && bad "inject: no ssh/herdr call may happen" || ok
        fleet "$TMP/inj2.json" '[{"name":"lenovo","ssh":"lukas@h $(id)"}]'
        run "$TMP/inj2.json"; [ "$CODE" -ne 0 ] && ok || bad "inject2: must fail evaluation"
        printf '{"schema_version":2,"hosts":[]}' > "$TMP/v2.json"; run "$TMP/v2.json"
        [ "$CODE" -ne 0 ] && ok || bad "wrong schema_version: must fail"
        grep -q 'schema_version must be 1' "$TMP/run.log" && ok || bad "wrong schema_version: message"

        # 7b. renumbered pane / new session does not inherit the old age; null fields do not crash
        fleet "$TMP/ren.json" '[{"name":"acer-swift","ssh":null}]'
        FAKE_HERDR_LIST="$FX/herdr/local-two-agents.json" run "$TMP/ren.json"; sleep 1
        jq '.result.agents[0].pane_id = "wF:p9"' "$FX/herdr/local-two-agents.json" > "$TMP/ren2.json"
        FAKE_HERDR_LIST="$TMP/ren2.json" run "$TMP/ren.json"
        [ "$(jqr '.hosts[0].agents[0].state_age_s')" = 0 ] && ok || bad "renumbered pane starts at age 0"
        FAKE_HERDR_LIST="$FX/herdr/odd-agents.json" run "$TMP/ren.json"
        [ "$CODE" -eq 0 ] && [ "$(jqr '.hosts[0].agents|length')" = 3 ] && ok || bad "odd records: 3 usable agents ($(jqr '.hosts[0]'))"
        [ "$(jqr '.hosts[0].agents[] | select(.agent_id=="wX:p1") | .observed_state')" = idle ] && ok || bad "odd: idle agent"
        [ "$(jqr '.hosts[0].agents[] | select(.agent_id=="wX:p3") | .observed_state')" = unknown ] && ok || bad "odd: missing status => unknown"
        [ "$(jqr '.hosts[0].agents[] | select(.agent_id=="wX:p3") | .session_id')" = null ] && ok || bad "odd: string agent_session => null session"

        # 7c. a missing fleet file is an empty graph (fresh clones evaluate); the override is --option, never env (devenv caches eval per inputs, not env)
        out=$(devenv tasks list --option coordinator.fleetFile:path "$TMP/does-not-exist.json" 2>&1); rc=$?
        [ "$rc" -eq 0 ] && grep -q 'herdr:inventory' <<<"$out" && [ "$(grep -cE 'herdr:list:' <<<"$out")" = 0 ] && ok || bad "missing fleet => empty graph that still evaluates (rc $rc)"

        # 8. the graph contains exactly the fleet's hosts
        fleet "$TMP/two.json" '[{"name":"acer-swift","ssh":null},{"name":"lenovo","ssh":"lukas@lenovo.lan"}]'
        listed=$(devenv tasks list --option coordinator.fleetFile:path "$TMP/two.json" 2>/dev/null | grep -oE 'herdr:list:[a-z-]+' | sort -u | paste -sd,)
        [ "$listed" = "herdr:list:acer-swift,herdr:list:lenovo" ] && ok || bad "graph: expected two list tasks, got '$listed'"
        listed=$(devenv tasks list --option coordinator.fleetFile:path "$FX/fleet-empty.json" 2>/dev/null | grep -cE 'herdr:list:')
        [ "$listed" = 0 ] && ok || bad "graph: empty fleet has no list tasks"

        echo "passed=$PASS failed=$FAIL"; [ "$FAIL" -eq 0 ]
      '';
    };
    "skills:test:tasks:herdr-message-await" = {
      description = "herdr:message audit/duplicate guard and herdr:await two-phase wait";
      exec = ''
        # herdr:message (act) and herdr:await with a fake herdr: confirmation, blocked refusal, audit, duplicates, timeouts.
        set +e -uo pipefail   # the task runner enables errexit; these suites inspect exit codes themselves
        ROOT="$DEVENV_ROOT"; cd "$ROOT" || exit 1
        FX="$ROOT/task-modules/fixtures"
        TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
        export FAKE_LOG="$TMP/calls.log"
        PASS=0; FAIL=0
        ok() { PASS=$((PASS+1)); }
        bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
        printf '{"schema_version":1,"hosts":[{"name":"acer-swift","ssh":null},{"name":"lenovo","ssh":"lukas@lenovo.lan"}],"repos":[]}' > "$TMP/fleet.json"
        run() { # <task> <input-json> [args]
          local task="$1" in="$2"; shift 2
          devenv tasks run "$task" --option coordinator.fleetFile:path "$TMP/fleet.json" --option coordinator.sshCommand:string "${config.coordinator.fakes}/bin/ssh" \
            --option coordinator.herdrCommand:string "${config.coordinator.fakes}/bin/herdr" --option coordinator.stateDir:string "$TMP/state" --option coordinator.timeoutSeconds:int 1 \
            --option coordinator.messageTimeoutSeconds:int 1 --show-output --input-json "$in" "$@" > "$TMP/run.log" 2>&1; CODE=$?
          OUT=$(grep -E '^\s*\{"schema_version":1' "$TMP/run.log" | tail -1 | sed -E 's/^\s+//'); [ -n "$OUT" ] || OUT='{}'
        }
        jqr() { jq -r "$1" <<<"$OUT"; }
        audit() { cat "$TMP/state/audit.jsonl" 2>/dev/null; }

        draft='{"host":"lenovo","agent_id":"wA:p2","task_ref":"#42","scope":"Add rounding tests","expected_evidence":"PR","acceptance":"green tests"}'
        run coord:handoff "$draft"; id=$(jqr .handoff_id); [ "''${#id}" = 12 ] && ok || bad "setup: draft ($OUT)"

        # refusals before anything is sent
        : > "$FAKE_LOG"
        run herdr:message '{"handoff_id":"zzzz"}'; [ "$(jqr .error.kind)" = invalid_input ] && ok || bad "bad id: $(jqr .error.kind)"
        run herdr:message "{\"handoff_id\":\"$id\"}"; [ "$(jqr .error.kind)" = not_confirmed ] && ok || bad "no confirm: $(jqr .error.kind)"
        run herdr:message "{\"handoff_id\":\"$id\",\"confirm\":\"acer-swift/wA:p2\"}"; [ "$(jqr .error.kind)" = not_confirmed ] && ok || bad "wrong host confirm: $(jqr .error.kind)"
        run herdr:message "{\"handoff_id\":\"$id\",\"confirm\":\"lenovo/wF:p1\"}"; [ "$(jqr .error.kind)" = not_confirmed ] && ok || bad "wrong agent confirm: $(jqr .error.kind)"
        grep -q 'agent prompt' "$FAKE_LOG" && bad "refusals: nothing may be sent" || ok
        [ -s "$TMP/state/audit.jsonl" ] && bad "refusals: no audit attempt" || ok

        # blocked target is refused, no prompt, no audit attempt
        FAKE_HERDR_STATE=blocked run herdr:message "{\"handoff_id\":\"$id\",\"confirm\":\"lenovo/wA:p2\"}"
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = agent_blocked ] && ok || bad "blocked: $(jqr .error.kind)"
        grep -q 'agent prompt' "$FAKE_LOG" && bad "blocked: prompt must not be sent" || ok
        [ "$(audit | grep -c attempt)" = 0 ] && ok || bad "blocked: no audit attempt"

        # happy path over ssh: attempt + outcome audited, draft marked sent, receipt true, accepted false
        : > "$FAKE_LOG"
        FAKE_HERDR_STATE=idle run herdr:message "{\"handoff_id\":\"$id\",\"confirm\":\"lenovo/wA:p2\"}"
        [ "$CODE" -eq 0 ] && ok || bad "send: exit $CODE ($(tail -3 "$TMP/run.log"))"
        [ "$(jqr .outcome)" = delivered ] && [ "$(jqr .receipt)" = true ] && [ "$(jqr .accepted)" = false ] && ok || bad "send: fields ($OUT)"
        grep -q 'herdr agent prompt wA:p2 Assignment' "$FAKE_LOG" && ok || bad "send: argv ($(grep prompt "$FAKE_LOG"))"
        [ "$(audit | jq -r 'select(.phase=="attempt") | .handoff_id')" = "$id" ] && ok || bad "send: audit attempt"
        [ "$(audit | jq -r 'select(.phase=="outcome") | .outcome')" = delivered ] && ok || bad "send: audit outcome"
        [ "$(audit | jq -r 'select(.phase=="attempt") | .session_id')" = sess-1 ] && ok || bad "send: attempt records the session"
        aid=$(jqr .audit_id)
        # a working agent is not a target: no queued prompts
        run coord:handoff "$(jq -c '.scope = "busy"' <<<"$draft")"; idb=$(jqr .handoff_id)
        : > "$FAKE_LOG"; n_att=$(audit | grep -c attempt)
        FAKE_HERDR_STATE=working run herdr:message "{\"handoff_id\":\"$idb\",\"confirm\":\"lenovo/wA:p2\"}"; [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = agent_busy ] && ok || bad "working target: $(jqr .error.kind)"
        grep -q 'agent prompt' "$FAKE_LOG" && bad "busy: nothing may be sent" || ok; [ "$(audit | grep -c attempt)" = "$n_att" ] && ok || bad "busy: no attempt"
        FAKE_HERDR_MISSING=wA:p2 run herdr:message "{\"handoff_id\":\"$idb\",\"confirm\":\"lenovo/wA:p2\"}"; [ "$(jqr .error.kind)" = agent_not_found ] && ok || bad "missing agent on get: $(jqr .error.kind)"

        # duplicate: same handoff refused unless resend names the prior audit id
        : > "$FAKE_LOG"
        run herdr:message "{\"handoff_id\":\"$id\",\"confirm\":\"lenovo/wA:p2\"}"
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = duplicate ] && ok || bad "dup: $(jqr .error.kind)"
        jqr .error.message | grep -q "$aid" && ok || bad "dup: message names prior audit id"
        jqr .error.message | grep -q 'only the owner' && ok || bad "dup: message says the owner decides"
        grep -q 'agent prompt' "$FAKE_LOG" && bad "dup: nothing sent" || ok
        run herdr:message "{\"handoff_id\":\"$id\",\"confirm\":\"lenovo/wA:p2\",\"resend\":\"$aid\"}"
        [ "$CODE" -eq 0 ] && [ "$(jqr .outcome)" = delivered ] && ok || bad "resend: $(jqr .outcome)"
        [ "$(audit | grep -c '"phase":"attempt"')" = 2 ] && ok || bad "resend: second attempt audited"

        # prompt timeout => unknown_delivery, exit non-zero, audited; a later resend is refused when the agent's seq advanced (probably received)
        run coord:handoff "$(jq -c '.scope = "second task"' <<<"$draft")"; id2=$(jqr .handoff_id)
        FAKE_HERDR_PROMPT=timeout run herdr:message "{\"handoff_id\":\"$id2\",\"confirm\":\"lenovo/wA:p2\"}"
        [ "$CODE" -ne 0 ] && [ "$(jqr .outcome)" = unknown_delivery ] && [ "$(jqr .error.kind)" = unknown_delivery ] && ok || bad "timeout: $(jqr .outcome)/$(jqr .error.kind)"
        [ "$(audit | jq -r --arg i "$id2" 'select(.handoff_id==$i and .phase=="outcome") | .outcome')" = unknown_delivery ] && ok || bad "timeout: audited"
        aid2=$(jqr .audit_id)
        run herdr:message "{\"handoff_id\":\"$id2\",\"confirm\":\"lenovo/wA:p2\"}"; [ "$(jqr .error.kind)" = duplicate ] && ok || bad "timeout then retry must hit duplicate guard"
        FAKE_HERDR_SEQ=9 run herdr:message "{\"handoff_id\":\"$id2\",\"confirm\":\"lenovo/wA:p2\",\"resend\":\"$aid2\"}"
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = probably_received ] && ok || bad "resend after seq advance must be refused ($(jqr .error.kind))"
        FAKE_HERDR_SEQ=7 run herdr:message "{\"handoff_id\":\"$id2\",\"confirm\":\"lenovo/wA:p2\",\"resend\":\"$aid2\"}"
        [ "$CODE" -eq 0 ] && [ "$(jqr .outcome)" = delivered ] && ok || bad "resend with unchanged seq goes through ($(jqr .error.kind))"
        # herdr-side blocked race: prompt rejected with agent_blocked after get said idle; a later resend after the seq moved is still allowed (nothing was delivered)
        run coord:handoff "$(jq -c '.scope = "third"' <<<"$draft")"; id3=$(jqr .handoff_id)
        FAKE_HERDR_PROMPT=blocked run herdr:message "{\"handoff_id\":\"$id3\",\"confirm\":\"lenovo/wA:p2\"}"
        [ "$CODE" -ne 0 ] && [ "$(jqr .outcome)" = agent_blocked ] && ok || bad "race: $(jqr .outcome)"
        aid3=$(jqr .audit_id)
        FAKE_HERDR_SEQ=50 run herdr:message "{\"handoff_id\":\"$id3\",\"confirm\":\"lenovo/wA:p2\",\"resend\":\"$aid3\"}"
        [ "$CODE" -eq 0 ] && [ "$(jqr .outcome)" = delivered ] && ok || bad "resend after a definite refusal must be allowed ($(jqr .error.kind))"
        # a stalled prompt is delivery-unknown, so a resend after the seq moved is refused
        run coord:handoff "$(jq -c '.scope = "stall"' <<<"$draft")"; ids=$(jqr .handoff_id)
        FAKE_HERDR_PROMPT=stalled run herdr:message "{\"handoff_id\":\"$ids\",\"confirm\":\"lenovo/wA:p2\"}"
        [ "$CODE" -ne 0 ] && [ "$(jqr .outcome)" = agent_prompt_stalled ] && jqr .error.message | grep -q 'input box' && ok || bad "stalled: $(jqr .outcome) $(jqr .error.message)"
        aids=$(jqr .audit_id); FAKE_HERDR_SEQ=8 run herdr:message "{\"handoff_id\":\"$ids\",\"confirm\":\"lenovo/wA:p2\",\"resend\":\"$aids\"}"
        [ "$(jqr .error.kind)" = probably_received ] && ok || bad "stalled then seq advance: $(jqr .error.kind)"
        # unknown -> resend refused by herdr (blocked) -> block cleared and seq moved -> the next resend is still refused (first attempt unconfirmed)
        run coord:handoff "$(jq -c '.scope = "chain"' <<<"$draft")"; idc=$(jqr .handoff_id)
        FAKE_HERDR_PROMPT=timeout run herdr:message "{\"handoff_id\":\"$idc\",\"confirm\":\"lenovo/wA:p2\"}"; aidc1=$(jqr .audit_id)
        FAKE_HERDR_PROMPT=blocked run herdr:message "{\"handoff_id\":\"$idc\",\"confirm\":\"lenovo/wA:p2\",\"resend\":\"$aidc1\"}"; aidc2=$(jqr .audit_id); [ "$(jqr .outcome)" = agent_blocked ] && ok || bad "chain: second attempt blocked ($(jqr .outcome))"
        FAKE_HERDR_SEQ=30 run herdr:message "{\"handoff_id\":\"$idc\",\"confirm\":\"lenovo/wA:p2\",\"resend\":\"$aidc2\"}"
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = probably_received ] && ok || bad "chain: seq advanced after an unconfirmed first attempt must refuse ($(jqr .error.kind))"
        # ordering of the resend guard: delivered -> unknown -> resend must REFUSE once the seq moved; unknown -> delivered -> resend must ALLOW
        run coord:handoff "$(jq -c '.scope = "order1"' <<<"$draft")"; ido=$(jqr .handoff_id)
        run herdr:message "{\"handoff_id\":\"$ido\",\"confirm\":\"lenovo/wA:p2\"}"; a1=$(jqr .audit_id); [ "$(jqr .outcome)" = delivered ] && ok || bad "order1: first delivered"
        FAKE_HERDR_PROMPT=timeout run herdr:message "{\"handoff_id\":\"$ido\",\"confirm\":\"lenovo/wA:p2\",\"resend\":\"$a1\"}"; a2=$(jqr .audit_id); [ "$(jqr .outcome)" = unknown_delivery ] && ok || bad "order1: second unknown"
        FAKE_HERDR_SEQ=40 run herdr:message "{\"handoff_id\":\"$ido\",\"confirm\":\"lenovo/wA:p2\",\"resend\":\"$a2\"}"
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = probably_received ] && ok || bad "order1: delivered->unknown->seq moved must refuse ($(jqr .error.kind))"
        run coord:handoff "$(jq -c '.scope = "order2"' <<<"$draft")"; ido2=$(jqr .handoff_id)
        FAKE_HERDR_PROMPT=timeout run herdr:message "{\"handoff_id\":\"$ido2\",\"confirm\":\"lenovo/wA:p2\"}"; b1=$(jqr .audit_id)
        run herdr:message "{\"handoff_id\":\"$ido2\",\"confirm\":\"lenovo/wA:p2\",\"resend\":\"$b1\"}"; b2=$(jqr .audit_id); [ "$(jqr .outcome)" = delivered ] && ok || bad "order2: second delivered"
        FAKE_HERDR_SEQ=41 run herdr:message "{\"handoff_id\":\"$ido2\",\"confirm\":\"lenovo/wA:p2\",\"resend\":\"$b2\"}"
        [ "$CODE" -eq 0 ] && [ "$(jqr .outcome)" = delivered ] && ok || bad "order2: unknown->delivered->resend must be allowed ($(jqr .error.kind))"
        # an unconfirmed attempt followed by a seq going BACKWARDS means a restart: refuse the resend, record nothing
        run coord:handoff "$(jq -c '.scope = "restart"' <<<"$draft")"; idr=$(jqr .handoff_id)
        FAKE_HERDR_PROMPT=timeout run herdr:message "{\"handoff_id\":\"$idr\",\"confirm\":\"lenovo/wA:p2\"}"; r1=$(jqr .audit_id); n_att=$(audit | grep -c attempt)
        FAKE_HERDR_SEQ=3 run herdr:message "{\"handoff_id\":\"$idr\",\"confirm\":\"lenovo/wA:p2\",\"resend\":\"$r1\"}"
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = agent_restarted ] && [ "$(audit | grep -c attempt)" = "$n_att" ] && ok || bad "restart: seq backwards after unconfirmed attempt must refuse ($(jqr .error.kind))"
        # a bad object in the MIDDLE of the audit is corruption
        tmpa=$(mktemp); { head -1 "$TMP/state/audit.jsonl"; echo '{"audit_id":5,"phase":"attempt"}'; tail -n +2 "$TMP/state/audit.jsonl"; } > "$tmpa"; cp "$TMP/state/audit.jsonl" "$TMP/audit.bak"; mv "$tmpa" "$TMP/state/audit.jsonl"
        run herdr:message "{\"handoff_id\":\"$ido2\",\"confirm\":\"lenovo/wA:p2\"}"; [ "$(jqr .error.kind)" = audit_corrupt ] && ok || bad "bad object mid-file: $(jqr .error.kind)"
        mv "$TMP/audit.bak" "$TMP/state/audit.jsonl"
        # an attempt line without an outcome (killed mid-send) is delivery-unknown for await, not "nothing delivered"
        printf '%s\n' '{"audit_id":"abcdefabcdef","handoff_id":"'"$idc"'","phase":"attempt","host":"lenovo","agent_id":"wA:p2","session_id":"sess-1","at":"2026-10-26T00:00:00Z","confirm":"lenovo/wA:p2","state_before":"idle","seq_before":7}' >> "$TMP/state/audit.jsonl"
        rm -f "$FAKE_LOG.seq"; FAKE_HERDR_STATE_SEQ="idle,working,idle" run herdr:await '{"audit_id":"abcdefabcdef","timeout_s":5}'
        [ "$CODE" -eq 0 ] && [ "$(jqr .delivery)" = interrupted ] && ok || bad "await interrupted attempt proceeds with delivery=interrupted ($(jqr .delivery) $(jqr .error.kind))"
        # a non-object JSON line in the audit is corruption, not a silent skip
        printf '1\n' >> "$TMP/state/audit.jsonl"
        run herdr:message "{\"handoff_id\":\"$idc\",\"confirm\":\"lenovo/wA:p2\"}"; [ "$(jqr .error.kind)" = audit_corrupt ] && ok || bad "non-object audit line: $(jqr .error.kind)"
        sed -i '/^1$/d' "$TMP/state/audit.jsonl"
        # await on an undelivered attempt is refused
        run herdr:await "{\"audit_id\":\"$aid3\",\"timeout_s\":5}"; [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = not_delivered ] && ok || bad "await undelivered: $(jqr .error.kind)"
        rm -f "$FAKE_LOG.seq"; FAKE_HERDR_STATE_SEQ="idle,working,idle" run herdr:await "{\"audit_id\":\"$aids\",\"timeout_s\":5}"
        [ "$CODE" -eq 0 ] && [ "$(jqr .delivery)" = agent_prompt_stalled ] && ok || bad "await after a stall proceeds but reports delivery ($(jqr .delivery))"
        # fail closed on unusable `agent get` output: no send, no attempt
        run coord:handoff "$(jq -c '.scope = "fourth"' <<<"$draft")"; id4=$(jqr .handoff_id); : > "$FAKE_LOG"; n_before=$(audit | grep -c attempt)
        FAKE_HERDR_GET_RAW='not json' run herdr:message "{\"handoff_id\":\"$id4\",\"confirm\":\"lenovo/wA:p2\"}"
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = agent_state_unknown ] && ok || bad "malformed get: $(jqr .error.kind)"
        FAKE_HERDR_GET_RAW='{"result":{"agent":{"pane_id":"wA:p2"}}}' run herdr:message "{\"handoff_id\":\"$id4\",\"confirm\":\"lenovo/wA:p2\"}"
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = agent_state_unknown ] && ok || bad "wrong-shape get: $(jqr .error.kind)"
        grep -q 'agent prompt' "$FAKE_LOG" && bad "unusable get: nothing may be sent" || ok
        [ "$(audit | grep -c attempt)" = "$n_before" ] && ok || bad "unusable get: no attempt recorded"
        # agent identity: a draft bound to a session is refused when the pane runs another session
        run coord:handoff "$(jq -c '.scope = "fifth" | .session_id = "sess-1"' <<<"$draft")"; id5=$(jqr .handoff_id)
        FAKE_HERDR_SESSION=sess-2 run herdr:message "{\"handoff_id\":\"$id5\",\"confirm\":\"lenovo/wA:p2\"}"
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = agent_changed ] && ok || bad "session mismatch: $(jqr .error.kind)"
        run herdr:message "{\"handoff_id\":\"$id5\",\"confirm\":\"lenovo/wA:p2\"}"; [ "$CODE" -eq 0 ] && ok || bad "session match sends ($(jqr .error.kind))"
        # edited draft is refused (content-addressed id)
        run coord:handoff "$(jq -c '.scope = "sixth"' <<<"$draft")"; id6=$(jqr .handoff_id)
        jq '.text = "tampered"' "$TMP/state/handoffs/$id6.json" > "$TMP/t.json" && mv "$TMP/t.json" "$TMP/state/handoffs/$id6.json"
        run herdr:message "{\"handoff_id\":\"$id6\",\"confirm\":\"lenovo/wA:p2\"}"; [ "$(jqr .error.kind)" = invalid_input ] && jqr .error.message | grep -q 'does not match' && ok || bad "tampered draft refused ($(jqr .error.kind))"
        # byte-exact delivery through the remote path: quotes, $(id), backtick, newline, unicode
        weird=$(printf 'Scope with '"'"'single'"'"' and "double" quotes, $(id), `uname`, a\\backslash and ünïcödé\nsecond line')
        run coord:handoff "$(jq -cn --arg s "$weird" '{host:"lenovo",agent_id:"wA:p2",task_ref:"#7",scope:$s,expected_evidence:"e",acceptance:"a"}')"; id7=$(jqr .handoff_id); [ -n "$id7" ] && ok || bad "weird draft ($OUT)"
        FAKE_PROMPT_OUT="$TMP/prompt.txt" run herdr:message "{\"handoff_id\":\"$id7\",\"confirm\":\"lenovo/wA:p2\"}"
        [ "$CODE" -eq 0 ] && ok || bad "weird: send ($(jqr .error.kind))"
        jq -r .text "$TMP/state/handoffs/$id7.json" > "$TMP/expected.txt"; printf '%s' "$(cat "$TMP/expected.txt")" > "$TMP/expected.txt"
        cmp -s "$TMP/prompt.txt" "$TMP/expected.txt" && ok || bad "weird: text not byte-identical over ssh/fish/bash ($(diff "$TMP/prompt.txt" "$TMP/expected.txt" | head -3))"
        # audit corruption fails closed
        printf 'not json\n' >> "$TMP/state/audit.jsonl"
        run coord:handoff "$(jq -c '.scope = "eighth"' <<<"$draft")"; id8=$(jqr .handoff_id)
        run herdr:message "{\"handoff_id\":\"$id8\",\"confirm\":\"lenovo/wA:p2\"}"; [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = audit_corrupt ] && ok || bad "corrupt audit: $(jqr .error.kind)"
        sed -i '/^not json$/d' "$TMP/state/audit.jsonl"

        # await: the turn must start before it can end
        : > "$FAKE_LOG"; rm -f "$FAKE_LOG.seq"
        FAKE_HERDR_STATE_SEQ="idle,working,done" run herdr:await '{"host":"lenovo","agent_id":"wA:p2","timeout_s":5}'
        [ "$CODE" -eq 0 ] && [ "$(jqr .herdr_state)" = "done" ] && [ "$(jqr .turn_observed)" = true ] && [ "$(jqr .worker_done)" = true ] && [ "$(jqr .accepted)" = false ] && ok || bad "await idle→working→done: $OUT"
        grep -q 'herdr agent wait wA:p2 --until working --until blocked --timeout 5000' "$FAKE_LOG" && ok || bad "await: phase-1 argv"
        grep -q 'herdr agent wait wA:p2 --until idle --until done --until blocked --timeout' "$FAKE_LOG" && ok || bad "await: phase-2 argv"
        rm -f "$FAKE_LOG.seq"; FAKE_HERDR_STATE_SEQ="working,idle" run herdr:await '{"host":"lenovo","agent_id":"wA:p2","timeout_s":5}'
        [ "$CODE" -eq 0 ] && [ "$(jqr .herdr_state)" = idle ] && ok || bad "await already working: $OUT"
        rm -f "$FAKE_LOG.seq"; FAKE_HERDR_STATE_SEQ="idle,idle,idle" run herdr:await '{"host":"lenovo","agent_id":"wA:p2","timeout_s":3,"start_timeout_s":1}'
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = no_turn_observed ] && [ "$(jqr .turn_observed)" = false ] && jqr .error.message | grep -q 'Do not resend' && ok || bad "await stale idle: $OUT"
        # await by audit_id: host/agent/since/session come from the attempt record
        last_aid=$(audit | jq -r 'select(.phase=="attempt" and .handoff_id=="'"$id5"'") | .audit_id' | tail -1)
        rm -f "$FAKE_LOG.seq"; FAKE_HERDR_SEQ=12 FAKE_HERDR_STATE_SEQ="idle,idle" run herdr:await "{\"audit_id\":\"$last_aid\",\"timeout_s\":5}"
        [ "$CODE" -eq 0 ] && [ "$(jqr .turn_observed)" = true ] && [ "$(jqr .audit_id)" = "$last_aid" ] && [ "$(jqr .host)" = lenovo ] && ok || bad "await by audit_id with seq advanced: $OUT"
        rm -f "$FAKE_LOG.seq"; FAKE_HERDR_SESSION=sess-9 FAKE_HERDR_SEQ=12 run herdr:await "{\"audit_id\":\"$last_aid\",\"timeout_s\":5}"
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = agent_changed ] && ok || bad "await: session changed since the message ($(jqr .error.kind))"
        rm -f "$FAKE_LOG.seq"; FAKE_HERDR_SEQ=3 run herdr:await "{\"audit_id\":\"$last_aid\",\"timeout_s\":5}"
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = agent_restarted ] && ok || bad "await: seq went backwards => restarted ($(jqr .error.kind))"
        run herdr:await '{"audit_id":"000000000000","timeout_s":5}'; [ "$(jqr .error.kind)" = invalid_input ] && ok || bad "await: unknown audit id"
        rm -f "$FAKE_LOG.seq"; FAKE_HERDR_STATE_SEQ="blocked" run herdr:await '{"host":"lenovo","agent_id":"wA:p2","timeout_s":5}'
        [ "$(jqr .needs_owner)" = true ] && [ "$(jqr .worker_done)" = false ] && ok || bad "await blocked"
        rm -f "$FAKE_LOG.seq"; FAKE_HERDR_STATE_SEQ="working,working" run herdr:await '{"host":"lenovo","agent_id":"wA:p2","timeout_s":1}'
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = timeout ] && [ "$(jqr .turn_observed)" = true ] && [ "$(jqr .reached)" = false ] && ok || bad "await timeout: $OUT"
        FAKE_HERDR_MISSING=wA:p2 run herdr:await '{"host":"lenovo","agent_id":"wA:p2","timeout_s":5}'
        [ "$CODE" -ne 0 ] && [ "$(jqr .error.kind)" = agent_not_found ] && ok || bad "await: agent gone ($(jqr .error.kind))"
        run herdr:await '{"host":"lenovo","agent_id":"wA:p2","timeout_s":99999}'; [ "$(jqr .error.kind)" = invalid_input ] && ok || bad "await: timeout bound"
        run herdr:await '{"host":"lenovo","agent_id":"wA:p2","timeout_s":5,"start_timeout_s":"x"}'; [ "$(jqr .error.kind)" = invalid_input ] && ok || bad "await: start_timeout validation"
        run herdr:await '{"host":"lenovo","agent_id":"x; id"}'; [ "$(jqr .error.kind)" = invalid_input ] && ok || bad "await: id validation"
        run herdr:await '{"host":"nope","agent_id":"wA:p2"}'; [ "$(jqr .error.kind)" = invalid_input ] && ok || bad "await: wrong host"

        echo "passed=$PASS failed=$FAIL"; [ "$FAIL" -eq 0 ]
      '';
    };
  };
}
