#!/usr/bin/env bash
# One integrity predicate for a materialised checkout, shared by the guard (every Bash call) and the nixos-config
# activation (rebuild decision), so a copy the guard refuses is exactly a copy the activation rebuilds.
# Usage: integrity-check.sh <dir> <pin-sha256|-> [role...]   exit 0 = intact; exit 1 = reason on stderr
set -uo pipefail
dir="${1:-}"; pin="${2:--}"; shift 2 2>/dev/null || { echo "usage: integrity-check.sh <dir> <pin|-> [role...]" >&2; exit 2; }
[ -f "$dir/.integrity" ] || { echo "no .integrity manifest in $dir" >&2; exit 1; }
if [ "$pin" != - ]; then
  [ "$(sha256sum "$dir/.integrity" | cut -d' ' -f1)" = "$pin" ] || { echo ".integrity does not match the pinned hash" >&2; exit 1; }
fi
(cd "$dir" && sha256sum --check --quiet --strict .integrity >/dev/null 2>&1) || { echo "checkout integrity check failed (a listed file changed or is missing)" >&2; exit 1; }
listed() { grep -qE "^[0-9a-f]{64}  (\./)?${1//./\\.}\$" "$dir/.integrity"; }
for must in hooks/validate-role.sh hooks/lib/role-list.awk hooks/lib/integrity-check.sh devenv.nix devenv.lock; do
  listed "$must" || { echo ".integrity does not cover $must" >&2; exit 1; }
done
for role in "$@"; do
  listed "agents/$role/ROLE.md" || { echo ".integrity does not cover agents/$role/ROLE.md" >&2; exit 1; }
done
# files a harness reads as policy or that redirect evaluation: present means they must be manifest-listed
for extra in devenv.local.nix devenv.local.yaml .claude/settings.json .claude/settings.local.json AGENTS.md AGENTS.override.md CLAUDE.md .mcp.json .codex/config.toml .codex/hooks.json; do
  [ -e "$dir/$extra" ] || continue
  listed "$extra" || { echo "$extra is present but not covered by .integrity" >&2; exit 1; }
done
