#!/usr/bin/env bash
# Shunt policy shared by hooks/shunt-check-*.sh and scripts/bulk-read.sh:
# the token estimate, exemptions, the sensitive-path list, non-text detection,
# line counting, and the hooks' shared tail.
# coreutils only (no grep/sed/awk) so the delegating script needs nothing more.
# The hooks are an optimisation and fail open; bulk-read.sh's refusal of
# shunt_sensitive paths is the real guard on what leaves the machine.

SHUNT_DEFAULT_MIN_TOKENS=8000
SHUNT_DEFAULT_MAX_PAYLOAD_BYTES=200000
SHUNT_DEFAULT_SKIP_AGENTS="Explore,claude-code-guide,statusline-setup"

# shunt_int <value> <default>: the value when it is a plain non-negative integer.
shunt_int() {
  case "$1" in
    '' | *[!0-9]*) echo "$2" ;;
    *) echo "$((10#$1))" ;;
  esac
}

shunt_threshold() { shunt_int "${SHUNT_MIN_TOKENS:-}" "$SHUNT_DEFAULT_MIN_TOKENS"; }
shunt_max_payload() { shunt_int "${SHUNT_MAX_PAYLOAD_BYTES:-}" "$SHUNT_DEFAULT_MAX_PAYLOAD_BYTES"; }

# shunt_tokens <bytes> <lines>: tokens a read of that many bytes and lines puts in
# context (bytes*2/7 + lines*11/10; lines alone under-count markdown about 2x).
shunt_tokens() { echo $(( $1 * 2 / 7 + $2 * 11 / 10 )); }

# shunt_fit_lines <bytes> <lines> <threshold>: the most lines of this file one
# ranged read can return and stay at or under the threshold (0: not even one).
shunt_fit_lines() {
  local b="$1" l="$2" t="$3" n est
  [ "$l" -gt 0 ] || { echo 0; return; }
  est=$(( b * 2 / 7 + l * 11 / 10 ))
  [ "$est" -gt "$t" ] || { echo "$l"; return; }
  n=$(( t * l / est + 1 ))
  while [ "$n" -gt 0 ] && [ $(( (b * n / l) * 2 / 7 + n * 11 / 10 )) -gt "$t" ]; do n=$((n - 1)); done
  echo "$n"
}

# shunt_context_gate: "mode" for a permission mode that cannot run bulk-read.sh
# (dontAsk) or should not be steered (plan), "subagent" for an agent type in
# SHUNT_SKIP_AGENTS (comma separated; set it empty to cover every agent), else nothing.
shunt_context_gate() {
  local pm at a list
  pm=$(echo "${HOOK_INPUT:-}" | jq -r '.permission_mode // ""' 2>/dev/null)
  case "$pm" in dontAsk | plan) echo mode; return ;; esac
  at=$(echo "${HOOK_INPUT:-}" | jq -r '.agent_type // ""' 2>/dev/null)
  [ -n "$at" ] || return 0
  IFS=, read -ra list <<< "${SHUNT_SKIP_AGENTS-$SHUNT_DEFAULT_SKIP_AGENTS}"
  for a in "${list[@]}"; do
    a="${a#"${a%%[![:space:]]*}"}"; a="${a%"${a##*[![:space:]]}"}"
    [ -n "$a" ] && [ "$a" = "$at" ] && { echo subagent; return; }
  done
}

