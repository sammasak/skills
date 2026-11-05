#!/usr/bin/env bash
# Tests for bundles/build.sh (skills#63): a bundle holds exactly the named skills and one real role
# contract, fails predictably on bad input, changes digest with its source, keeps authorization
# apart from visibility, and ships a check entrypoint that runs with no network or credentials.
#
#   bash tests/test-bundles.sh
# shellcheck disable=SC2016 # jq programs in single quotes
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/bundles/build.sh"
T=$(mktemp -d)
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
REV=0123456789abcdef0123456789abcdef01234567
fails=0
ok() { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; fails=$((fails + 1)); }
expect() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi; }
class() { tail -n 1 "$1" | jq -r '.error.class' 2>/dev/null || echo "(no json error)"; }
# build OUT [args...]: sets rc; stderr in $T/err
build() { local out=$1; shift; rc=0; bash "$BUILD" --out "$out" "$@" 2>"$T/err" >/dev/null || rc=$?; }
pilot=(--src "$ROOT" --rev "$REV" --role quality --harness claude-code --skill rust-engineering --skill nix-flake-development)

# the pilot: rust-engineering and nix-flake-development with the real quality role
build "$T/b1" "${pilot[@]}"
B="$T/b1/bundle.json"
expect "pilot: exit 0, kind and schema" "0 agent-skill-bundle 1" "$rc $(jq -r '"\(.kind) \(.schemaVersion)"' "$B" 2>/dev/null)"
expect "pilot: exactly the named skills, in the manifest and on disk" "nix-flake-development,rust-engineering nix-flake-development rust-engineering" \
  "$(jq -r '.skills | keys | join(",")' "$B") $(find "$T/b1/skills" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
expect "pilot: the role contract is the real one, byte for byte" "same" "$(cmp -s "$ROOT/agents/quality/ROLE.md" "$T/b1/roles/quality/ROLE.md" && echo same || echo differ)"
expect "pilot: role, version, source rev and harness recorded" "quality 1 $REV claude-code" "$(jq -r '"\(.role.name) \(.role.version) \(.source.rev) \(.harness.name)"' "$B")"
expect "pilot: the role's declared tasks are carried" "quality:report,gh:work,git:recent quality:gate " \
  "$(jq -r '"\(.tasks.read | join(",")) \(.tasks.run | join(",")) \(.tasks.act | join(","))"' "$B")"
expect "pilot: declared role skills that are not bundled are named, not added" "orchestrated-review,sdlc-pipeline" "$(jq -r '.role.declaredSkillsAbsent | join(",")' "$B")"
expect "pilot: the claude-code adapter lists only bundled skills" "rust-engineering" \
  "$(yq --front-matter=extract '.skills | join(",")' "$T/b1/.claude/agents/quality.md")"
expect "pilot: claude-code finds the skills at .claude/skills" "true true" \
  "$([ -f "$T/b1/.claude/skills/rust-engineering/SKILL.md" ] && echo true || echo false) $([ -e "$T/b1/.claude/skills/sdlc-pipeline" ] && echo false || echo true)"
expect "pilot: every skill and the role carry a 64-hex sha256; the bundle digest too" "true" \
  "$(jq '[.skills[].sha256, .role.sha256, .harness.sha256, .digests.bundle] | all(test("^[0-9a-f]{64}$"))' "$B")"
build "$T/b1again" "${pilot[@]}"
expect "the same inputs give a byte-identical bundle.json" "same" "$(cmp -s "$B" "$T/b1again/bundle.json" && echo same || echo differ)"
rc=0; build "$T/b1" "${pilot[@]}"
expect "an existing output is refused" "2 usage" "$rc $(class "$T/err")"

