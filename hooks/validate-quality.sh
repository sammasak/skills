#!/usr/bin/env bash
ROLE=quality exec "$(dirname "$(readlink -f "$0")")/validate-role.sh"
