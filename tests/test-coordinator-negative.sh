#!/usr/bin/env bash
# shellcheck disable=SC2088  # literal ~ paths are what an agent would type into Read
# Negative controls for the Coordinator surface (epic #16 M0): the portable
# permission rules must not be able to express code changes, pushes, merges,
# host switches, arbitrary SSH or the act-class herdr:message without a prompt.
# Run: bash tests/test-coordinator-negative.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/claude-permission-match.sh
. "$ROOT/tests/lib/claude-permission-match.sh"
P="$ROOT/agents/coordinator/permissions.json"
TMP_HOME_MISSING=$(mktemp -d); trap 'rm -rf "$TMP_HOME_MISSING"' EXIT
PASS=0; FAIL=0

expect() { # <want> <tool> <command>
  local got; got="$(permission_decision "$P" "$2" "${3:-}")"
  if [ "$got" = "$1" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $2 '${3:-}' -> $got (want $1)"; fi
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
HOOK="$ROOT/hooks/validate-coordinator.sh"
export COORDINATOR_CHECKOUT="$ROOT"
hook() { # <want: allow|ask|block> <command> [cwd]
  local out code dec
  out=$(jq -cn --arg c "$2" --arg d "${3:-$ROOT}" '{session_id:"t",cwd:$d,tool_name:"Bash",tool_input:{command:$c}}' | "$HOOK" 2>/dev/null); code=$?
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
( unset COORDINATOR_CHECKOUT; jq -cn --arg d "$ROOT" '{cwd:$d,tool_name:"Bash",tool_input:{command:"devenv tasks run coord:brief"}}' | "$HOOK" >/dev/null 2>&1; [ $? -eq 2 ] ) && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL(hook): unset COORDINATOR_CHECKOUT must block"; }
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
wdcase "newline-only workdir" '{"workdir":"\n"}'
wdcase "workdir with an embedded newline" "$(jq -cn --arg d "$ROOT" '{workdir:($d+"\n/tmp")}')"
# these must be refused by the control-character/type check itself (reason pinned), not by a later check
cchook() { local label="$1" payload="$2" err code; err=$(printf '%s' "$payload" | "$HOOK" 2>&1 >/dev/null); code=$?; [ "$code" -eq 2 ] && grep -q 'control characters or unparseable input' <<<"$err" && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL(hook): $label -> $code '$err' (want the control-character refusal)"; }; }
cchook "control character in working_dir" "$(jq -cn --arg d "$ROOT" '{cwd:$d,tool_name:"Bash",tool_input:{command:"devenv tasks run coord:brief",working_dir:($d+"\t")}}')"
cchook "trailing newline in cwd" "$(jq -cn --arg d "$ROOT" '{cwd:($d+"\n"),tool_name:"Bash",tool_input:{command:"devenv tasks run coord:brief"}}')"
cchook "string tool_input" "$(jq -cn --arg d "$ROOT" '{cwd:$d,tool_name:"Bash",tool_input:"devenv tasks run coord:brief"}')"
cchook "array tool_input" "$(jq -cn --arg d "$ROOT" '{cwd:$d,tool_name:"Bash",tool_input:["devenv tasks run coord:brief"]}')"
cchook "non-string command" "$(jq -cn --arg d "$ROOT" '{cwd:$d,tool_name:"Bash",tool_input:{command:["devenv","tasks","run","coord:brief"]}}')"
cchook "newline-only workdir" "$(jq -cn --arg d "$ROOT" '{cwd:$d,tool_name:"Bash",tool_input:{command:"devenv tasks run coord:brief",workdir:"\n"}}')"
# the adapter's hook command refuses when the guard file is absent (fail closed)
if command -v yq >/dev/null; then
  cmd=$(yq --front-matter=extract -r '.hooks.PreToolUse[0].hooks[0].command' "$ROOT/agents/coordinator.md")
  ( HOME="$TMP_HOME_MISSING" bash -c "$cmd" </dev/null >/dev/null 2>&1; [ $? -eq 2 ] ) && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL(adapter): hook command must exit 2 when guard is missing ($cmd)"; }
  mkdir -p "$TMP_HOME_MISSING/.claude/hooks" && ln -sf "$HOOK" "$TMP_HOME_MISSING/.claude/hooks/validate-coordinator.sh"
  dec=$(jq -cn --arg d "$ROOT" '{cwd:$d,tool_name:"Bash",tool_input:{command:"devenv tasks run coord:brief"}}' | HOME="$TMP_HOME_MISSING" bash -c "$cmd" 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecision // empty')
  [ "$dec" = allow ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL(adapter): installed guard must exec through (got '$dec')"; }
else echo "note: yq missing, adapter hook command cases skipped"; fi

# the same guard serves the quality role: run-class allowed, coordinator-only and act tasks blocked
qhook() { # <want> <command>
  local out code dec
  out=$(jq -cn --arg c "$2" --arg d "$ROOT" '{session_id:"t",cwd:$d,tool_name:"Bash",tool_input:{command:$c}}' | "$ROOT/hooks/validate-quality.sh" 2>/dev/null); code=$?
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
( jq -cn --arg d "$ROOT" '{cwd:$d,tool_name:"Bash",tool_input:{command:"devenv tasks run gh:work"}}' | ROLE=nosuchrole "$ROOT/hooks/validate-role.sh" >/dev/null 2>&1; [ $? -eq 2 ] ) && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: unknown ROLE must block"; }

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
    rhook() { local out code dec; out=$(jq -cn --arg c "$2" --arg d "$ROOT" '{session_id:"t",cwd:$d,tool_name:"Bash",tool_input:{command:$c}}' | ROLE="$role" "$ROOT/hooks/validate-role.sh" 2>/dev/null); code=$?
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
ITMP=$(mktemp -d); git -C "$ROOT" archive --format=tar HEAD | tar -x -C "$ITMP"; cp -r "$ROOT/hooks/." "$ITMP/hooks/"   # the guard under test is the working tree's
mkdir -p "$ITMP/.claude" && echo '{}' > "$ITMP/.claude/settings.json"
# shellcheck disable=SC2046  # the roots file is a space-free word list
manifest() { ( cd "$ITMP" && find -L $(cat hooks/lib/integrity-paths) -type f -print0 2>/dev/null | sort -z | xargs -0 sha256sum > .integrity ); }
manifest; pin=$(sha256sum "$ITMP/.integrity" | cut -d' ' -f1)
# ghook <want: allow|<stderr substring>> [env...]: run the coordinator guard in the copy
ghook() { local want="$1"; shift; local out err code dec
  out=$(jq -cn --arg d "$ITMP" '{cwd:$d,tool_name:"Bash",tool_input:{command:"devenv tasks run coord:brief"}}' | env "$@" COORDINATOR_CHECKOUT="$ITMP" ROLE=coordinator "$ITMP/hooks/validate-role.sh" 2>"$TMP_HOME_MISSING/g.err"); code=$?; err=$(cat "$TMP_HOME_MISSING/g.err")
  dec=$(jq -r '.hookSpecificOutput.permissionDecision // empty' <<<"$out" 2>/dev/null)
  if [ "$want" = allow ]; then [ "$code" -eq 0 ] && [ "$dec" = allow ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL(integrity): expected allow, got $code/$dec $err"; }
  else [ "$code" -eq 2 ] && [[ "$err" == *"$want"* ]] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL(integrity): expected block '$want', got $code/$dec '$err'"; }; fi; }
ghook allow
ghook allow COORDINATOR_REQUIRE_INTEGRITY=1 COORDINATOR_INTEGRITY_SHA256="$pin"
echo '# tampered' >> "$ITMP/agents/coordinator/tasks.nix"; ghook "integrity check failed"
git -C "$ROOT" show HEAD:agents/coordinator/tasks.nix > "$ITMP/agents/coordinator/tasks.nix"; ghook allow
# the shared predicate itself: arity, pin validation, ./-prefixed manifest lines, a role whose contract is unlisted
IC="$ITMP/hooks/lib/integrity-check.sh"
pc() { local want="$1" label="$2"; shift 2; local out code; out=$("$IC" "$@" 2>&1); code=$?; [ "$code" -eq "$want" ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL(predicate): $label -> $code ($out), want $want"; }; }
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
ghook "without a valid integrity pin" COORDINATOR_REQUIRE_INTEGRITY=1
mv "$ITMP/.integrity" "$ITMP/.integrity.bak"; ghook "no .integrity manifest" COORDINATOR_REQUIRE_INTEGRITY=1 COORDINATOR_INTEGRITY_SHA256="$pin"; ghook "no .integrity manifest" COORDINATOR_INTEGRITY_SHA256="$pin"; mv "$ITMP/.integrity.bak" "$ITMP/.integrity"
echo '# tampered' >> "$ITMP/agents/coordinator/tasks.nix"; manifest; ghook "does not match the pinned hash" COORDINATOR_REQUIRE_INTEGRITY=1 COORDINATOR_INTEGRITY_SHA256="$pin"
git -C "$ROOT" show HEAD:agents/coordinator/tasks.nix > "$ITMP/agents/coordinator/tasks.nix"; manifest
echo '{ ... }: { coordinator.devenvCommand = "/tmp/evil"; }' > "$ITMP/devenv.local.nix"; ghook "devenv.local.nix is present but not covered" COORDINATOR_REQUIRE_INTEGRITY=1 COORDINATOR_INTEGRITY_SHA256="$pin"
# shellcheck disable=SC2046
( cd "$ITMP" && find -L $(cat hooks/lib/integrity-paths) devenv.local.nix -type f -print0 2>/dev/null | sort -z | xargs -0 sha256sum > .integrity ); pin=$(sha256sum "$ITMP/.integrity" | cut -d' ' -f1); ghook allow COORDINATOR_REQUIRE_INTEGRITY=1 COORDINATOR_INTEGRITY_SHA256="$pin"
echo '{"disableAllHooks":true}' > "$ITMP/.claude/settings.local.json"; ghook "settings.local.json is present but not covered" COORDINATOR_REQUIRE_INTEGRITY=1 COORDINATOR_INTEGRITY_SHA256="$pin"; rm -f "$ITMP/.claude/settings.local.json"
echo '{"permissions":{"allow":["Bash"]}}' > "$ITMP/.claude/settings.json"; ghook "integrity check failed" COORDINATOR_REQUIRE_INTEGRITY=1 COORDINATOR_INTEGRITY_SHA256="$pin"
sed -i '/hooks\/lib\/role-list.awk/d' "$ITMP/.integrity"; pin2=$(sha256sum "$ITMP/.integrity" | cut -d' ' -f1); echo '{}' > "$ITMP/.claude/settings.json"
if ( cd "$ITMP" && sha256sum --check --quiet .integrity >/dev/null 2>&1 ); then ghook "does not cover hooks/lib/role-list.awk" COORDINATOR_REQUIRE_INTEGRITY=1 COORDINATOR_INTEGRITY_SHA256="$pin2"; else FAIL=$((FAIL+1)); echo "FAIL(integrity): precondition for the coverage case did not hold"; fi
rm -f "$ITMP/devenv.local.nix"; manifest; pin=$(sha256sum "$ITMP/.integrity" | cut -d' ' -f1)
echo 'x' > "$ITMP/devenv.local.yaml"; ghook "devenv.local.yaml is present but not covered" COORDINATOR_REQUIRE_INTEGRITY=1 COORDINATOR_INTEGRITY_SHA256="$pin"; rm -f "$ITMP/devenv.local.yaml"
echo '# planted' > "$ITMP/CLAUDE.md"; ghook "CLAUDE.md is present but not covered" COORDINATOR_REQUIRE_INTEGRITY=1 COORDINATOR_INTEGRITY_SHA256="$pin"; rm -f "$ITMP/CLAUDE.md"
mkdir -p "$ITMP/.codex" && echo '{}' > "$ITMP/.codex/hooks.json"; ghook ".codex/hooks.json is present but not covered" COORDINATOR_REQUIRE_INTEGRITY=1 COORDINATOR_INTEGRITY_SHA256="$pin"; rm -rf "$ITMP/.codex"
ghook "without a valid integrity pin" COORDINATOR_REQUIRE_INTEGRITY=true COORDINATOR_INTEGRITY_SHA256=abc
ghook "without a valid integrity pin" COORDINATOR_REQUIRE_INTEGRITY=yes
( jq -cn --arg d "$ITMP" '{cwd:$d,tool_name:"Bash",tool_input:{command:"devenv tasks run quality:report --input-json '"'"'{}'"'"'"}}' | COORDINATOR_CHECKOUT="$ITMP" COORDINATOR_REQUIRE_INTEGRITY=1 COORDINATOR_INTEGRITY_SHA256="$pin" ROLE=quality "$ITMP/hooks/validate-role.sh" 2>/dev/null | jq -e '.hookSpecificOutput.permissionDecision == "allow"' >/dev/null ) && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL(integrity): managed quality session must allow its own task"; }
rm -rf "$ITMP"

echo "passed=$PASS failed=$FAIL"; [ "$FAIL" -eq 0 ]
