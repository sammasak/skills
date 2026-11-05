#!/usr/bin/env bash
# Build one agent skill bundle (skills#63): exactly the named skills and one role contract from a
# pinned skills tree, in the layout one harness reads, with bundle.json (agent-skill-bundle,
# schemaVersion 1). Skills are visibility only; what the agent may do is the role's `forbidden`
# list, its `act` tasks and the adapter's tool policy, recorded apart under `authorization`.
# Every failure ends stderr with one JSON line; the class fixes the exit code. Nothing is written
# unless the whole bundle is.
#
#   build.sh --src DIR --rev SHA --role NAME --harness claude-code|codex|pi --skill NAME... --out DIR
set -euo pipefail
fail() { # <class> <message>
  local code
  case $1 in usage) code=2 ;; role) code=3 ;; skill) code=4 ;; harness) code=5 ;; *) code=1 ;; esac
  jq -nc --arg c "$1" --arg m "$2" '{error: {class: $c, message: $m}}' >&2
  exit "$code"
}
USAGE='build.sh --src DIR --rev SHA --role NAME --harness claude-code|codex|pi --skill NAME... --out DIR'
src='' rev='' role='' harness='' out='' skills=()
while [ $# -gt 0 ]; do
  case $1 in
    --src | --rev | --role | --harness | --out | --skill) [ $# -ge 2 ] || fail usage "usage: $USAGE" ;;&
    --src) src=$2; shift 2 ;;
    --rev) rev=$2; shift 2 ;;
    --role) role=$2; shift 2 ;;
    --harness) harness=$2; shift 2 ;;
    --out) out=$2; shift 2 ;;
    --skill) skills+=("$2"); shift 2 ;;
    *) fail usage "usage: $USAGE" ;;
  esac
done
[ -n "$src" ] && [ -n "$rev" ] && [ -n "$role" ] && [ -n "$harness" ] && [ -n "$out" ] || fail usage "usage: $USAGE"
[[ $rev =~ ^[0-9a-f]{40}$ ]] || fail usage "rev must be the 40-hex revision of the skills source, got '$rev'"
[ -d "$src/skills" ] && [ -d "$src/agents" ] || fail usage "$src is not a skills tree (no skills/ and agents/)"
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
  (cd "$1" && find . \( -type f -o -type l \) -print0 | LC_ALL=C sort -z | while IFS= read -r -d '' f; do
    printf '%s\0' "$f"
    if [ -L "$f" ]; then printf 'link:%s\0' "$(readlink "$f")"; else sha256sum <"$f" | cut -c1-64; fi
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
    policy=$(yq -p toml -o=json '{"sandbox_mode": (.sandbox_mode // null), "approval_policy": (.approval_policy // null)}' "$src/$adapter_src" 2>/dev/null) || policy='{}'
    ;;
esac

body=$(jq -nc --arg rev "$rev" --arg role "$role" --arg harness "$harness" --arg adapter "$adapter" \
  --arg role_sum "$(sha256sum <"$stage/roles/$role/ROLE.md" | cut -c1-64)" --arg adapter_sum "$(sha256sum <"$stage/$adapter" | cut -c1-64)" \
  --argjson front "$front" --argjson skills "$skills_json" --argjson declared "$declared" --argjson bundled "$bundled" --argjson policy "$policy" '
  {schemaVersion: 1, kind: "agent-skill-bundle",
   source: {rev: $rev},
   role: {name: $role, version: ($front.version // null), contract: ("roles/" + $role + "/ROLE.md"), sha256: $role_sum,
          declaredSkills: $declared, declaredSkillsAbsent: ($declared - $bundled)},
   harness: {name: $harness, adapter: $adapter, sha256: $adapter_sum},
   skills: $skills,
   tasks: {read: ($front.tasks.read // []), run: ($front.tasks.run // []), act: ($front.tasks.act // [])},
   authorization: {forbidden: ($front.forbidden // []), act: ($front.tasks.act // []), adapter: $policy},
   entrypoints: {check: "bin/bundle-check"}}')
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
  (cd "$1" && find . \( -type f -o -type l \) -print0 | LC_ALL=C sort -z | while IFS= read -r -d '' f; do
    printf '%s\0' "$f"
    if [ -L "$f" ]; then printf 'link:%s\0' "$(readlink "$f")"; else sha256sum <"$f" | cut -c1-64; fi
  done) | sha256sum | cut -c1-64
}
[ "$(sha256sum <"$here/$(jq -r .role.contract "$m")" | cut -c1-64)" = "$(jq -r .role.sha256 "$m")" ] || fail "the role contract does not match bundle.json"
[ "$(sha256sum <"$here/$(jq -r .harness.adapter "$m")" | cut -c1-64)" = "$(jq -r .harness.sha256 "$m")" ] || fail "the harness adapter does not match bundle.json"
for s in $(jq -r '.skills | keys[]' "$m"); do
  [ "$(tree_sha "$here/$(jq -r --arg s "$s" '.skills[$s].path' "$m")")" = "$(jq -r --arg s "$s" '.skills[$s].sha256' "$m")" ] || fail "skill $s does not match bundle.json"
done
jq -r '"\(.role.name): read \(.tasks.read | join(",") | if . == "" then "-" else . end); run \(.tasks.run | join(",") | if . == "" then "-" else . end); act \(.tasks.act | join(",") | if . == "" then "-" else . end)"' "$m"
CHECK
chmod 755 "$stage/bin/bundle-check"
mv "$stage" "$out"
trap - EXIT