# predictable failures, each with its class and nothing written
n=0
for case in "skill:rust-engineerin" "skill:../agents" "skill:" "dup:rust-engineering"; do
  kind=${case%%:*} name=${case#*:}
  if [ "$kind" = dup ]; then build "$T/f$n" --src "$ROOT" --rev "$REV" --role quality --harness claude-code --skill "$name" --skill "$name"
  else build "$T/f$n" --src "$ROOT" --rev "$REV" --role quality --harness claude-code --skill "$name"; fi
  if [ "$rc" -ne 0 ] && [ "$(class "$T/err")" = skill ] && [ ! -e "$T/f$n" ]; then n=$((n + 1)); else bad "skill case '$case' not refused as class skill (rc $rc $(class "$T/err"))"; fi
done
expect "unknown, misspelled, traversing, empty and duplicate skill names fail as class skill, nothing written" 4 "$n"
build "$T/f-misspelled" --src "$ROOT" --rev "$REV" --role quality --harness claude-code --skill rust-engineerin
expect "a misspelling names the closest known skill" "true" "$(grep -q 'did you mean rust-engineering' "$T/err" && echo true || echo false)"
build "$T/f-far" --src "$ROOT" --rev "$REV" --role quality --harness claude-code --skill zzz-nothing-like-it
expect "an unknown name with no near match is refused without a guess" "skill false" "$(class "$T/err") $(grep -q 'did you mean' "$T/err" && echo true || echo false)"
build "$T/f-noskill" --src "$ROOT" --rev "$REV" --role quality --harness claude-code
expect "no skill named: class skill" "skill" "$(class "$T/err")"
build "$T/f-role" --src "$ROOT" --rev "$REV" --role nonesuch --harness claude-code --skill rust-engineering
expect "an unknown role: class role" "role" "$(class "$T/err")"
build "$T/f-codex" --src "$ROOT" --rev "$REV" --role quality --harness codex --skill rust-engineering
expect "quality has no codex adapter: class harness (unsupported combination)" "harness" "$(class "$T/err")"
build "$T/f-pi" --src "$ROOT" --rev "$REV" --role coordinator --harness pi --skill herdr
expect "no pi adapter for any role: class harness" "harness" "$(class "$T/err")"
build "$T/f-hx" --src "$ROOT" --rev "$REV" --role quality --harness gemini --skill rust-engineering
expect "a harness name outside claude-code, codex, pi: class usage" "usage" "$(class "$T/err")"
build "$T/f-rev" --src "$ROOT" --rev main --role quality --harness claude-code --skill rust-engineering
expect "a rev that is not 40 hex: class usage" "usage" "$(class "$T/err")"
build "$T/codex" --src "$ROOT" --rev "$REV" --role coordinator --harness codex --skill herdr --skill herdr-operations
expect "a codex agent file carries no tool policy: the bundle says the host's codex config sets it" "host codex config" "$(jq -r .authorization.adapter.policySource "$T/codex/bundle.json")"
expect "coordinator with codex: its codex.toml is the adapter" "0 codex/coordinator.toml same" \
  "$rc $(jq -r .harness.adapter "$T/codex/bundle.json") $(cmp -s "$ROOT/agents/coordinator/codex.toml" "$T/codex/codex/coordinator.toml" && echo same || echo differ)"

# the digest follows the pinned source: one changed skill moves its sha and the bundle digest, not the other skill's
SRC2="$T/src2"; cp -r "$ROOT/agents" "$ROOT/skills" -t "$(mkdir -p "$SRC2" && echo "$SRC2")"
printf '\nA changed line.\n' >>"$SRC2/skills/rust-engineering/SKILL.md"
build "$T/b2" --src "$SRC2" --rev "$REV" --role quality --harness claude-code --skill rust-engineering --skill nix-flake-development
expect "a changed skill changes its sha256 and the bundle digest; the untouched skill keeps its sha256" "true true true" \
  "$(jq -n --slurpfile a "$B" --slurpfile b "$T/b2/bundle.json" '[$a[0].skills["rust-engineering"].sha256 != $b[0].skills["rust-engineering"].sha256,
     $a[0].digests.bundle != $b[0].digests.bundle, $a[0].skills["nix-flake-development"].sha256 == $b[0].skills["nix-flake-development"].sha256] | map(tostring) | join(" ")' -r)"
build "$T/b3" --src "$ROOT" --rev fedcba9876543210fedcba9876543210fedcba98 --role quality --harness claude-code --skill rust-engineering --skill nix-flake-development
expect "another source rev with the same files is another bundle digest" "true" "$(jq -n --slurpfile a "$B" --slurpfile b "$T/b3/bundle.json" '$a[0].digests.bundle != $b[0].digests.bundle')"

