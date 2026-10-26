#!/usr/bin/env bash
# Contract test: every role's ROLE.md frontmatter, its adapters and its
# permissions.json agree, and every named skill/task exists.
# Run inside the devenv (needs yq-go, jq): bash tests/test-role-contract.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
FAIL=0; PASS=0
ok() { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }

TASKS="$(devenv tasks list 2>/dev/null | grep -oE '[a-z]+:[a-z-]+(:[a-z-]+)*' | sort -u)"
[ -n "$TASKS" ] || { echo "FAIL: devenv tasks list returned nothing"; exit 1; }

for role_md in agents/*/ROLE.md; do
  dir="$(dirname "$role_md")"; role="$(basename "$dir")"
  fm="$(yq --front-matter=extract -o=json '.' "$role_md")" || { bad "$role: frontmatter not parseable"; continue; }
  [ "$(jq -r .name <<<"$fm")" = "$role" ] && ok || bad "$role: name != directory"
  [ "$(jq -r .version <<<"$fm")" = "1" ] && ok || bad "$role: version must be 1"

  for s in $(jq -r '.skills[]' <<<"$fm"); do
    [ -f "skills/$s/SKILL.md" ] && ok || bad "$role: skill $s missing"
  done
  for t in $(jq -r '.tasks.read[], .tasks.act[]' <<<"$fm"); do
    grep -qx "$t" <<<"$TASKS" && ok || bad "$role: task $t not in devenv tasks list"
  done
  [ "$(jq '.forbidden|length' <<<"$fm")" -ge 5 ] && ok || bad "$role: forbidden list too short"

  perms="$dir/permissions.json"
  [ -f "$perms" ] || { bad "$role: permissions.json missing"; continue; }
  # input-less read tasks (declared in ROLE.md tasks.inputless) get exact settings rules; the rest are guard-only
  jq -e '.tasks.inputless | type == "array" and length > 0' <<<"$fm" >/dev/null && ok || bad "$role: tasks.inputless must be a non-empty list"
  jq -e '(.tasks.read | type == "array" and length > 0) and (.tasks.act | type == "array") and (.skills | type == "array" and length > 0)' <<<"$fm" >/dev/null && ok || bad "$role: tasks.read, tasks.act and skills must be lists"
  for t in $(jq -r '.tasks.inputless[]?' <<<"$fm"); do
    jq -e --arg t "$t" '.tasks.read | index($t)' <<<"$fm" >/dev/null && ok || bad "$role: inputless task $t is not a read task"
    jq -e --arg r "Bash(devenv tasks run ${t})" '.allow|index($r)' "$perms" >/dev/null && ok || bad "$role: exact rule for $t missing"
  done
  for t in $(jq -r '.tasks.act[]' <<<"$fm"); do
    jq -e --arg t "$t" '[.allow[] | select(contains($t))] | length == 0' "$perms" >/dev/null && ok || bad "$role: act task $t is allowlisted"
    jq -e --arg t "$t" '[.ask[] | select(contains($t))] | length > 0' "$perms" >/dev/null && ok || bad "$role: act task $t not in ask"
  done
  # every Bash allow rule names a read task; nothing else is allowed besides Read
  extra=$(jq -r --argjson r "$(jq -c '.tasks.inputless' <<<"$fm")" '.allow[] | select(startswith("Bash(")) | ((capture("^Bash\\(devenv tasks run (?<t>[a-z]+:[a-z-]+)( --show-output)?\\)$").t) // "<malformed>") | select(. as $t | ($r | index($t)) == null)' "$perms") || { bad "$role: allow-rule filter failed"; extra=""; }
  [ -z "$extra" ] && ok || bad "$role: Bash allow rules outside the inputless read tasks: $extra"
  jq -e --arg r "$role" '[.allow[] | select(startswith("Bash(") | not)] == ["Read(./**)", "Read(~/.local/state/\($r)/**)"]' "$perms" >/dev/null && ok || bad "$role: Read must be scoped to the checkout and the role's state dir"
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
echo "passed=$PASS failed=$FAIL"; [ "$FAIL" -eq 0 ]
