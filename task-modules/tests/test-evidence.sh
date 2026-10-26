#!/usr/bin/env bash
# Drives gh:work:<repo> / git:recent:<repo> and their aggregates with a fake gh and a throwaway git repo.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$ROOT" || exit 1
FX="$ROOT/task-modules/fixtures"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export FAKE_LOG="$TMP/calls.log" FAKE_GH_DIR="$FX/gh"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
run() { # <task> <fleet> [devenv args...]
  local task="$1" fleet="$2"; shift 2
  devenv tasks run "$task" --option coordinator.fleetFile:path "$fleet" --option coordinator.ghCommand:string "$FX/bin/gh" \
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

FAKE_GH_EXIT=1 run gh:work "$TMP/fleet.json"
[ "$CODE" -ne 0 ] && ok || bad "gh down: all repos failed must fail"
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
# unsafe checkout path is refused at evaluation
printf '{"schema_version":1,"hosts":[],"repos":[{"name":"x","gh":null,"checkout":"/tmp/a; id"}]}' > "$TMP/bad.json"
run git:recent "$TMP/bad.json"; [ "$CODE" -ne 0 ] && grep -q 'unsafe characters' "$TMP/run.log" && ok || bad "unsafe checkout must fail evaluation"

echo "passed=$PASS failed=$FAIL"; [ "$FAIL" -eq 0 ]
