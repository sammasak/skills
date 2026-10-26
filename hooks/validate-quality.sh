#!/usr/bin/env bash
# Quality guard: the shared role guard with ROLE pinned (referenced by the adapter frontmatter and nixos-config).
ROLE=quality exec "$(dirname "$(readlink -f "$0")")/validate-role.sh"
