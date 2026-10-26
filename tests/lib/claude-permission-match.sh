#!/usr/bin/env bash
# Reimplements the documented Claude Code permission-rule semantics for tests:
# deny > ask > allow; `Bash(x:*)` == `x` or `x *`; `*` is a glob; compound
# commands need every part allowed, and any part (incl. $(...)) can deny/ask.
# Source it, then: permission_decision <permissions.json> <tool> [command]
# prints deny|ask|allow|none.

_rule_matches() { # <rule> <tool> <command>
  local rule="$1" tool="$2" cmd="$3" inner base
  if [[ "$rule" != *"("* ]]; then [[ "$rule" == "$tool" ]]; return; fi
  [[ "${rule%%(*}" == "$tool" ]] || return 1
  inner="${rule#*(}"; inner="${inner%)}"
  if [[ "$inner" == *":*" ]]; then
    base="${inner%:\*}"
    [[ "$cmd" == "$base" || "$cmd" == "$base "* ]]; return
  fi
  # shellcheck disable=SC2053
  [[ "$cmd" == $inner ]]
}

_strip_wrappers() { # drop documented leading wrappers from one subcommand
  local c="$1"
  c="${c#"${c%%[![:space:]]*}"}"; c="${c%"${c##*[![:space:]]}"}"
  while :; do
    case "$c" in
      "timeout "*) c="${c#timeout }"; c="${c#* }" ;;
      "time "*|"nice "*|"nohup "*|"command "*|"builtin "*|"stdbuf "*) c="${c#* }" ;;
      *) break ;;
    esac
  done
  printf '%s' "$c"
}

_split_parts() { # compound separators -> one part per line, plus every $(...) and `...` body
  local cmd="$1" rest
  printf '%s\n' "$cmd" | sed -E 's/\|\||&&|;|\|&|\||&/\n/g'
  rest="$cmd"
  while grep -qE '\$\([^()]*\)' <<<"$rest"; do
    grep -oE '\$\([^()]*\)' <<<"$rest" | sed -E 's/^\$\((.*)\)$/\1/'
    rest=$(sed -E 's/\$\([^()]*\)/_/g' <<<"$rest")
  done
  grep -oE '`[^`]*`' <<<"$cmd" | tr -d '`' || true
}

_unallowable() { # substitutions, process substitution and redirections never auto-allow
  [[ "$1" == *'`'* || "$1" == *'$('* || "$1" == *'<('* || "$1" == *'>('* || "$1" == *'>'* || "$1" == *'<'* ]]
}

permission_decision() { # <permissions.json> <tool> [command]
  local file="$1" tool="$2" cmd="${3:-}" list rule part decided
  for list in deny ask; do
    while IFS= read -r rule; do
      [ -n "$rule" ] || continue
      while IFS= read -r part; do
        part="$(_strip_wrappers "$part")"; [ -n "$part" ] || continue
        if _rule_matches "$rule" "$tool" "$part"; then echo "$list"; return 0; fi
      done < <(_split_parts "$cmd")
      [ -n "$cmd" ] || { _rule_matches "$rule" "$tool" "" && { echo "$list"; return 0; }; }
    done < <(jq -r ".${list}[]?" "$file")
  done
  if [ -z "$cmd" ]; then
    while IFS= read -r rule; do _rule_matches "$rule" "$tool" "" && { echo allow; return 0; }; done < <(jq -r '.allow[]?' "$file")
    echo none; return 0
  fi
  [[ "$cmd" =~ (\&\&|\|\||;|\|\&|\||\&)[[:space:]]*$ ]] && { echo none; return 0; }
  _unallowable "$cmd" && { echo none; return 0; }
  while IFS= read -r part; do
    part="$(_strip_wrappers "$part")"; [ -n "$part" ] || continue
    decided=0
    while IFS= read -r rule; do
      _rule_matches "$rule" "$tool" "$part" && { decided=1; break; }
    done < <(jq -r '.allow[]?' "$file")
    [ "$decided" -eq 1 ] || { echo none; return 0; }
  done < <(printf '%s\n' "$cmd" | sed -E 's/\|\||&&|;|\|&|\||&/\n/g')
  echo allow
}
