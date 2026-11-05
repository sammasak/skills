#!/usr/bin/env bash
# Build one agent skill bundle (skills#63): exactly the named skills and one role contract from a
# pinned skills tree, in the layout one harness reads, with bundle.json (agent-skill-bundle,
# schemaVersion 1). Skills are visibility only; what the agent may do is the role's `forbidden`
# list, its `act` tasks and the adapter's tool policy, recorded apart under `authorization`.
# Every failure ends stderr with one JSON line; the class fixes the exit code. Nothing is written
# unless the whole bundle is.
#
#   build.sh --src DIR --rev SHA --role NAME --harness claude-code|codex|pi --skill NAME... [--tasks DIR] [--runtime PATH] --out DIR
# --runtime PATH (default.nix passes its store bin dirs): the PATH the entrypoints run with, so a sandbox needs no tools of its own.
# --tasks DIR (bundles/default.nix builds it from task-modules/): one executable per task and index.json
# ({name: {after}}); the role's declared read and run tasks, with what they run after, ship as tasks/<name>.
set -euo pipefail
fail() { # <class> <message>
  local code
  case $1 in usage) code=2 ;; role) code=3 ;; skill) code=4 ;; harness) code=5 ;; task) code=6 ;; *) code=1 ;; esac
  jq -nc --arg c "$1" --arg m "$2" '{error: {class: $c, message: $m}}' >&2
  exit "$code"
}
USAGE='build.sh --src DIR --rev SHA --role NAME --harness claude-code|codex|pi --skill NAME... [--tasks DIR] [--runtime PATH] --out DIR'
src='' rev='' role='' harness='' out='' tasks_src='' runtime='' skills=()
while [ $# -gt 0 ]; do
  case $1 in
    --src | --rev | --role | --harness | --out | --skill | --tasks | --runtime) [ $# -ge 2 ] || fail usage "usage: $USAGE" ;;&
    --src) src=$2; shift 2 ;;
    --rev) rev=$2; shift 2 ;;
    --role) role=$2; shift 2 ;;
    --harness) harness=$2; shift 2 ;;
    --out) out=$2; shift 2 ;;
    --skill) skills+=("$2"); shift 2 ;;
    --tasks) tasks_src=$2; shift 2 ;;
    --runtime) runtime=$2; shift 2 ;;
    *) fail usage "usage: $USAGE" ;;
  esac
done
[ -n "$src" ] && [ -n "$rev" ] && [ -n "$role" ] && [ -n "$harness" ] && [ -n "$out" ] || fail usage "usage: $USAGE"
[[ $rev =~ ^[0-9a-f]{40}$ ]] || fail usage "rev must be the 40-hex revision of the skills source, got '$rev'"
[ -d "$src/skills" ] && [ -d "$src/agents" ] || fail usage "$src is not a skills tree (no skills/ and agents/)"
[ -z "$runtime" ] || [[ $runtime =~ ^/nix/store/[A-Za-z0-9+._/-]+(:/nix/store/[A-Za-z0-9+._/-]+)*$ ]] || fail usage "--runtime must be store bin directories joined by ':'"
[ -e "$out" ] && fail usage "$out exists; a bundle is built into a fresh directory"
case $harness in claude-code | codex | pi) ;; *) fail usage "harness must be claude-code, codex or pi, got '$harness'" ;; esac

# the role: a real contract under agents/<role>/ROLE.md, and an adapter for the harness
[[ $role =~ ^[a-z][a-z0-9-]*$ ]] && [ -f "$src/agents/$role/ROLE.md" ] \
  || fail role "no role contract agents/$role/ROLE.md (known: $(find "$src/agents" -mindepth 2 -maxdepth 2 -name ROLE.md -printf '%h\n' | sed 's#.*/##' | LC_ALL=C sort | tr '\n' ' '))"
front=$(yq --front-matter=extract -o=json '.' "$src/agents/$role/ROLE.md") || fail role "agents/$role/ROLE.md has no YAML front matter"
case $harness in
  claude-code) adapter_src="agents/$role.md" adapter="claude/agents/$role.md" ;;
  codex) adapter_src="agents/$role/codex.toml" adapter="codex/$role.toml" ;;
  pi) adapter_src="" adapter="" ;;