# shunt_source <path>: 0 for source code, which is exempt unless SHUNT_INCLUDE_SOURCE=1
# (a large source read is often followed by an Edit, where delegating is waste).
shunt_source() {
  [ "${SHUNT_INCLUDE_SOURCE:-0}" = 1 ] && return 1
  local b="${1##*/}"
  b="${b,,}"
  case "$b" in
    makefile | gnumakefile | dockerfile | justfile | rakefile | gemfile | *.mk) return 0 ;;
  esac
  case "$b" in
    *.rs | *.nix | *.py | *.pyi | *.ts | *.tsx | *.mts | *.cts | *.js | *.jsx | *.mjs | *.cjs | *.go | \
    *.sh | *.bash | *.zsh | *.fish | *.c | *.h | *.cc | *.cpp | *.cxx | *.hpp | *.hh | *.m | *.mm | \
    *.java | *.kt | *.kts | *.scala | *.groovy | *.gradle | *.rb | *.lua | *.sql | *.tf | *.hcl | *.zig | \
    *.swift | *.cs | *.fs | *.ex | *.exs | *.erl | *.hrl | *.hs | *.ml | *.mli | *.elm | *.dart | *.php | \
    *.pl | *.pm | *.r | *.jl | *.clj | *.cljs | *.nim | *.v | *.vue | *.svelte | *.css | *.scss | *.sass | \
    *.proto | *.cmake | *.ps1 | *.vim | *.el | *.asm | *.s | *.cu | *.wgsl | *.glsl) return 0 ;;
  esac
  return 1
}

