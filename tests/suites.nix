# Repo-level suites as devenv tasks. hooks and manifests wrap the pre-existing scripts of the hook framework.
{ config, lib, ... }:
{
  tasks = {
    "skills:test:policy" = {
      description = "No owner-stand-in language anywhere in skills, agents or docs";
      exec = ''
        # Policy gate: nothing an agent reads may let it stand in for the owner on
        # privileged decisions (epic #16 M0). Run: bash tests/test-policy.sh
        set +e -uo pipefail   # the task runner enables errexit; these suites inspect exit codes themselves
        ROOT="$DEVENV_ROOT"
        cd "$ROOT" || exit 1
        FAIL=0

        while IFS= read -r f; do
          if grep -nEi '\bstand(s|ing)?[- ]in\b|\bstood in\b|\bstand[- ]ins\b|acting for the owner' "$f"; then
            echo "FAIL: $f contains owner stand-in language" >&2; FAIL=1
          fi
        done < <(find global-context.md README.md skills agents docs -type f -not -path 'docs/plans/*' -not -path '*/.archived/*')

        if ! grep -qEi 'may not approve|cannot approve|AI review is evidence' "$ROOT/global-context.md"; then
          echo "FAIL: global-context.md does not state that agents cannot approve privileged actions" >&2; FAIL=1
        fi

        [ "$FAIL" -eq 0 ] && echo "PASS: policy gate" || exit 1
      '';
    };
    "skills:test:contract" = {
      description = "ROLE.md <-> adapters <-> tasks agreement for every role; awk/yq parity; adversarial role fixtures";
      exec = ''
        ${config.coordinator.guardLib}
        # Contract test: every role's ROLE.md frontmatter, its adapters, its permissions.json
        # and the shared guard parser agree, and every named skill/task exists.
        # Run inside the devenv (needs yq-go, jq): bash tests/test-role-contract.sh
        set +e -uo pipefail   # the task runner enables errexit; these suites inspect exit codes themselves
        ROOT="$DEVENV_ROOT"
        cd "$ROOT" || exit 1
        FAIL=0; PASS=0
        ok() { PASS=$((PASS+1)); }
        bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }

        TASKS="$(devenv tasks list --option coordinator.fleetFile:path "$ROOT/task-modules/fixtures/fleet-empty.json" 2>/dev/null | grep -oE '[a-z0-9_-]+(:[a-z0-9_-]+)+' | sort -u)"
        [ -n "$TASKS" ] || { echo "FAIL: devenv tasks list returned nothing"; exit 1; }

        for role_md in agents/*/ROLE.md; do
          dir="$(dirname "$role_md")"; role="$(basename "$dir")"
          fm="$(yq --front-matter=extract -o=json '.' "$role_md")" || { bad "$role: frontmatter not parseable"; continue; }
          [ "$(jq -r .name <<<"$fm")" = "$role" ] && ok || bad "$role: name != directory"
          [ "$(jq -r .version <<<"$fm")" = "1" ] && ok || bad "$role: version must be 1"
          jq -e '(.tasks.read | type == "array" and length > 0) and (.tasks.act | type == "array") and (.skills | type == "array" and length > 0)' <<<"$fm" >/dev/null && ok || bad "$role: tasks.read, tasks.act and skills must be lists"
          jq -e '.tasks.inputless | type == "array" and length > 0' <<<"$fm" >/dev/null && ok || bad "$role: tasks.inputless must be a non-empty list"

          for s in $(jq -r '.skills[]' <<<"$fm"); do
            [ -f "skills/$s/SKILL.md" ] && ok || bad "$role: skill $s missing"
          done
          for t in $(jq -r '.tasks.read[], (.tasks.run // [])[], .tasks.act[]' <<<"$fm"); do
            grep -qxF "$t" <<<"$TASKS" && ok || bad "$role: task $t not in devenv tasks list"
          done
          [ "$(jq '.forbidden|length' <<<"$fm")" -ge 5 ] && ok || bad "$role: forbidden list too short"

          # the shared guard must read the same lists the contract declares (the shipped awk == yq)
          for key in read run act inputless; do
            want=$(jq -r --arg k "$key" '(.tasks[$k] // []) | join("|")' <<<"$fm")
            have=$(role_list_awk "$key" "$role_md" | paste -sd'|' -) || { bad "$role: guard parser rejected the contract"; continue; }
            [ "$want" = "$have" ] && ok || bad "$role: guard parser reads tasks.$key as '$have', contract says '$want'"
          done

          perms="$dir/permissions.json"
          [ -f "$perms" ] || { bad "$role: permissions.json missing"; continue; }
          # input-less read tasks (declared in ROLE.md tasks.inputless) get exact settings rules; the rest are guard-only
          for t in $(jq -r '.tasks.inputless[]?' <<<"$fm"); do
            jq -e --arg t "$t" '.tasks.read | index($t)' <<<"$fm" >/dev/null && ok || bad "$role: inputless task $t is not a read task"
            jq -e --arg r "Bash(devenv tasks run ''${t})" '.allow|index($r)' "$perms" >/dev/null && ok || bad "$role: exact rule for $t missing"
          done
          for t in $(jq -r '.tasks.act[]' <<<"$fm"); do
            jq -e --arg t "$t" '[.allow[] | select(contains($t))] | length == 0' "$perms" >/dev/null && ok || bad "$role: act task $t is allowlisted"
            jq -e --arg t "$t" '[.ask[] | select(contains($t))] | length > 0' "$perms" >/dev/null && ok || bad "$role: act task $t not in ask"
          done
          # every Bash allow rule names an inputless read task; nothing else is allowed besides a scoped Read
          extra=$(jq -r --argjson r "$(jq -c '.tasks.inputless' <<<"$fm")" '.allow[] | select(startswith("Bash(")) | ((capture("^Bash\\(devenv tasks run (?<t>[a-z0-9_-]+(:[a-z0-9_-]+)+)( --show-output)?\\)$").t) // "<malformed>") | select(. as $t | ($r | index($t)) == null)' "$perms") || { bad "$role: allow-rule filter failed"; extra=""; }
          [ -z "$extra" ] && ok || bad "$role: Bash allow rules outside the inputless read tasks: $extra"
          jq -e --arg r "$role" '[.allow[] | select(startswith("Bash(") | not)] | . == ["Read(./**)"] or . == ["Read(./**)", "Read(~/.local/state/\($r)/**)"]' "$perms" >/dev/null && ok || bad "$role: Read must be scoped to the checkout (plus the role's state dir if it keeps one)"
          [ -x "$ROOT/$(jq -r .guard "$perms")" ] && ok || bad "$role: guard hook missing or not executable"

          for adapter in $(jq -r '.adapters[]' <<<"$fm"); do
            case "$adapter" in
              claude)
                f="agents/$role.md"; [ -f "$f" ] || { bad "$role: claude adapter $f missing"; continue; }
                afm="$(yq --front-matter=extract -o=json '.' "$f")"
                [ "$(jq -r .name <<<"$afm")" = "$role" ] && ok || bad "$role: claude adapter name mismatch"
                grep -q "ROLE.md" "$f" && ok || bad "$role: claude adapter does not point at ROLE.md"
                for s in $(jq -r '.skills[]' <<<"$fm"); do jq -e --arg s "$s" '.skills|index($s)' <<<"$afm" >/dev/null && ok || bad "$role: claude adapter does not preload $s"; done
                jq -e '[.tools[]] - ["Bash","Read"] | length == 0' <<<"$afm" >/dev/null && ok || bad "$role: claude adapter tools must be within Bash, Read"
                jq -e --arg g "$(basename "$(jq -r .guard "$perms")")" '[.hooks.PreToolUse[]? | select(.matcher=="Bash") | .hooks[] | select((.command | contains($g)) and (.command | contains("exit 2")) and (.command | contains("[ -x")))] | length == 1' <<<"$afm" >/dev/null && ok || bad "$role: claude adapter must wire the guard on Bash and fail closed when it is missing"
                ;;
              codex)
                f="agents/$role/AGENTS.md"
                if [ -f "$f" ]; then grep -q "ROLE.md" "$f" && ok || bad "$role: codex adapter does not point at ROLE.md"; else echo "note: $role codex adapter not yet present (M4)"; fi
                ;;
              *) bad "$role: unknown adapter $adapter" ;;
            esac
          done
        done

        # adversarial contracts: the guard parser must refuse every fixture under tests/fixtures/roles (fail closed, exit 3)
        for f in tests/fixtures/roles/*.md; do
          role_list_awk read "$f" >/dev/null 2>&1; rc=$?
          [ "$rc" -eq 3 ] && ok || bad "guard parser accepted $(basename "$f") (exit $rc)"
        done

        # every adapter that wires a role guard ships its contract: the dispatcher routes by name, so an adapter without
        # agents/<name>/ROLE.md would be an unguarded role
        for adapter in agents/*.md; do
          name=$(basename "$adapter" .md)
          if grep -qE "validate-(role|$name)\.sh" "$adapter"; then
            [ -f "agents/$name/ROLE.md" ] && ok || bad "$name: adapter wires a role guard but agents/$name/ROLE.md is missing"
          fi
        done
        echo "passed=$PASS failed=$FAIL"; [ "$FAIL" -eq 0 ]
      '';
    };
    "skills:test:negative" = {
      description = "Permission-rule emulator, guard grammar and dispatcher behaviour, integrity cases";
      exec = ''
        ${config.coordinator.guardLib}
        # shellcheck disable=SC2088  # literal ~ paths are what an agent would type into Read
        # Negative controls for the Coordinator surface (epic #16 M0): the portable
        # permission rules must not be able to express code changes, pushes, merges,
        # host switches, arbitrary SSH or the act-class herdr:message without a prompt.
        # Run: bash tests/test-coordinator-negative.sh
        set +e -uo pipefail   # the task runner enables errexit; these suites inspect exit codes themselves
        ROOT="$DEVENV_ROOT"
        # ---- Claude permission-rule emulator (inlined)
        # Reimplements the documented Claude Code permission-rule semantics for tests:
        # deny > ask > allow; `Bash(x:*)` == `x` or `x *`; `*` is a glob; compound
        # commands need every part allowed, and any part (incl. $(...)) can deny/ask.
        # Source it, then: permission_decision <permissions.json> <tool> [command]
        # prints deny|ask|allow|none.

        _rule_matches() { # <rule> <tool> <command>
          local rule="$1" tool="$2" cmd="$3" inner base
          if [[ "$rule" != *"("* ]]; then [[ "$rule" == "$tool" ]]; return; fi
          [[ "''${rule%%(*}" == "$tool" ]] || return 1
          inner="''${rule#*(}"; inner="''${inner%)}"
          if [[ "$inner" == *":*" ]]; then
            base="''${inner%:\*}"
            [[ "$cmd" == "$base" || "$cmd" == "$base "* ]]; return
          fi
          # shellcheck disable=SC2053
          [[ "$cmd" == $inner ]]
        }

        _strip_wrappers() { # drop documented leading wrappers from one subcommand
          local c="$1"
          c="''${c#"''${c%%[![:space:]]*}"}"; c="''${c%"''${c##*[![:space:]]}"}"
          while :; do
            case "$c" in
              "timeout "*) c="''${c#timeout }"; c="''${c#* }" ;;
              "time "*|"nice "*|"nohup "*|"command "*|"builtin "*|"stdbuf "*) c="''${c#* }" ;;
              *) break ;;
            esac
          done
          printf '%s' "$c"
        }

        _split_parts() { # compound separators -> one part per line, plus every $(...) and `...` body
          local cmd="$1" rest
          printf '%s\n' "$cmd" | sed -E 's/\|\||&&|;|\|&|\||&/\n/g'
          rest="$cmd"
          while grep -qE '\$\([^()]*\)' <<<"$rest"; do
            grep -oE '\$\([^()]*\)' <<<"$rest" | sed -E 's/^\$\((.*)\)$/\1/'
            rest=$(sed -E 's/\$\([^()]*\)/_/g' <<<"$rest")
          done
          grep -oE '`[^`]*`' <<<"$cmd" | tr -d '`' || true
        }

        _unallowable() { # substitutions, process substitution and redirections never auto-allow
          [[ "$1" == *'`'* || "$1" == *'$('* || "$1" == *'<('* || "$1" == *'>('* || "$1" == *'>'* || "$1" == *'<'* ]]
        }

        permission_decision() { # <permissions.json> <tool> [command]
          local file="$1" tool="$2" cmd="''${3:-}" list rule part decided
          for list in deny ask; do
            while IFS= read -r rule; do
              [ -n "$rule" ] || continue
              while IFS= read -r part; do
                part="$(_strip_wrappers "$part")"; [ -n "$part" ] || continue
                if _rule_matches "$rule" "$tool" "$part"; then echo "$list"; return 0; fi
              done < <(_split_parts "$cmd")
              [ -n "$cmd" ] || { _rule_matches "$rule" "$tool" "" && { echo "$list"; return 0; }; }
            done < <(jq -r ".''${list}[]?" "$file")
          done
          if [ -z "$cmd" ]; then
            while IFS= read -r rule; do _rule_matches "$rule" "$tool" "" && { echo allow; return 0; }; done < <(jq -r '.allow[]?' "$file")
            echo none; return 0
          fi
          [[ "$cmd" =~ (\&\&|\|\||;|\|\&|\||\&)[[:space:]]*$ ]] && { echo none; return 0; }
          _unallowable "$cmd" && { echo none; return 0; }
          while IFS= read -r part; do
            part="$(_strip_wrappers "$part")"; [ -n "$part" ] || continue
            decided=0
            while IFS= read -r rule; do
              _rule_matches "$rule" "$tool" "$part" && { decided=1; break; }
            done < <(jq -r '.allow[]?' "$file")
            [ "$decided" -eq 1 ] || { echo none; return 0; }
          done < <(printf '%s\n' "$cmd" | sed -E 's/\|\||&&|;|\|&|\||&/\n/g')
          echo allow
        }
        P="$ROOT/agents/coordinator/permissions.json"
        TMP_HOME_MISSING=$(mktemp -d); CLEANUP=("$TMP_HOME_MISSING"); trap 'rm -rf "''${CLEANUP[@]}"' EXIT
        PASS=0; FAIL=0

        expect() { # <want> <tool> <command>
          local got; got="$(permission_decision "$P" "$2" "''${3:-}")"
          if [ "$got" = "$1" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $2 ${"'"}''${3:-}' -> $got (want $1)"; fi
        }

        # read-class tasks are allowed without a prompt
        expect allow Bash "devenv tasks run coord:brief"
        expect allow Bash "devenv tasks run coord:brief --show-output"
        expect allow Bash "timeout 60 devenv tasks run work:status"
        expect allow Bash "timeout 60s devenv tasks run work:status"
        # calls that carry input are allowed only by the guard hook, so the settings rules prompt
        expect none Bash "devenv tasks run herdr:inspect --input-json '{\"host\":\"lenovo\",\"agent_id\":\"wF:p1\"}'"
        expect none Bash "devenv tasks run herdr:await --input-json '{\"host\":\"lenovo\",\"agent_id\":\"wF:p1\"}'"

        # act-class tasks always prompt
        expect ask Bash "devenv tasks run herdr:message --input-json '{}'"
        expect ask Bash "devenv tasks run coord:brief && devenv tasks run herdr:message --input-json '{}'"

        # bypass attempts found in review: multi-task runs, option overrides, redirections, substitutions
        expect none Bash "devenv tasks run coord:brief herdr:message"
        expect deny Bash "devenv tasks run coord:brief -O 'tasks.\"coord:brief\".exec:string' 'ssh lenovo id'"
        expect deny Bash "devenv tasks run gh:work --input-json '{}' -O 'tasks.\"gh:work\".exec:string' 'ssh lenovo id'"
        expect none Bash "devenv tasks run gh:work --input-json '{}' herdr:message"
        expect deny Bash "devenv tasks run coord:brief --from path:/tmp/evil"
        expect none Bash "devenv tasks run coord:brief > ~/.ssh/authorized_keys"
        expect deny Bash "devenv tasks run coord:brief \`ssh lenovo x\`"
        expect deny Bash "devenv tasks run coord:brief \$(ssh h \"\$(id)\")"
        expect none Bash "devenv tasks run coord:brief \$(cat ~/.ssh/id_ed25519)"
        expect none Bash "devenv tasks run coord:brief &"
        expect none Bash "devenv tasks run coord:brief |&"
        expect deny Read "~/.ssh/id_ed25519"
        expect deny Read "/run/secrets/claude_oauth_token"
        expect deny Read "~/.claude/.credentials.json"
        expect deny Read "~/.config/gh/hosts.yml"
        expect deny Read "~/.kube/config"

        # privileged or arbitrary operations are denied or at least never silently allowed
        expect deny Bash "ssh lenovo rm -rf /"
        expect deny Bash "git push origin main"
        expect deny Bash "gh pr merge 16"
        expect deny Bash "sudo nixos-rebuild switch --flake .#lenovo"
        expect deny Bash "kubectl delete ns kanban"
        expect deny Bash "rm -rf ~/skills-epic16"
        expect deny Bash "devenv tasks run coord:brief; ssh lenovo true"
        expect deny Bash "echo \$(ssh lenovo cat ~/.ssh/id_ed25519)"
        expect deny Edit
        expect deny Write
        expect none Bash "cargo build --release"
        expect none Bash "devenv tasks run skills:test"
        expect none Bash "devenv tasks run coordinate"
        expect none Bash "devenv tasks run coord:brief &&"
        expect none Bash "DEVENV_ROOT=/tmp/x devenv tasks run coord:brief"
        expect deny Read "~/.netrc"
        expect deny Read "~/.claude.json"
        expect allow Read "./agents/coordinator/ROLE.md"

        # the agent-scoped PreToolUse hook: strict grammar, allow for read tasks, ask for act tasks, block otherwise
        # guard_hook: the guard as the old CLI behaved (stdin payload; allow/ask JSON + exit 0, or reason on stderr + exit 2),
        # driven by the Nix-held guard_check; ROLE and COORDINATOR_CHECKOUT come from the environment
        guard_hook() { local payload dec d r; payload=$(cat); dec=$(guard_check "''${ROLE:-coordinator}" "$payload"); d=$(jq -r .decision <<<"$dec"); r=$(jq -r .reason <<<"$dec")
          if [ "$d" = block ]; then printf '%s\n' "$r" >&2; return 2; fi
          jq -cn --arg d "$d" --arg r "$r" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d,permissionDecisionReason:$r}}'; }
        HOOK=guard_hook
        export COORDINATOR_CHECKOUT="$ROOT"
        hook() { # <want: allow|ask|block> <command> [cwd]
          local out code dec
          out=$(jq -cn --arg c "$2" --arg d "''${3:-$ROOT}" '{session_id:"t",cwd:$d,tool_name:"Bash",tool_input:{command:$c}}' | "$HOOK" 2>/dev/null); code=$?
          dec=$(jq -r '.hookSpecificOutput.permissionDecision // empty' <<<"$out" 2>/dev/null)
          if [ "$1" = block ]; then [ "$code" -eq 2 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL(hook): '$2' -> exit $code dec=$dec (want block)"; }
          else [ "$code" -eq 0 ] && [ "$dec" = "$1" ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL(hook): '$2' -> exit $code dec=$dec (want $1)"; }; fi
        }
        hook allow "devenv tasks run coord:brief"
        hook allow "devenv tasks run coord:brief --show-output"
        hook allow "devenv tasks run herdr:inspect --input-json '{\"host\":\"lenovo\",\"agent_id\":\"wF:p1\",\"lines\":40}'"
        hook allow "devenv tasks run herdr:inventory --input-json '{\"host\":\"lenovo\"}' --show-output"
        hook ask   "devenv tasks run herdr:message --input-json '{\"handoff_id\":\"abc\"}'"
        hook block "devenv tasks run coord:brief herdr:message"
        hook block "devenv tasks run coord:brief -O 'tasks.\"coord:brief\".exec:string' 'ssh lenovo id'"
        hook block "devenv tasks run coord:brief > ~/.ssh/authorized_keys"
        hook block "devenv tasks run coord:brief \`ssh lenovo x\`"
        hook block "devenv tasks run coord:brief \$(id)"
        hook block "devenv tasks run coord:brief; ssh lenovo true"
        hook block "devenv tasks run coord:brief && ls"
        hook block "devenv tasks run skills:test"
        hook block "devenv tasks run coord:brief --input-json 'not json'"
        hook block "devenv tasks run coord:brief --input-json '[1]'"
        hook block "devenv tasks run coord:brief --input-json '{\"a\":\"x'\"'\"'y\"}'"
        hook block "devenv --from path:/tmp/evil tasks run coord:brief"
        hook block "timeout 60 devenv tasks run coord:brief"
        hook block "ssh lenovo herdr agent list"
        hook block "cat ~/.ssh/id_ed25519"
        hook block $'devenv tasks run coord:brief\nssh lenovo id'
        hook block $'devenv tasks run coord:brief\r'
        hook block ""
        hook block "devenv tasks run coord:brief --input-json '{} {}'"
        hook block "devenv tasks run coord:brief" "/tmp"
        hook block "devenv tasks run coord:handoff --input-json '{\"scope\":\"don'\"'\"'t\"}'"  # apostrophes need \u0027 in the body
        hook allow "devenv tasks run coord:handoff --input-json '{\"scope\":\"A & B | \$HOME; <x>\"}'"
        # no checkout anywhere (env unset, default path absent) must block; the default resolves when nothing is set
        ( unset COORDINATOR_CHECKOUT SKILLS_CHECKOUT; HOME=/nonexistent jq -cn --arg d "$ROOT" '{cwd:$d,tool_name:"Bash",tool_input:{command:"devenv tasks run coord:brief"}}' | ( HOME=/nonexistent guard_hook ) >/dev/null 2>&1; [ $? -eq 2 ] ) && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL(hook): no checkout at all must block"; }
        ( unset COORDINATOR_CHECKOUT; jq -cn --arg d "$ROOT" '{cwd:$d,tool_name:"Bash",tool_input:{command:"devenv tasks run coord:brief"}}' | ( SKILLS_CHECKOUT="$ROOT" guard_hook ) 2>/dev/null | jq -e '.hookSpecificOutput.permissionDecision=="allow"' >/dev/null ) && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL(hook): SKILLS_CHECKOUT fallback must allow"; }
        # subagent form: cd into exactly the checkout (plain absolute text, or ~/) from any cwd, joined with && only
        hook allow "cd $ROOT && devenv tasks run coord:brief" /tmp
        hook allow "cd $ROOT/ && devenv tasks run coord:brief" /tmp
        hook allow "cd $ROOT && devenv tasks run coord:brief --input-json '{}' --show-output" /tmp
        hook block "devenv tasks run coord:brief" /tmp
        hook block "cd /tmp && devenv tasks run coord:brief" /tmp
        hook block "cd $ROOT; devenv tasks run coord:brief" /tmp
        hook block "cd $ROOT || devenv tasks run coord:brief" /tmp
        hook block "cd $ROOT && devenv tasks run coord:brief && ssh lenovo id" /tmp
        hook block "cd $ROOT && cd /tmp && devenv tasks run coord:brief" /tmp
        hook block "cd \"$ROOT\" && devenv tasks run coord:brief" /tmp
        hook block "cd $ROOT/tests && devenv tasks run coord:brief" /tmp
        hook block "X=1 cd $ROOT && devenv tasks run coord:brief" /tmp
        hook block "cd -- $ROOT && devenv tasks run coord:brief" /tmp
        hook block "cd \$SKILLS_CHECKOUT && devenv tasks run coord:brief" /tmp
        # bash moves logically and expands ~+ ~- -: text that resolves physically to the checkout but is not its path is refused
        hook block "cd $ROOT/../$(basename "$ROOT") && devenv tasks run coord:brief" /tmp
        hook block "cd $ROOT/tests/.. && devenv tasks run coord:brief" /tmp
        hook block "cd $ROOT/./ && devenv tasks run coord:brief" /tmp
        hook block "cd /$ROOT && devenv tasks run coord:brief" /tmp
        SYMTMP=$(mktemp -d); CLEANUP+=("$SYMTMP"); ln -s "$ROOT/agents" "$SYMTMP/x"; ln -s "$ROOT" "$SYMTMP/~+"; ln -s "$ROOT" "$SYMTMP/-"
        hook block "cd x/.. && devenv tasks run coord:brief" "$SYMTMP"
        hook block "cd $SYMTMP/x/.. && devenv tasks run coord:brief" "$SYMTMP"
        hook block "cd ~+ && devenv tasks run coord:brief" "$SYMTMP"
        hook block "cd ~- && devenv tasks run coord:brief" "$SYMTMP"
        hook block "cd - && devenv tasks run coord:brief" "$SYMTMP"
        hook block "cd -P && devenv tasks run coord:brief" "$SYMTMP"
        hook block "cd ~root && devenv tasks run coord:brief" "$SYMTMP"
        rm -rf "$SYMTMP"
        # ~ and ~/ expand exactly as bash does
        ( out=$(jq -cn --arg c "cd ~ && devenv tasks run coord:brief" '{cwd:"/tmp",tool_name:"Bash",tool_input:{command:$c}}' | HOME="$ROOT" "$HOOK" 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecision // empty'); [ "$out" = allow ] ) && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL(hook): cd ~ with HOME=checkout must allow"; }
        HOMETMP=$(mktemp -d); CLEANUP+=("$HOMETMP"); ln -s "$ROOT" "$HOMETMP/claude-code-skills"
        ( out=$(jq -cn --arg c "cd ~/claude-code-skills && devenv tasks run coord:brief" '{cwd:"/tmp",tool_name:"Bash",tool_input:{command:$c}}' | ( unset COORDINATOR_CHECKOUT SKILLS_CHECKOUT; HOME="$HOMETMP" guard_hook ) 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecision // empty'); [ "$out" = allow ] ) && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL(hook): cd ~/claude-code-skills with the default checkout must allow"; }
        # the settings-level dispatcher: role agents go through the guard, everything else is a silent no-op
        DISPATCH="$ROOT/hooks/role-guard-dispatch.sh"
        dcase() { local label="$1" want_code="$2" want_dec="$3" payload="$4" out code dec; out=$(printf '%s' "$payload" | env -u COORDINATOR_CHECKOUT SKILLS_CHECKOUT="$ROOT" "$DISPATCH" 2>/dev/null); code=$?; dec=$(jq -r '.hookSpecificOutput.permissionDecision // empty' <<<"$out" 2>/dev/null); [ "$code" -eq "$want_code" ] && [ "$dec" = "$want_dec" ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL(dispatch): $label -> $code/'$dec' (want $want_code/'$want_dec')"; }; }
        dcase "coordinator subagent, allowed task" 0 allow "$(jq -cn --arg c "cd $ROOT && devenv tasks run coord:brief" '{cwd:"/tmp",agent_type:"coordinator",tool_name:"Bash",tool_input:{command:$c}}')"
        dcase "coordinator subagent, forbidden command" 2 "" "$(jq -cn '{cwd:"/tmp",agent_type:"coordinator",tool_name:"Bash",tool_input:{command:"echo hi"}}')"
        derr() { local label="$1" want="$2" payload="$3"; shift 3; local err code; err=$(printf '%s' "$payload" | env -u COORDINATOR_CHECKOUT -u SKILLS_CHECKOUT "$@" "$DISPATCH" 2>&1 >/dev/null); code=$?; [ "$code" -eq 2 ] && grep -q -- "$want" <<<"$err" && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL(dispatch): $label -> $code '$err' (want 2 + '$want')"; }; }
        FORBID="$(jq -cn --arg d "$ROOT" '{cwd:$d,agent_type:"coordinator",tool_name:"Bash",tool_input:{command:"echo hi"}}')"
        ALLOWED="$(jq -cn --arg c "cd $ROOT && devenv tasks run coord:brief" '{cwd:"/tmp",agent_type:"coordinator",tool_name:"Bash",tool_input:{command:$c}}')"
        derr "forbidden command is refused by the grammar, not by a missing guard" "only '\[cd <checkout> && \]devenv tasks run" "$FORBID" SKILLS_CHECKOUT="$ROOT"
        # a shipped role with no checkout, or a stale checkout without the contract, must REFUSE (never silently un-guard)
        derr "shipped role, no checkout at all" "has no agents/coordinator/ROLE.md" "$ALLOWED" HOME=/nonexistent
        STALE=$(mktemp -d); CLEANUP+=("$STALE"); mkdir -p "$STALE/hooks" "$STALE/agents"
        derr "shipped role, stale checkout without the contract" "missing or stale" "$ALLOWED" SKILLS_CHECKOUT="$STALE"
        derr "checkout path with .. is refused" "must be absolute and plain" "$ALLOWED" SKILLS_CHECKOUT="$ROOT/../$(basename "$ROOT")"
        rm -rf "$STALE"
        # the decision comes from `devenv tasks run guard:check`; a devenv that fails or decides nothing is a block
        CRASH=$(mktemp -d); CLEANUP+=("$CRASH"); mkdir -p "$CRASH/bin"; printf '#!/usr/bin/env bash\nexit 1\n' > "$CRASH/bin/devenv"; chmod +x "$CRASH/bin/devenv"
        err=$(printf '%s' "$ALLOWED" | env -u COORDINATOR_CHECKOUT SKILLS_CHECKOUT="$ROOT" PATH="$CRASH/bin:$PATH" "$DISPATCH" 2>&1 >/dev/null); code=$?; [ "$code" -eq 2 ] && grep -q 'guard did not decide (devenv rc=1)' <<<"$err" && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL(dispatch): a failing devenv must map to exit 2"; }
        printf '#!/usr/bin/env bash\nexit 0\n' > "$CRASH/bin/devenv"
        err=$(printf '%s' "$ALLOWED" | env -u COORDINATOR_CHECKOUT SKILLS_CHECKOUT="$ROOT" PATH="$CRASH/bin:$PATH" "$DISPATCH" 2>&1 >/dev/null); code=$?; [ "$code" -eq 2 ] && grep -q 'guard did not decide' <<<"$err" && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL(dispatch): a devenv that writes no decision must map to exit 2"; }
        # a copy of the tree without the coordinator contract: the dispatcher refuses before devenv runs
        rm -rf "''${CRASH:?}/bin"; cp -r "$ROOT/hooks" "$CRASH/hooks"; cp -r "$ROOT/agents" "$CRASH/agents"
        # an adapter that wires a role guard but ships no contract directory is refused, not silently un-guarded
        rm -rf "''${CRASH:?}/agents/coordinator"
        err=$(printf '%s' "$ALLOWED" | env -u COORDINATOR_CHECKOUT SKILLS_CHECKOUT="$CRASH" "$CRASH/hooks/role-guard-dispatch.sh" 2>&1 >/dev/null); code=$?; [ "$code" -eq 2 ] && grep -q 'ships no agents/coordinator/ROLE.md' <<<"$err" && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL(dispatch): adapter without a contract must refuse ($code '$err')"; }
        # the dispatcher reached through a symlink (the ~/.claude/hooks shape) still finds its own tree
        LINKD=$(mktemp -d); CLEANUP+=("$LINKD"); ln -s "$ROOT/hooks/role-guard-dispatch.sh" "$LINKD/role-guard-dispatch.sh"
        err=$(printf '%s' "$ALLOWED" | env -u COORDINATOR_CHECKOUT -u SKILLS_CHECKOUT HOME=/nonexistent "$LINKD/role-guard-dispatch.sh" 2>&1 >/dev/null); code=$?; [ "$code" -eq 2 ] && grep -q 'missing or stale' <<<"$err" && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL(dispatch): symlinked dispatcher must resolve its own tree"; }
        rm -rf "$CRASH" "$LINKD"
        # without jq the routing still happens (grep fallback) and the guard fails closed on its own missing jq
        NOJQ=$(mktemp -d); CLEANUP+=("$NOJQ"); for b in bash grep sed head dirname readlink cat printf env mktemp rm tail tr; do p=$(type -P "$b") && ln -s "$p" "$NOJQ/$b"; done
        err=$(printf '%s' "$ALLOWED" | env -u COORDINATOR_CHECKOUT SKILLS_CHECKOUT="$ROOT" PATH="$NOJQ" "$DISPATCH" 2>&1 >/dev/null); code=$?; [ "$code" -eq 2 ] && grep -q 'jq is required' <<<"$err" && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL(dispatch): role agent without jq must fail closed naming jq ($code '$err')"; }
        out=$(printf '%s' "$(jq -cn '{cwd:"/tmp",tool_name:"Bash",tool_input:{command:"echo hi"}}')" | env -u COORDINATOR_CHECKOUT SKILLS_CHECKOUT="$ROOT" PATH="$NOJQ" "$DISPATCH" 2>&1); code=$?; [ "$code" -eq 0 ] && [ -z "$out" ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL(dispatch): main session without jq must stay a silent no-op"; }
        rm -rf "$NOJQ"
        dcase "capitalised agent_type is lowercased and routed" 0 allow "$(jq -cn --arg c "cd $ROOT && devenv tasks run coord:brief" '{cwd:"/tmp",agent_type:"Coordinator",tool_name:"Bash",tool_input:{command:$c}}')"
        dcase "namespaced agent_type routes by its tail" 0 allow "$(jq -cn --arg c "cd $ROOT && devenv tasks run coord:brief" '{cwd:"/tmp",agent_type:"sammasak-skills:coordinator",tool_name:"Bash",tool_input:{command:$c}}')"
        ( out=$(printf '%s' "$ALLOWED" | env -u COORDINATOR_CHECKOUT SKILLS_CHECKOUT="$ROOT/" "$DISPATCH" 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecision // empty'); [ "$out" = allow ] ) && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL(dispatch): checkout configured with a trailing slash must allow"; }
        ( out=$(jq -cn --arg c "cd ~/x && devenv tasks run coord:brief" '{cwd:"/tmp",tool_name:"Bash",tool_input:{command:$c}}' | HOME="/x/" COORDINATOR_CHECKOUT="$ROOT" "$HOOK" >/dev/null 2>&1; echo $?); [ "$out" = 2 ] ) && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL(hook): HOME with a trailing slash must block (//)"; }
        dcase "coordinator subagent, act task asks" 0 ask "$(jq -cn --arg c "cd $ROOT && devenv tasks run herdr:message --input-json '{}'" '{cwd:"/tmp",agent_type:"coordinator",tool_name:"Bash",tool_input:{command:$c}}')"
        dcase "quality subagent, allowed task" 0 allow "$(jq -cn --arg c "cd $ROOT && devenv tasks run quality:report --input-json '{}'" '{cwd:"/tmp",agent_type:"quality",tool_name:"Bash",tool_input:{command:$c}}')"
        dcase "other agent is a no-op" 0 "" "$(jq -cn '{cwd:"/tmp",agent_type:"code-reviewer",tool_name:"Bash",tool_input:{command:"echo hi"}}')"
        dcase "main session is a no-op" 0 "" "$(jq -cn '{cwd:"/tmp",tool_name:"Bash",tool_input:{command:"echo hi"}}')"
        dcase "pattern-like agent name is a no-op" 0 "" "$(jq -cn '{cwd:"/tmp",agent_type:"../coordinator",tool_name:"Bash",tool_input:{command:"echo hi"}}')"
        ( printf '%s' "$(jq -cn '{cwd:"/tmp",agent_type:"code-reviewer",tool_name:"Bash",tool_input:{command:"echo hi"}}')" | env -u COORDINATOR_CHECKOUT SKILLS_CHECKOUT="$ROOT" "$DISPATCH" 2>/dev/null | grep -q . ) && { FAIL=$((FAIL+1)); echo "FAIL(dispatch): no-op must print nothing"; } || PASS=$((PASS+1))
        ( jq -cn '{tool_name:"Bash",tool_input:{command:"devenv tasks run coord:brief"}}' | "$HOOK" >/dev/null 2>&1; [ $? -eq 2 ] ) && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL(hook): missing cwd must block"; }
        ( jq -cn --arg d "$ROOT" '{cwd:$d,tool_name:"Bash",tool_input:{command:"devenv tasks run coord:brief\u0000; ssh x"}}' | "$HOOK" >/dev/null 2>&1; [ $? -eq 2 ] ) && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL(hook): NUL byte must block"; }
        # a per-call working directory (Codex workdir) outside the checkout must block even when the session cwd is right
        ( jq -cn --arg d "$ROOT" '{cwd:$d,tool_name:"Bash",tool_input:{command:"devenv tasks run coord:brief",workdir:"/tmp"}}' | "$HOOK" >/dev/null 2>&1; [ $? -eq 2 ] ) && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL(hook): workdir outside the checkout must block"; }
        ( jq -cn --arg d "$ROOT" '{cwd:$d,tool_name:"Bash",tool_input:{command:"devenv tasks run coord:brief",working_directory:"/tmp"}}' | "$HOOK" >/dev/null 2>&1; [ $? -eq 2 ] ) && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL(hook): working_directory outside the checkout must block"; }
        ( jq -cn --arg d "$ROOT" '{cwd:$d,tool_name:"Bash",tool_input:{command:"devenv tasks run coord:brief",workdir:$d}}' | "$HOOK" 2>/dev/null | jq -e '.hookSpecificOutput.permissionDecision=="allow"' >/dev/null ) && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL(hook): workdir equal to the checkout must allow"; }
        # the actual threat: a subdirectory of the checkout (a planted devenv.nix there would evaluate instead), given absolute,
        # relative, or through a second field; a non-existent dir and tool_input.cwd must block too
        wdcase() { local label="$1" tin="$2"; ( jq -cn --arg d "$ROOT" --argjson t "$tin" '{cwd:$d,tool_name:"Bash",tool_input:({command:"devenv tasks run coord:brief"}+$t)}' | "$HOOK" >/dev/null 2>&1; [ $? -eq 2 ] ) && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL(hook): $label must block"; }; }
        wdcase "workdir = checkout subdirectory" "$(jq -cn --arg d "$ROOT/tests" '{workdir:$d}')"
        wdcase "relative workdir into a subdirectory" '{"workdir":"tests"}'
        wdcase "relative workdir ." '{"workdir":"./tests/../tests"}'
        wdcase "non-existent workdir" "$(jq -cn --arg d "$ROOT/does-not-exist" '{workdir:$d}')"
        wdcase "tool_input.cwd outside" '{"cwd":"/tmp"}'
        wdcase "working_dir outside" '{"working_dir":"/tmp"}'
        wdcase "one good field and one bad field" "$(jq -cn --arg d "$ROOT" '{workdir:$d, cwd:"/tmp"}')"
        wdcase "non-string workdir" '{"workdir":{"path":"/tmp"}}'
        # these must be refused by the control-character/type check itself (reason pinned), not by a later check
        cchook() { local label="$1" payload="$2" err code; err=$(printf '%s' "$payload" | "$HOOK" 2>&1 >/dev/null); code=$?; [ "$code" -eq 2 ] && grep -q 'control characters or unparseable input' <<<"$err" && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL(hook): $label -> $code '$err' (want the control-character refusal)"; }; }
        cchook "control character in working_dir" "$(jq -cn --arg d "$ROOT" '{cwd:$d,tool_name:"Bash",tool_input:{command:"devenv tasks run coord:brief",working_dir:($d+"\t")}}')"
        cchook "trailing newline in cwd" "$(jq -cn --arg d "$ROOT" '{cwd:($d+"\n"),tool_name:"Bash",tool_input:{command:"devenv tasks run coord:brief"}}')"
        cchook "string tool_input" "$(jq -cn --arg d "$ROOT" '{cwd:$d,tool_name:"Bash",tool_input:"devenv tasks run coord:brief"}')"
        cchook "array tool_input" "$(jq -cn --arg d "$ROOT" '{cwd:$d,tool_name:"Bash",tool_input:["devenv tasks run coord:brief"]}')"
        cchook "non-string command" "$(jq -cn --arg d "$ROOT" '{cwd:$d,tool_name:"Bash",tool_input:{command:["devenv","tasks","run","coord:brief"]}}')"
        cchook "newline-only workdir" "$(jq -cn --arg d "$ROOT" '{cwd:$d,tool_name:"Bash",tool_input:{command:"devenv tasks run coord:brief",workdir:"\n"}}')"
        cchook "workdir with an embedded newline" "$(jq -cn --arg d "$ROOT" '{cwd:$d,tool_name:"Bash",tool_input:{command:"devenv tasks run coord:brief",workdir:($d+"\n/tmp")}}')"
        cchook "newline inside the command" "$(jq -cn --arg d "$ROOT" '{cwd:$d,tool_name:"Bash",tool_input:{command:"devenv tasks run coord:brief\nssh lenovo id"}}')"
        cchook "carriage return in the command" "$(jq -cn --arg d "$ROOT" '{cwd:$d,tool_name:"Bash",tool_input:{command:"devenv tasks run coord:brief\r"}}')"
        # the adapter's hook command (main-session mode) finds the guard in the default checkout and refuses when none exists
        if command -v yq >/dev/null; then
          cmd=$(yq --front-matter=extract -r '.hooks.PreToolUse[0].hooks[0].command' "$ROOT/agents/coordinator.md")
          err=$( (env -u COORDINATOR_CHECKOUT -u SKILLS_CHECKOUT HOME="$TMP_HOME_MISSING" bash -c "$cmd" </dev/null 2>&1 >/dev/null); echo "rc=$?")
          ( grep -q 'no role guard at' <<<"$err" && grep -q 'rc=2' <<<"$err" ) && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL(adapter): hook command must exit 2 with 'no guard at' when no checkout exists ($err)"; }
          dec=$(jq -cn --arg d "$ROOT" '{cwd:$d,tool_name:"Bash",tool_input:{command:"devenv tasks run coord:brief"}}' | env -u COORDINATOR_CHECKOUT -u SKILLS_CHECKOUT HOME="$HOMETMP" bash -c "$cmd" 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecision // empty')
          [ "$dec" = allow ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL(adapter): guard in the default checkout must exec through (got '$dec')"; }
          dec=$(jq -cn --arg d "$ROOT" '{cwd:$d,tool_name:"Bash",tool_input:{command:"devenv tasks run coord:brief"}}' | env -u COORDINATOR_CHECKOUT SKILLS_CHECKOUT="$ROOT" HOME="$TMP_HOME_MISSING" bash -c "$cmd" 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecision // empty')
          [ "$dec" = allow ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL(adapter): SKILLS_CHECKOUT override must exec through (got '$dec')"; }
          rm -rf "$HOMETMP"
        else echo "note: yq missing, adapter hook command cases skipped"; fi

        # the same guard serves the quality role: run-class allowed, coordinator-only and act tasks blocked
        qhook() { # <want> <command>
          local out code dec
          out=$(jq -cn --arg c "$2" --arg d "$ROOT" '{session_id:"t",cwd:$d,tool_name:"Bash",tool_input:{command:$c}}' | ROLE=quality guard_hook 2>/dev/null); code=$?
          dec=$(jq -r '.hookSpecificOutput.permissionDecision // empty' <<<"$out" 2>/dev/null)
          if [ "$1" = block ]; then [ "$code" -eq 2 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL(qhook): '$2' -> exit $code dec=$dec (want block)"; }
          else [ "$code" -eq 0 ] && [ "$dec" = "$1" ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL(qhook): '$2' -> exit $code dec=$dec (want $1)"; }; fi
        }
        qhook allow "devenv tasks run quality:report --input-json '{\"checkout\":\"/home/x/repo\"}'"
        qhook allow "devenv tasks run quality:gate --input-json '{\"checkout\":\"/home/x/repo\",\"stage\":\"test\"}'"
        qhook allow "devenv tasks run gh:work --show-output"
        qhook block "devenv tasks run coord:brief"
        qhook block "devenv tasks run herdr:message --input-json '{}'"
        qhook block "devenv tasks run herdr:inspect --input-json '{}'"
        qhook block "cargo test"
        qhook block "devenv tasks run quality:gate --input-json '{\"stage\":\"test\"}' && git push"
        ( jq -cn --arg d "$ROOT" '{cwd:$d,tool_name:"Bash",tool_input:{command:"devenv tasks run gh:work"}}' | ROLE=nosuchrole guard_hook >/dev/null 2>&1; [ $? -eq 2 ] ) && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: unknown ROLE must block"; }

        # the Claude adapter must not carry editing tools
        if grep -qE '^\s*-\s*(Edit|Write|NotebookEdit)\s*$' <(awk '/^tools:/{f=1;next} /^[a-zA-Z]+:/{f=0} f' "$ROOT/agents/coordinator.md"); then
          FAIL=$((FAIL+1)); echo "FAIL: adapter lists an editing tool"
        else PASS=$((PASS+1)); fi

        # allow rules carry no wildcard at all: a wildcard after the task name admits -O overrides and extra task names
        if jq -r '.allow[] | select(startswith("Bash("))' "$P" | grep -q '\*'; then FAIL=$((FAIL+1)); echo "FAIL: a Bash allow rule contains a wildcard"; else PASS=$((PASS+1)); fi
        # the guard honours every role contract behaviourally: read/run tasks allow, act tasks ask, another role's tasks block
        if command -v yq >/dev/null; then
          for role_md in "$ROOT"/agents/*/ROLE.md; do
            role=$(basename "$(dirname "$role_md")"); fm=$(yq --front-matter=extract -o=json '.' "$role_md")
            rhook() { local out code dec; out=$(jq -cn --arg c "$2" --arg d "$ROOT" '{session_id:"t",cwd:$d,tool_name:"Bash",tool_input:{command:$c}}' | ROLE="$role" guard_hook 2>/dev/null); code=$?
              dec=$(jq -r '.hookSpecificOutput.permissionDecision // empty' <<<"$out" 2>/dev/null)
              if [ "$1" = block ]; then [ "$code" -eq 2 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL($role): '$2' -> $code/$dec (want block)"; }
              else [ "$code" -eq 0 ] && [ "$dec" = "$1" ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL($role): '$2' -> $code/$dec (want $1)"; }; fi; }
            for t in $(jq -r '.tasks.read[], (.tasks.run // [])[]' <<<"$fm"); do rhook allow "devenv tasks run $t --input-json '{}'"; done
            for t in $(jq -r '.tasks.act[]' <<<"$fm"); do rhook ask "devenv tasks run $t --input-json '{}'"; done
            for other in "$ROOT"/agents/*/ROLE.md; do [ "$other" = "$role_md" ] && continue
              for t in $(yq --front-matter=extract -o=json '.' "$other" | jq -r --argjson mine "$(jq -c '[.tasks.read[], (.tasks.run // [])[], .tasks.act[]]' <<<"$fm")" '[.tasks.read[], (.tasks.run // [])[], .tasks.act[]] | map(select(. as $t | ($mine | index($t)) == null))[]'); do rhook block "devenv tasks run $t"; done
            done
          done
        else echo "note: yq missing, role-list behaviour cases skipped"; fi
        # integrity: a checkout with an .integrity manifest refuses every call once a guarded file changes; managed sessions
        # need manifest AND pin; refusals are checked by their reason, not just by the absence of a decision
        ITMP=$(mktemp -d); CLEANUP+=("$ITMP"); git -C "$ROOT" archive --format=tar HEAD | tar -x -C "$ITMP"; cp -r "$ROOT/hooks/." "$ITMP/hooks/"; cp "$ROOT/task-modules/guard.nix" "$ITMP/task-modules/guard.nix"   # the guard under test is the working tree's
        mkdir -p "$ITMP/.claude" && echo '{}' > "$ITMP/.claude/settings.json"
        # shellcheck disable=SC2046  # the roots file is a space-free word list
        manifest() { ( cd "$ITMP" && find -L $(cat hooks/lib/integrity-paths) -type f -print0 2>/dev/null | sort -z | xargs -0 sha256sum > .integrity ); }
        manifest; pin=$(sha256sum "$ITMP/.integrity" | cut -d' ' -f1)
        # ghook <want: allow|<stderr substring>> [env...]: run the coordinator guard in the copy
        ghook() { local want="$1"; shift; local out err code dec
          out=$(jq -cn --arg d "$ITMP" '{cwd:$d,tool_name:"Bash",tool_input:{command:"devenv tasks run coord:brief"}}' | ( export "$@" COORDINATOR_CHECKOUT="$ITMP" ROLE=coordinator; guard_hook ) 2>"$TMP_HOME_MISSING/g.err"); code=$?; err=$(cat "$TMP_HOME_MISSING/g.err")
          dec=$(jq -r '.hookSpecificOutput.permissionDecision // empty' <<<"$out" 2>/dev/null)
          if [ "$want" = allow ]; then [ "$code" -eq 0 ] && [ "$dec" = allow ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL(integrity): expected allow, got $code/$dec $err"; }
          else [ "$code" -eq 2 ] && [[ "$err" == *"$want"* ]] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL(integrity): expected block '$want', got $code/$dec '$err'"; }; fi; }
        ghook allow
        ghook allow COORDINATOR_REQUIRE_INTEGRITY=1 COORDINATOR_INTEGRITY_SHA256="$pin"
        echo '# tampered' >> "$ITMP/agents/coordinator/tasks.nix"; ghook "integrity check failed"
        git -C "$ROOT" show HEAD:agents/coordinator/tasks.nix > "$ITMP/agents/coordinator/tasks.nix"; ghook allow
        # the shared predicate itself: arity, pin validation, ./-prefixed manifest lines, a role whose contract is unlisted
        pc() { local want="$1" label="$2"; shift 2; local out code; out=$(integrity_check "$@" 2>&1); code=$?; [ "$code" -eq "$want" ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL(predicate): $label -> $code ($out), want $want"; }; }
        pc 2 "single argument" "$ITMP"
        pc 2 "empty dir" "" "$pin"
        pc 2 "empty pin (never means no pin)" "$ITMP" ""
        pc 2 "short pin" "$ITMP" abc
        pc 0 "no-pin sentinel" "$ITMP" -
        pc 0 "valid pin and role" "$ITMP" "$pin" coordinator
        pc 1 "role whose contract is not listed" "$ITMP" "$pin" nosuchrole
        cp "$ITMP/.integrity" "$ITMP/.integrity.orig"; sed -i 's#^\([0-9a-f]\{64\}\)  #\1  ./#' "$ITMP/.integrity"
        pc 0 "./-prefixed manifest lines" "$ITMP" - coordinator
        mv "$ITMP/.integrity.orig" "$ITMP/.integrity"; pc 0 "manifest restored" "$ITMP" "$pin"
        pc 2 "role name that is a pattern" "$ITMP" - 'a+'
        # near misses must not count as listed: a dot is literal, and a prefix or suffix of a listed path is another path
        cp "$ITMP/.integrity" "$ITMP/.integrity.orig"
        cp "$ITMP/devenv.nix" "$ITMP/devenvXnix"; sed -i 's#  devenv\.nix$#  devenvXnix#' "$ITMP/.integrity"; pc 1 "dot is literal (devenvXnix does not cover devenv.nix)" "$ITMP" -
        mv "$ITMP/.integrity.orig" "$ITMP/.integrity"; cp "$ITMP/.integrity" "$ITMP/.integrity.orig"
        cp "$ITMP/task-modules/guard.nix" "$ITMP/task-modules/guard.nix.bak"; sed -i 's#  task-modules/guard\.nix$#  task-modules/guard.nix.bak#' "$ITMP/.integrity"; pc 1 "suffix near miss (guard.nix.bak does not cover guard.nix)" "$ITMP" -
        mv "$ITMP/.integrity.orig" "$ITMP/.integrity"; rm -f "$ITMP/devenvXnix" "$ITMP/task-modules/guard.nix.bak"; pc 0 "manifest restored again" "$ITMP" "$pin"
        ghook "without a valid integrity pin" COORDINATOR_REQUIRE_INTEGRITY=1
        mv "$ITMP/.integrity" "$ITMP/.integrity.bak"; ghook "no .integrity manifest" COORDINATOR_REQUIRE_INTEGRITY=1 COORDINATOR_INTEGRITY_SHA256="$pin"; ghook "no .integrity manifest" COORDINATOR_INTEGRITY_SHA256="$pin"; mv "$ITMP/.integrity.bak" "$ITMP/.integrity"
        echo '# tampered' >> "$ITMP/agents/coordinator/tasks.nix"; manifest; ghook "does not match the pinned hash" COORDINATOR_REQUIRE_INTEGRITY=1 COORDINATOR_INTEGRITY_SHA256="$pin"
        git -C "$ROOT" show HEAD:agents/coordinator/tasks.nix > "$ITMP/agents/coordinator/tasks.nix"; manifest
        echo '{ ... }: { coordinator.devenvCommand = "/tmp/evil"; }' > "$ITMP/devenv.local.nix"; ghook "devenv.local.nix is present but not covered" COORDINATOR_REQUIRE_INTEGRITY=1 COORDINATOR_INTEGRITY_SHA256="$pin"
        # shellcheck disable=SC2046
        ( cd "$ITMP" && find -L $(cat hooks/lib/integrity-paths) devenv.local.nix -type f -print0 2>/dev/null | sort -z | xargs -0 sha256sum > .integrity ); pin=$(sha256sum "$ITMP/.integrity" | cut -d' ' -f1); ghook allow COORDINATOR_REQUIRE_INTEGRITY=1 COORDINATOR_INTEGRITY_SHA256="$pin"
        echo '{"disableAllHooks":true}' > "$ITMP/.claude/settings.local.json"; ghook "settings.local.json is present but not covered" COORDINATOR_REQUIRE_INTEGRITY=1 COORDINATOR_INTEGRITY_SHA256="$pin"; rm -f "$ITMP/.claude/settings.local.json"
        echo '{"permissions":{"allow":["Bash"]}}' > "$ITMP/.claude/settings.json"; ghook "integrity check failed" COORDINATOR_REQUIRE_INTEGRITY=1 COORDINATOR_INTEGRITY_SHA256="$pin"
        sed -i '/task-modules\/guard.nix/d' "$ITMP/.integrity"; pin2=$(sha256sum "$ITMP/.integrity" | cut -d' ' -f1); echo '{}' > "$ITMP/.claude/settings.json"
        if ( cd "$ITMP" && sha256sum --check --quiet .integrity >/dev/null 2>&1 ); then ghook "does not cover task-modules/guard.nix" COORDINATOR_REQUIRE_INTEGRITY=1 COORDINATOR_INTEGRITY_SHA256="$pin2"; else FAIL=$((FAIL+1)); echo "FAIL(integrity): precondition for the coverage case did not hold"; fi
        rm -f "$ITMP/devenv.local.nix"; manifest; pin=$(sha256sum "$ITMP/.integrity" | cut -d' ' -f1)
        echo 'x' > "$ITMP/devenv.local.yaml"; ghook "devenv.local.yaml is present but not covered" COORDINATOR_REQUIRE_INTEGRITY=1 COORDINATOR_INTEGRITY_SHA256="$pin"; rm -f "$ITMP/devenv.local.yaml"
        echo '# planted' > "$ITMP/CLAUDE.md"; ghook "CLAUDE.md is present but not covered" COORDINATOR_REQUIRE_INTEGRITY=1 COORDINATOR_INTEGRITY_SHA256="$pin"; rm -f "$ITMP/CLAUDE.md"
        mkdir -p "$ITMP/.codex" && echo '{}' > "$ITMP/.codex/hooks.json"; ghook ".codex/hooks.json is present but not covered" COORDINATOR_REQUIRE_INTEGRITY=1 COORDINATOR_INTEGRITY_SHA256="$pin"; rm -rf "$ITMP/.codex"
        ghook "without a valid integrity pin" COORDINATOR_REQUIRE_INTEGRITY=true COORDINATOR_INTEGRITY_SHA256=abc
        ghook "without a valid integrity pin" COORDINATOR_REQUIRE_INTEGRITY=yes
        ( jq -cn --arg d "$ITMP" '{cwd:$d,tool_name:"Bash",tool_input:{command:"devenv tasks run quality:report --input-json '"'"'{}'"'"'"}}' | COORDINATOR_CHECKOUT="$ITMP" COORDINATOR_REQUIRE_INTEGRITY=1 COORDINATOR_INTEGRITY_SHA256="$pin" ROLE=quality guard_hook 2>/dev/null | jq -e '.hookSpecificOutput.permissionDecision == "allow"' >/dev/null ) && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL(integrity): managed quality session must allow its own task"; }
        rm -rf "$ITMP"

        echo "passed=$PASS failed=$FAIL"; [ "$FAIL" -eq 0 ]
      '';
    };
  };
}