# visibility is not authorization: adding the credentials skill changes nothing under authorization
build "$T/b4" "${pilot[@]}" --skill credentials
expect "a bundled skill grants nothing: authorization is identical with or without the credentials skill" "true true" \
  "$(jq -n --slurpfile a "$B" --slurpfile b "$T/b4/bundle.json" '[$a[0].authorization == $b[0].authorization, ($b[0].skills | has("credentials"))] | map(tostring) | join(" ")' -r)"
expect "authorization carries the role's forbidden list, its act tasks and the adapter's tool policy" "true true Edit" \
  "$(jq -r '"\(.authorization.forbidden | length > 0) \(.authorization.act == []) \(.authorization.adapter.disallowedTools[0])"' "$B")"

# the entrypoint runs with no network, no HOME and no credentials, and catches a tampered bundle
envrun() { env -i PATH="$(dirname "$(command -v bash)"):$(dirname "$(command -v jq)"):$(dirname "$(command -v sha256sum)"):$(dirname "$(command -v find)"):/var/empty" HOME=/nonexistent "$@"; }
rc=0; envrun "$T/b1/bin/bundle-check" >"$T/check.out" 2>"$T/err" || rc=$?
expect "bin/bundle-check: exit 0 in an empty environment, names the role and its tasks" "0 true" \
  "$rc $(grep -q 'quality: read quality:report,gh:work,git:recent; run quality:gate; act -' "$T/check.out" && echo true || echo false)"
# tampering bundle-check must catch: an added skill, an edited manifest, a redirected harness link, a lost exec bit
tamper() { rm -rf "$T/t"; cp -a "$T/b1again" "$T/t"; chmod -R u+w "$T/t"; "$@"; rc=0; envrun "$T/t/bin/bundle-check" >/dev/null 2>"$T/err" || rc=$?; echo "$rc $(class "$T/err")"; }
expect "an extra skill copied into skills/ is refused" "1 integrity" "$(tamper cp -r "$ROOT/skills/credentials" "$T/t/skills/")"
expect "a manifest with its authorization emptied is refused (its digest no longer matches)" "1 integrity" \
  "$(tamper sh -c "jq '.authorization.forbidden = [] | .authorization.adapter.disallowedTools = []' '$T/t/bundle.json' > '$T/t/bj' && mv '$T/t/bj' '$T/t/bundle.json'")"
expect "a .claude link pointing elsewhere is refused" "1 integrity" "$(tamper sh -c "rm '$T/t/claude/skills' && ln -s /etc '$T/t/claude/skills'")"
x=$(find "$T/b1again/skills" -type f -perm -u+x | head -n 1)
if [ -n "$x" ]; then
  expect "a lost exec bit changes the skill's hash" "1 integrity" "$(tamper chmod a-x "$T/t/${x#"$T/b1again/"}")"
else
  expect "an exec bit added to a skill file changes the skill's hash" "1 integrity" "$(tamper chmod +x "$T/t/skills/rust-engineering/SKILL.md")"
fi
chmod -R u+w "$T/b1"; printf 'tampered\n' >>"$T/b1/skills/nix-flake-development/SKILL.md"
rc=0; envrun "$T/b1/bin/bundle-check" >/dev/null 2>"$T/err" || rc=$?
expect "bin/bundle-check refuses a bundle whose skill no longer matches its sha256" "1 integrity" "$rc $(class "$T/err")"

# the Nix entry point builds the same bundle (what nixos-config consumes through inputs.skills)
nixb=$(nix build --no-link --print-out-paths --impure --expr "
  let pkgs = import (builtins.getFlake \"nixpkgs\") { }; in
  (import $ROOT/bundles { inherit pkgs; src = $ROOT; rev = \"$REV\"; }).bundle {
    role = \"quality\"; harness = \"claude-code\"; skills = [ \"rust-engineering\" \"nix-flake-development\" ]; }" 2>"$T/nix.err") || nixb=""
expect "bundles/default.nix builds a bundle with the same skills and role digest as the script" "true" \
  "$([ -n "$nixb" ] && jq -n --slurpfile a "$B" --slurpfile b "$nixb/bundle.json" '$a[0].skills == $b[0].skills and $a[0].role == $b[0].role' || echo "false: $(tail -n 3 "$T/nix.err")")"

echo
if [ "$fails" -eq 0 ]; then echo "bundles: all checks passed"; else echo "bundles: $fails failure(s)"; exit 1; fi