# shunt_instructions <path> <resolved> <hooks_dir>: 0 for files an agent must read
# verbatim: CLAUDE.md, AGENTS.md, ROLE.md, SKILL.md, MEMORY.md, anything under a
# .claude/ directory, and anything in the skills repo these hooks live in.
shunt_instructions() {
  local root
  case "${1##*/}" in CLAUDE.md | AGENTS.md | ROLE.md | SKILL.md | MEMORY.md) return 0 ;; esac
  case "${2##*/}" in CLAUDE.md | AGENTS.md | ROLE.md | SKILL.md | MEMORY.md) return 0 ;; esac
  case "$1/" in */.claude/*) return 0 ;; esac
  case "$2/" in */.claude/*) return 0 ;; esac
  root=$(cd "$3/.." 2>/dev/null && pwd -P) || return 1
  case "$2" in "$root"/*) return 0 ;; esac
  return 1
}

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
    wg*.conf | rclone.conf | *history* | .histfile | talosconfig | .msmtprc | .mbsyncrc | .authinfo* | .claude.json | \
    kube*config* | k3s.yaml | admin.conf | *.tfstate* | *.tfvars | shadow | gshadow)
      return 0 ;;
  esac
  # Any path component (or the name) naming a secret, credential or token (so /run/secrets and
  # /run/agent-runtime/credentials too), and known secret locations.
  case "/$lp/" in
    *secret* | *credential* | *token* | \
    */.ssh/* | */.gnupg/* | */.aws/* | */.azure/* | */.kube/* | */.docker/* | */.codex/* | */.password-store/* | \
    */.config/gh/* | */.config/sops/* | */.config/gcloud/* | */.config/age/* | */.config/talos/* | */.config/rclone/* | */.local/share/keyrings/* | \
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

# shunt_secret_marker <file>: 0 when the first 64 KiB look like secret material:
# a private key (PEM or its base64 form, as in kubeconfig client-key-data, Talos
# configs and TLS Secrets, so certificates match too), sops-encrypted data, a
# Kubernetes Secret (also as a List item, quoted, or JSON), a token-auth
# kubeconfig, a WireGuard key, or a GitHub/Anthropic/Nix access token.
# Line-anchored forms only match at a line start (after spaces or "- "), so a
# manifest that merely mentions "kind: Secret" mid-line is still delegated.
_SHUNT_NL=$'\n'
_SHUNT_SECRET_KIND="(^|${_SHUNT_NL})[[:blank:]-]*kind:[[:blank:]]*[\"']?Secret[\"']?[[:blank:]]*(${_SHUNT_NL}|\$)"
_SHUNT_CONFIG_KIND="(^|${_SHUNT_NL})[[:blank:]-]*kind:[[:blank:]]*[\"']?Config[\"']?[[:blank:]]*(${_SHUNT_NL}|\$)"
_SHUNT_TOKEN_LINE="(^|${_SHUNT_NL})[[:blank:]-]*token:[[:blank:]]*[^[:space:]]"
_SHUNT_WG_KEY="(^|${_SHUNT_NL})[[:blank:]]*(PrivateKey|PresharedKey)[[:blank:]]*="
_SHUNT_JSON_SECRET="\"kind\"[[:blank:]]*:[[:blank:]]*\"Secret\""
shunt_secret_marker() {
  local head
  head=$(head -c 65536 -- "$1" 2>/dev/null | tr -d '\000') || return 1
  case "$head" in
    *"PRIVATE KEY-----"* | *"-----BEGIN PGP PRIVATE KEY BLOCK-----"* | *"AGE-SECRET-KEY-1"* | *"ENC[AES256_GCM,"* | \
    *"LS0tLS1CRUdJTi"* | *ghp_* | *github_pat_* | *sk-ant-* | *access-tokens*) return 0 ;;
  esac
  case "$head" in *"sops:"*"ENC["* | *"ENC["*"sops:"*) return 0 ;; esac
  [[ "$head" =~ $_SHUNT_SECRET_KIND || "$head" =~ $_SHUNT_JSON_SECRET || "$head" =~ $_SHUNT_WG_KEY ]] && return 0
  [[ "$head" =~ $_SHUNT_CONFIG_KIND && "$head" =~ $_SHUNT_TOKEN_LINE ]] && return 0
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
  n=$(wc -l 2>/dev/null < "$1") || return 1   # 2> first: a failed < must stay silent
  if [ -s "$1" ] && [ "$(tail -c 1 -- "$1" | wc -l)" -eq 0 ]; then n=$((n + 1)); fi
  echo "$n"
}

shunt_count_bytes() { wc -c 2>/dev/null < "$1"; }

shunt_script_path() { printf '%s/scripts/bulk-read.sh\n' "$(cd "$1/.." && pwd)"; }

# Shared hook tail (needs lib/log.sh and lib/state.sh). Callers set SHUNT_HOOK,
# START_MS, T, LINES, BYTES, RETURNED and TOKENS.
shunt_done() { # shunt_done <result> [exit]: log the decision and exit
  log_hook "$SHUNT_HOOK" "$1" "$(( ($(date +%s%N) / 1000000) - START_MS ))" \
    "{\"lines\":$LINES,\"bytes\":$BYTES,\"returned\":$RETURNED,\"tokens\":$TOKENS,\"threshold\":$T}" 2>/dev/null || true
  exit "${2:-0}"
}

# shunt_redirect <hooks_dir> <file> <resolved> <first line>: deny the first large read
# of a file per session; any later read of the same resolved file, by Read or
# Bash in any shape, is allowed (one state file shared by both hooks).
shunt_redirect() {
  local cap fit
  seen_before shunt "$3"
  case $? in
    0) shunt_done bypass ;;
    1) ;;
    *) shunt_done nostate ;;
  esac
  cap=$(shunt_max_payload)
  fit=$(shunt_fit_lines "$BYTES" "$LINES" "$T")
  {
    printf '%s\n' "$4"
    if [ "$BYTES" -gt "$cap" ]; then
      printf 'It is over the bulk-read payload cap (%s bytes), so do not delegate it: use Grep for what you need, or Read a range.\n' "$cap"
    else
      printf 'To explore or summarise it, run this via Bash instead (see the bulk-reader skill):\n'
      printf '  %s --question "<what you need to know>" --paths %q\n' "$(shunt_script_path "$1")" "$2"
    fi
    if [ "$LINES" -ge 5 ] && [ "$fit" -ge 1 ]; then
      printf 'For exact content, Read at most %s lines at a time (offset/limit).\n' "$fit"
    fi
    printf 'If you will edit this file, Read the range you will change, or repeat this read.\n'
    printf 'Repeating a read of this file (in any form) will be allowed; allow_large is not needed.\n'
  } >&2
  shunt_done redirect 2
}
