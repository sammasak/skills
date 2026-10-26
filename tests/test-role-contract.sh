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
  for t in $(jq -r '.tasks.read[]' <<<"$fm"); do
    jq -e --arg r "Bash(devenv tasks run ${t}*)" '.allow|index($r)' "$perms" >/dev/null && ok || bad "$role: read task $t not allowlisted"
  done
  for t in $(jq -r '.tasks.act[]' <<<"$fm"); do
    jq -e --arg r "Bash(devenv tasks run ${t}*)" '.allow|index($r)' "$perms" >/dev/null && bad "$role: act task $t is allowlisted" || ok
    jq -e --arg r "Bash(devenv tasks run ${t}*)" '.ask|index($r)' "$perms" >/dev/null && ok || bad "$role: act task $t not in ask"
  done

  for adapter in $(jq -r '.adapters[]' <<<"$fm"); do
    case "$adapter" in
      claude)
        f="agents/$role.md"; [ -f "$f" ] || { bad "$role: claude adapter $f missing"; continue; }
        afm="$(yq --front-matter=extract -o=json '.' "$f")"
        [ "$(jq -r .name <<<"$afm")" = "$role" ] && ok || bad "$role: claude adapter name mismatch"
        grep -q "ROLE.md" "$f" && ok || bad "$role: claude adapter does not point at ROLE.md"
        for s in $(jq -r '.skills[]' <<<"$fm"); do jq -e --arg s "$s" '.skills|index($s)' <<<"$afm" >/dev/null && ok || bad "$role: claude adapter does not preload $s"; done
        jq -e '[.tools[]] - ["Bash","Read"] | length == 0' <<<"$afm" >/dev/null && ok || bad "$role: claude adapter tools must be within Bash, Read"
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
