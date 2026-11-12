#!/usr/bin/env bash
# Shunt policy shared by hooks/shunt-check-*.sh and scripts/bulk-read.sh:
# thresholds, the sensitive-path list, non-text detection and line counting.
# coreutils only (no grep/sed/awk) so the delegating script needs nothing more.
# The hooks are an optimisation and fail open; bulk-read.sh's refusal of
# shunt_sensitive paths is the real guard on what leaves the machine.

SHUNT_DEFAULT_MIN_LINES=350
SHUNT_DEFAULT_MIN_BYTES=60000

# shunt_int <value> <default>: the value when it is a plain non-negative integer.
shunt_int() {
  case "$1" in
    '' | *[!0-9]*) echo "$2" ;;
    *) echo "$((10#$1))" ;;
  esac
}

shunt_threshold() { shunt_int "${SHUNT_MIN_LINES:-}" "$SHUNT_DEFAULT_MIN_LINES"; }
shunt_min_bytes() { shunt_int "${SHUNT_MIN_BYTES:-}" "$SHUNT_DEFAULT_MIN_BYTES"; }

# shunt_abs <path> <cwd>: lexical absolute path (symlinks are NOT resolved here).
shunt_abs() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "${2:-$PWD}" "$1" ;;
  esac
}

_shunt_sensitive_one() {
  local p="$1" b pat
  b="${p##*/}"
  b="${b,,}"
  case "$b" in
    .env | .env.* | *.pem | *.key | *.p12 | *.pfx | *.kdbx | \
    id_rsa* | id_ed25519* | id_ecdsa* | *.secret.yaml | *.secret.yml | *.sops.* | \
    .netrc | .npmrc | .pypirc | credentials* | *token*)
      return 0 ;;
  esac
  case "/$p/" in
    */secrets/* | */.ssh/* | */.gnupg/* | */.aws/* | */.kube/* | */.config/gh/* | */.config/sops/* | \
    //run/secrets* | //run/agent-runtime/credentials* | //run/egress* | \
    //etc/shadow* | //etc/gshadow* | //etc/sudoers* | //etc/ssh/ssh_host_*)
      return 0 ;;
  esac
  if [ -n "${SHUNT_EXCLUDE:-}" ]; then
    local IFS=':'
    for pat in $SHUNT_EXCLUDE; do
      [ -n "$pat" ] || continue
      # shellcheck disable=SC2053  # $pat is a glob on purpose
      if [[ "$p" == $pat ]] || [[ "${p##*/}" == $pat ]]; then return 0; fi
    done
  fi
  return 1
}

# shunt_sensitive <path> [cwd]: 0 when the path as given, its absolute form, or
# its symlink-resolved target is sensitive or matches SHUNT_EXCLUDE.
shunt_sensitive() {
  local p="$1" abs real
  abs=$(shunt_abs "$p" "${2:-$PWD}")
  _shunt_sensitive_one "$p" && return 0
  _shunt_sensitive_one "$abs" && return 0
  real=$(realpath -e -- "$abs" 2>/dev/null) || return 1
  _shunt_sensitive_one "$real"
}

# shunt_nontext <file>: 0 for images, PDFs, notebooks, or a NUL byte in the first 64 KiB.
shunt_nontext() {
  local b="${1##*/}" head_bytes text_bytes
  case "${b,,}" in
    *.png | *.jpg | *.jpeg | *.gif | *.webp | *.svg | *.pdf | *.ipynb) return 0 ;;
  esac
  head_bytes=$(head -c 65536 -- "$1" 2>/dev/null | wc -c) || return 1
  text_bytes=$(head -c 65536 -- "$1" 2>/dev/null | tr -d '\000' | wc -c) || return 1
  [ "$head_bytes" -ne "$text_bytes" ]
}

# shunt_count_lines <file>: lines as a reader sees them (a final unterminated line counts).
shunt_count_lines() {
  local n
  n=$(wc -l < "$1" 2>/dev/null) || return 1
  if [ -s "$1" ] && [ "$(tail -c 1 -- "$1" | wc -l)" -eq 0 ]; then n=$((n + 1)); fi
  echo "$n"
}

shunt_count_bytes() { wc -c < "$1" 2>/dev/null; }

shunt_script_path() { printf '%s/scripts/bulk-read.sh\n' "$(cd "$1/.." && pwd)"; }