esac
[ -n "$adapter_src" ] && [ -f "$src/$adapter_src" ] \
  || fail harness "unsupported harness combination: role $role has no $harness adapter${adapter_src:+ ($adapter_src)}"

# the skills: explicitly named, each a directory of skills/ holding a SKILL.md, no duplicates
[ ${#skills[@]} -gt 0 ] || fail skill "name at least one skill (--skill NAME); a bundle holds only what is named"
known=$(find "$src/skills" -mindepth 1 -maxdepth 1 -type d -exec test -f '{}/SKILL.md' ';' -printf '%f\n' | LC_ALL=C sort)
closest() { # the known name sharing the longest prefix with $1
  local best='' len=0 k i
  while IFS= read -r k; do
    i=0; while [ "$i" -lt "${#1}" ] && [ "$i" -lt "${#k}" ] && [ "${1:i:1}" = "${k:i:1}" ]; do i=$((i + 1)); done
    [ "$i" -le "$len" ] || { best=$k; len=$i; }
  done <<<"$known"
  [ "$len" -ge 3 ] && printf '%s' "$best"
}
seen=' '
for s in "${skills[@]}"; do
  [[ $s =~ ^[a-z0-9][a-z0-9-]*$ ]] || fail skill "skill name '$s' must be a skills/ directory name (lowercase letters, digits, -)"
  [[ $seen != *" $s "* ]] || fail skill "skill $s is named twice"
  seen="$seen$s "
  grep -qxF "$s" <<<"$known" || { c=$(closest "$s" || true); fail skill "no skill $s in skills/${c:+; did you mean $c?}"; }
done
selected=$(printf '%s\n' "${skills[@]}" | LC_ALL=C sort)

# tree_sha DIR: sha256 over every file's relative path and content, symlinks by their target
tree_sha() {
  (cd "$1" && find . -mindepth 1 \( -type f -o -type l -o \( -type d -empty \) \) -print0 | LC_ALL=C sort -z | while IFS= read -r -d '' f; do
    printf '%s\0' "$f"
    if [ -L "$f" ]; then printf 'link:%s\0' "$(readlink "$f")"
    elif [ -d "$f" ]; then printf 'dir\0'
    else printf 'mode:%s\0' "$( [ -x "$f" ] && echo x || echo -)"; sha256sum <"$f" | cut -c1-64; fi
  done) | sha256sum | cut -c1-64
}

mkdir -p "$(dirname "$out")"
stage=$(mktemp -d "$(dirname "$out")/.bundle.XXXXXX")
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/roles/$role" "$stage/skills" "$stage/bin"
cp "$src/agents/$role/ROLE.md" "$stage/roles/$role/ROLE.md"
chmod u+w "$stage/roles/$role/ROLE.md"   # a store source is read-only; the copy must stay removable
skills_json='{}'
while IFS= read -r s; do
  cp -r "$src/skills/$s" "$stage/skills/$s"
  chmod -R u+w "$stage/skills/$s"
  skills_json=$(jq -c --arg n "$s" --arg sum "$(tree_sha "$stage/skills/$s")" '.[$n] = {path: ("skills/" + $n), sha256: $sum}' <<<"$skills_json")
done <<<"$selected"
declared=$(jq -c '.skills // [] | sort' <<<"$front")

# the tasks: the role's declared read and run tasks (act tasks stay with the host's audited wrappers), each with the
# tasks it runs after, as the evaluated task-module scripts; a declared task the modules do not define fails the build
scripts_json='{}'
if [ -n "$tasks_src" ]; then
  [ -f "$tasks_src/index.json" ] || fail usage "--tasks $tasks_src has no index.json"
  want=$(jq -r '((.tasks.read // []) + (.tasks.run // []))[]' <<<"$front")
  closure=$(jq -r --argjson want "$(jq -Rsc 'split("\n") | map(select(length > 0))' <<<"$want")" '
    . as $idx | def deps($n): [$n] + ([($idx[$n].after // [])[] | deps(.)] | add // []);
    [$want[] | deps(.)] | flatten | unique | .[]' "$tasks_src/index.json")
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    [ -x "$tasks_src/$n" ] && jq -e --arg n "$n" 'has($n)' "$tasks_src/index.json" >/dev/null \
      || fail task "role $role declares task $n, which task-modules/ and agents/$role/ do not define"
  done <<<"$want"
  mkdir -p "$stage/tasks"
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    cp "$tasks_src/$n" "$stage/tasks/$n"; chmod 755 "$stage/tasks/$n"
    scripts_json=$(jq -c --arg n "$n" --arg sum "$(sha256sum <"$stage/tasks/$n" | cut -c1-64)" --argjson after "$(jq -c --arg n "$n" '.[$n].after' "$tasks_src/index.json")" \
      --argjson succ "$(jq -c --arg n "$n" '.[$n].afterSucceeded // []' "$tasks_src/index.json")" --argjson input "$(jq -c --arg n "$n" '.[$n].input // {}' "$tasks_src/index.json")" \
      --argjson declared "$(grep -qxF "$n" <<<"$want" && echo true || echo false)" \
      '.[$n] = {path: ("tasks/" + $n), sha256: $sum, after: $after, afterSucceeded: $succ, input: $input, declared: $declared}' <<<"$scripts_json")
  done <<<"$closure"
fi
bundled=$(printf '%s\n' "$selected" | jq -Rsc 'split("\n") | map(select(length > 0))')

# the harness layout: claude-code reads .claude/agents/<role>.md and .claude/skills/<name>/SKILL.md;
# the adapter's own skills list is narrowed to what the bundle holds
case $harness in
  claude-code)
    mkdir -p "$stage/claude/agents"
    yq --front-matter=process ".skills = ((.skills // []) - ((.skills // []) - $bundled))" "$src/$adapter_src" >"$stage/$adapter"
    ln -s claude "$stage/.claude"
    ln -s ../skills "$stage/claude/skills"
    policy=$(yq --front-matter=extract -o=json '{"tools": (.tools // []), "disallowedTools": (.disallowedTools // []), "permissionMode": (.permissionMode // null)}' "$src/$adapter_src")
    ;;
  codex)
    mkdir -p "$stage/codex"
    cp "$src/$adapter_src" "$stage/$adapter"; chmod u+w "$stage/$adapter"
    # a codex agent file carries no tool policy of its own: the host's codex config sets sandbox and approvals
    policy=$(yq -p toml -o=json '{"sandbox_mode": (.sandbox_mode // null), "approval_policy": (.approval_policy // null)}' "$src/$adapter_src" 2>/dev/null) \
      || fail harness "$adapter_src is not valid TOML"
    policy=$(jq -c 'if .sandbox_mode == null and .approval_policy == null then . + {policySource: "host codex config"} else . + {policySource: "agent file"} end' <<<"$policy")
    ;;
esac

body=$(jq -nc --arg rev "$rev" --arg role "$role" --arg harness "$harness" --arg adapter "$adapter" \
  --arg role_sum "$(sha256sum <"$stage/roles/$role/ROLE.md" | cut -c1-64)" --arg adapter_sum "$(sha256sum <"$stage/$adapter" | cut -c1-64)" \
  --argjson front "$front" --argjson skills "$skills_json" --argjson declared "$declared" --argjson bundled "$bundled" --argjson policy "$policy" --argjson scripts "$scripts_json" '
  {schemaVersion: 1, kind: "agent-skill-bundle",
   source: {rev: $rev},
   role: {name: $role, version: ($front.version // null), contract: ("roles/" + $role + "/ROLE.md"), sha256: $role_sum,
          declaredSkills: $declared, declaredSkillsAbsent: ($declared - $bundled)},
   harness: {name: $harness, adapter: $adapter, sha256: $adapter_sum},
   skills: $skills,
   tasks: {read: ($front.tasks.read // []), run: ($front.tasks.run // []), act: ($front.tasks.act // []), scripts: $scripts},
   authorization: {forbidden: ($front.forbidden // []), act: ($front.tasks.act // []), adapter: $policy},
   entrypoints: ({check: "bin/bundle-check"} + (if ($scripts | length) > 0 then {run: "bin/bundle-run"} else {} end))}')
jq -S --arg d "$(jq -cS . <<<"$body" | sha256sum | cut -c1-64)" '. + {digests: {bundle: $d}}' <<<"$body" >"$stage/bundle.json"

# the entrypoint: no network, no credentials; verifies the bundle against its manifest
cat >"$stage/bin/bundle-check" <<'CHECK'
#!/usr/bin/env bash
# Verify this bundle against bundle.json (role, adapter and skill sha256s) and print the role's tasks.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
m=$here/bundle.json
fail() { jq -nc --arg m "$1" '{error: {class: "integrity", message: $m}}' >&2; exit 1; }
tree_sha() {
  (cd "$1" && find . -mindepth 1 \( -type f -o -type l -o \( -type d -empty \) \) -print0 | LC_ALL=C sort -z | while IFS= read -r -d '' f; do
    printf '%s\0' "$f"
    if [ -L "$f" ]; then printf 'link:%s\0' "$(readlink "$f")"
    elif [ -d "$f" ]; then printf 'dir\0'
    else printf 'mode:%s\0' "$( [ -x "$f" ] && echo x || echo -)"; sha256sum <"$f" | cut -c1-64; fi
  done) | sha256sum | cut -c1-64
}
[ "$(sha256sum <"$here/$(jq -r .role.contract "$m")" | cut -c1-64)" = "$(jq -r .role.sha256 "$m")" ] || fail "the role contract does not match bundle.json"
[ "$(sha256sum <"$here/$(jq -r .harness.adapter "$m")" | cut -c1-64)" = "$(jq -r .harness.sha256 "$m")" ] || fail "the harness adapter does not match bundle.json"
for s in $(jq -r '.skills | keys[]' "$m"); do
  [ "$(tree_sha "$here/$(jq -r --arg s "$s" '.skills[$s].path' "$m")")" = "$(jq -r --arg s "$s" '.skills[$s].sha256' "$m")" ] || fail "skill $s does not match bundle.json"
done
for n in $(jq -r '.tasks.scripts // {} | keys[]' "$m"); do
  [ "$(sha256sum <"$here/$(jq -r --arg n "$n" '.tasks.scripts[$n].path' "$m")" | cut -c1-64)" = "$(jq -r --arg n "$n" '.tasks.scripts[$n].sha256' "$m")" ] || fail "task $n does not match bundle.json"
done
if [ -d "$here/tasks" ] || [ "$(jq '.tasks.scripts // {} | length' "$m")" -gt 0 ]; then
  [ "$(find "$here/tasks" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | LC_ALL=C sort | tr '\n' ' ')" = "$(jq -r '.tasks.scripts | keys | join(" ") + (if length > 0 then " " else "" end)' "$m")" ] \
    || fail "tasks/ holds other entries than bundle.json names"
fi
# exactly the manifest's skills and role, nothing added beside them
[ "$(find "$here/skills" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort | tr '\n' ' ')" = "$(jq -r '.skills | keys | join(" ") + (if length > 0 then " " else "" end)' "$m")" ] \
  || fail "skills/ holds other entries than bundle.json names"
[ "$(find "$here/roles" -mindepth 1 -maxdepth 1 -printf '%f\n' | tr '\n' ' ')" = "$(jq -r '.role.name' "$m") " ] || fail "roles/ holds other entries than bundle.json names"
if [ "$(jq -r .harness.name "$m")" = claude-code ]; then
  [ "$(readlink "$here/.claude")" = claude ] && [ "$(readlink "$here/claude/skills")" = ../skills ] || fail "the .claude layout points elsewhere than the bundled skills"
fi
# the manifest itself: its digest over everything but the digest
[ "$(jq -cS 'del(.digests)' "$m" | sha256sum | cut -c1-64)" = "$(jq -r .digests.bundle "$m")" ] || fail "bundle.json does not match its own digest"
jq -r '"\(.role.name): read \(.tasks.read | join(",") | if . == "" then "-" else . end); run \(.tasks.run | join(",") | if . == "" then "-" else . end); act \(.tasks.act | join(",") | if . == "" then "-" else . end)"' "$m"
CHECK
chmod 755 "$stage/bin/bundle-check"
pin_runtime() { [ -z "$runtime" ] || sed -i "2i export PATH=$runtime\${PATH:+:\$PATH}" "$1"; }
pin_runtime "$stage/bin/bundle-check"
if [ "$(jq '.tasks.scripts | length' "$stage/bundle.json")" -gt 0 ]; then
cat >"$stage/bin/bundle-run" <<'RUN'
#!/usr/bin/env bash
# bundle-run <task> [input-json]: run one task this bundle ships, after the tasks it depends on, the way devenv
# would: DEVENV_TASK_INPUT is the task's declared `input` defaults overlaid by the caller's JSON (dependencies get
# their defaults), DEVENV_TASK_OUTPUT_FILE, the outputs of its `after` tasks in DEVENV_TASKS_OUTPUTS; a failed
# dependency stops the run only on an `@succeeded` edge (every other edge is `@completed`);
# prints the task's output record and exits with its exit code. Only shipped tasks run; nothing is fetched.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
m=$here/bundle.json
[ $# -ge 1 ] || { echo 'usage: bundle-run <task> [input-json]' >&2; exit 3; }
jq -e --arg n "$1" '.tasks.scripts | has($n)' "$m" >/dev/null \
  || { jq -nc --arg n "$1" --arg k "$(jq -r '.tasks.scripts | keys | join(", ")' "$m")" '{error: {class: "task", message: ("this bundle ships no task \($n) (it ships: \($k))")}}' >&2; exit 3; }
"$here/bin/bundle-check" >/dev/null || exit 1
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
outputs='{}'
run_one() { # <task> <input-json> -> its exit code; records its output in $outputs
  local n=$1 rc=0 dep
  local input drc
  for dep in $(jq -r --arg n "$n" '.tasks.scripts[$n].after[]' "$m"); do
    jq -e --arg d "$dep" 'has($d)' <<<"$outputs" >/dev/null && continue
    drc=0; run_one "$dep" '{}' >/dev/null || drc=$?
    if [ "$drc" -ne 0 ] && jq -e --arg n "$n" --arg d "$dep" '.tasks.scripts[$n].afterSucceeded // [] | index($d)' "$m" >/dev/null; then
      jq -nc --arg n "$n" --arg d "$dep" --argjson rc "$drc" '{error: {class: "dependency", message: ("\($n) runs after \($d) succeeded; it exited \($rc)")}}' >&2
      return "$drc"
    fi
  done
  input=$(jq -c --arg n "$n" --argjson caller "$2" '(.tasks.scripts[$n].input // {}) + $caller' "$m") \
    || { jq -nc '{error: {class: "input", message: "the input is not a JSON object"}}' >&2; return 3; }
  DEVENV_TASK_INPUT="$input" DEVENV_TASK_OUTPUT_FILE="$work/$n.out" DEVENV_TASKS_OUTPUTS="$outputs" \
    "$here/$(jq -r --arg n "$n" '.tasks.scripts[$n].path' "$m")" > "$work/$n.log" 2>&1 || rc=$?
  outputs=$(jq -c --arg n "$n" --slurpfile o <(cat "$work/$n.out" 2>/dev/null || echo null) '.[$n] = ($o[0] // null)' <<<"$outputs")
  return "$rc"
}
rc=0; run_one "$1" "${2:-{\}}" || rc=$?
if [ -s "$work/$1.out" ]; then cat "$work/$1.out"; elif [ -f "$work/$1.log" ]; then tail -n 5 "$work/$1.log" >&2; fi
exit "$rc"
RUN
chmod 755 "$stage/bin/bundle-run"
pin_runtime "$stage/bin/bundle-run"
fi
mv -T "$stage" "$out" || fail usage "$out appeared while the bundle was built"
trap - EXIT
