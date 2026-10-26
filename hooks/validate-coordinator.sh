#!/usr/bin/env bash
# Coordinator guard: the shared role guard with ROLE pinned. Kept as its own file
# because nixos-config and the adapter frontmatter reference this path.
ROLE=coordinator exec "$(dirname "$(readlink -f "$0")")/validate-role.sh"
