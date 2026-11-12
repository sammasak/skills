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

# The refusal list, matched on the lowercased path. Over-matching is deliberate:
# a false positive only means the file is read normally instead of delegated.
# A name list always has another gap, so shunt_private and shunt_secret_marker
# back it with checks on the file itself.
shunt_sensitive_name() {
  local p="$1" lp b pat pats
  lp="${p,,}"
  b="${lp##*/}"
  case "$b" in
    .env* | *.env | *.pem* | *.key* | *.p12* | *.pfx* | *.p8 | *.der | *.kdbx* | *.jks | *.gpg | *.asc | *.age | *.ovpn | \
    id_rsa* | id_dsa* | id_ecdsa* | id_ed25519* | ssh_host_* | *private*key* | *key.txt | keys.* | *.sops.* | \
    *passw* | .netrc | .npmrc | .pypirc | .pgpass | .boto | .s3cfg | .my.cnf | .dev.vars | auth.json | \
    wg*.conf | rclone.conf | kube*config* | k3s.yaml | admin.conf | *.tfstate* | *.tfvars | shadow | gshadow)
      return 0 ;;
  esac
  # Any path component (or the name) naming a secret, credential or token (so /run/secrets and
  # /run/agent-runtime/credentials too), and known secret locations.
  case "/$lp/" in
    *secret* | *credential* | *token* | \
    */.ssh/* | */.gnupg/* | */.aws/* | */.azure/* | */.kube/* | */.docker/* | */.codex/* | */.password-store/* | \
    */.config/gh/* | */.config/sops/* | */.config/gcloud/* | */.config/age/* | */.config/rclone/* | */.local/share/keyrings/* | \
    */etc/wireguard/* | */etc/rancher/* | */var/lib/sops-nix/* | \
    //run/egress* | \
    //etc/shadow* | //etc/gshadow* | //etc/sudoers* | //etc/ssh/ssh_host_*)
      return 0 ;;
  esac
  if [ -n "${SHUNT_EXCLUDE:-}" ]; then
    # read -ra splits on ':' without pathname expansion (a bare `for pat in $X` would glob against cwd).
    IFS=: read -ra pats <<< "$SHUNT_EXCLUDE"
    for pat in "${pats[@]}"; do
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
  shunt_sensitive_name "$p" && return 0
  shunt_sensitive_name "$abs" && return 0
  real=$(realpath -e -- "$abs" 2>/dev/null) || return 1
  shunt_sensitive_name "$real"
}

# shunt_private: 0 when the file grants read to neither group nor other
# (0600/0400 style) AND the process umask would normally grant one of them, so
# the mode was chosen on purpose. Under a private umask (077) every file is 0600
# and the mode says nothing, so the check stands down rather than refuse everything.
shunt_private() { # shunt_private <file> [umask]: umask defaults to the current one
  local mode um="${2:-}"
  [ -n "$um" ] || um=$(umask 2>/dev/null) || return 1
  case "$um" in '' | *[!0-7]*) return 1 ;; esac
  [ $(( 8#$um & 8#044 )) -ne $(( 8#044 )) ] || return 1
  mode=$(stat -c %a -- "$1" 2>/dev/null) || return 1
  case "$mode" in '' | *[!0-7]*) return 1 ;; esac
  [ $(( 8#$mode & 8#044 )) -eq 0 ]
}

# shunt_secret_marker <file>: 0 when the first 64 KiB hold a private key or sops-encrypted data.
shunt_secret_marker() {
  local head
  head=$(head -c 65536 -- "$1" 2>/dev/null | tr -d '\000') || return 1
  case "$head" in
    *"PRIVATE KEY-----"* | *"-----BEGIN PGP PRIVATE KEY BLOCK-----"* | *"AGE-SECRET-KEY-1"* | *"ENC[AES256_GCM,"*) return 0 ;;
  esac
  case "$head" in *"sops:"*"ENC["* | *"ENC["*"sops:"*) return 0 ;; esac
  return 1
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

# Shared hook tail (needs lib/log.sh and lib/state.sh). Callers set SHUNT_HOOK,
# START_MS, T, LINES, BYTES and RETURNED.
shunt_done() { # shunt_done <result> [exit]: log the decision and exit
  log_hook "$SHUNT_HOOK" "$1" "$(( ($(date +%s%N) / 1000000) - START_MS ))" \
    "{\"lines\":$LINES,\"bytes\":$BYTES,\"returned\":$RETURNED,\"threshold\":$T}" 2>/dev/null || true
  exit "${2:-0}"
}

# shunt_redirect <hooks_dir> <key> <first line> <file> <exact-content line> <repeat noun> <whole noun>:
# deny the first attempt per session key with the bulk-read command; allow an identical repeat.
shunt_redirect() {
  seen_before "$SHUNT_HOOK" "$2"
  case $? in
    0) shunt_done bypass ;;
    1) ;;
    *) shunt_done nostate ;;
  esac
  cat >&2 <<MSG
$3
To explore or summarise it, run this via Bash instead (see the bulk-reader skill):
  $(shunt_script_path "$1") --question "<what you need to know>" --paths $(printf '%q' "$4")
$5
Repeating this same $6 will be allowed if the whole $7 is truly required.
MSG
  shunt_done redirect 2
}
