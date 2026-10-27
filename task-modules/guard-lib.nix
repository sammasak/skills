# The role guard as one shell library held in Nix (epic #16): role-list parser, integrity predicate, guard
# decision. Imported by task-modules/guard.nix for the guard:check / guard:integrity tasks and the test suites,
# and by nixos-config to build a store-resident guard binary that the dispatcher prefers over the checkout.
''
    # ---- role guard library: role-list parser, integrity predicate, guard decision (shared by guard:check,
    # guard:integrity and the test suites; the dispatcher hook calls guard:check)
    ROLE_LIST_AWK=$(cat <<'AWK'
    BEGIN { fm = 0; intasks = 0; cur = ""; seen_tasks = 0; closed = 0 }
    /\r$/ { print "role-list: CRLF line ending" > "/dev/stderr"; exit 3 }
    NR == 1 && !/^---$/ { print "role-list: frontmatter must start on line 1" > "/dev/stderr"; exit 3 }
    /^---$/ { fm++; if (fm == 2) { exit } ; next }
    /^[ \t]*#/ { next }
    fm != 1 { next }
    /^tasks:[ \t]*$/ { if (seen_tasks) { print "role-list: duplicate tasks: key" > "/dev/stderr"; exit 3 }; seen_tasks = 1; intasks = 1; cur = ""; next }
    intasks && /^[^ \t]/ { intasks = 0; cur = "" }
    !intasks { next }
    /^  (read|run|act|inputless):[ \t]*(\[\])?[ \t]*$/ { cur = $1; sub(":", "", cur); if (seen[cur]++) { print "role-list: duplicate sub-key " cur > "/dev/stderr"; exit 3 }; closed = ($0 ~ /\[\]/); next }
    closed && /^    - / { print "role-list: items after an inline [] list" > "/dev/stderr"; exit 3 }
    /^  [A-Za-z_"'][^:]*:/ { print "role-list: unknown key under tasks: " $0 > "/dev/stderr"; exit 3 }
    /^    - / {
      if (cur == "") { print "role-list: list item outside a known sub-key" > "/dev/stderr"; exit 3 }
      name = $0; sub(/^    - /, "", name); sub(/[ \t]+$/, "", name)
      if (name !~ /^[a-z0-9_-]+(:[a-z0-9_-]+)+$/) { print "role-list: bad task name: " name > "/dev/stderr"; exit 3 }
      if (cur == key) print name
      next
    }
    /^[ \t]*$/ { next }
    { print "role-list: unexpected line under tasks: " $0 > "/dev/stderr"; exit 3 }
    END { if (fm < 2) { print "role-list: frontmatter not closed" > "/dev/stderr"; exit 3 } }
    AWK
    )
    # role_list_awk <key> <ROLE.md>: one task per line for read|run|act|inputless; exit 3 on anything not understood
    role_list_awk() { awk -v key="$1" "$ROLE_LIST_AWK" "$2"; }
    # integrity_check <dir> <pin|-> [role...]: 0 intact; 1 refused with the reason on stderr; 2 bad call
    integrity_check() (
      [ $# -ge 2 ] && [ -n "''${1:-}" ] || { echo "usage: integrity_check <dir> <pin|-> [role...]" >&2; exit 2; }
      dir="$1"; pin="$2"; shift 2
      # an empty or malformed pin is a caller bug, never "no pin": only the literal - skips the pin comparison
      [ "$pin" = - ] || [[ "$pin" =~ ^[0-9a-f]{64}$ ]] || { echo "pin must be 64 hex characters or -" >&2; exit 2; }
      [ -f "$dir/.integrity" ] || { echo "no .integrity manifest in $dir" >&2; exit 1; }
      # the manifest is read once into memory and every step uses that copy, so it cannot be swapped between the pin
      # check and the file check (no temp file: the agent may own $TMPDIR)
      m=$(cat "$dir/.integrity" && printf x) || { echo "cannot read .integrity" >&2; exit 1; }; m=''${m%x}
      if [ "$pin" != - ]; then
        [ "$(printf %s "$m" | sha256sum | cut -d' ' -f1)" = "$pin" ] || { echo ".integrity does not match the pinned hash" >&2; exit 1; }
      fi
      (cd "$dir" && printf %s "$m" | sha256sum --check --quiet --strict - >/dev/null 2>&1) || { echo "checkout integrity check failed (a listed file changed or is missing)" >&2; exit 1; }
      # pure bash match: a pipe into grep -q could SIGPIPE the writer under pipefail and fail closed for the wrong reason
      listed() { local re; re=$'(^|\n)[0-9a-f]{64}  (\\./)?'"''${1//./\\.}"$'($|\n)'; [[ "$m" =~ $re ]]; }
      for must in hooks/role-guard-dispatch.sh task-modules/guard.nix devenv.nix devenv.yaml devenv.lock; do
        listed "$must" || { echo ".integrity does not cover $must" >&2; exit 1; }
      done
      for role in "$@"; do
        # the predicate defends itself (the activation calls it directly): a role name is plain lowercase, never a pattern
        [[ "$role" =~ ^[a-z][a-z-]*$ ]] || { echo "role name '$role' is not a lowercase role name" >&2; exit 2; }
        listed "agents/$role/ROLE.md" || { echo ".integrity does not cover agents/$role/ROLE.md" >&2; exit 1; }
      done
      # files a harness reads as policy or that redirect evaluation: present means they must be manifest-listed
      for extra in devenv.local.nix devenv.local.yaml .claude/settings.json .claude/settings.local.json AGENTS.md AGENTS.override.md CLAUDE.md .mcp.json .codex/config.toml .codex/hooks.json; do
        [ -e "$dir/$extra" ] || continue
        listed "$extra" || { echo "$extra is present but not covered by .integrity" >&2; exit 1; }
      done
    )

    # _guard_inner <role> <hook-json>: the guard as it decides: allow/ask JSON on stdout, or reason on stderr + exit 2
    _guard_inner() (
      local ROLE input; ROLE="$1"; input="$2"
      [[ "$ROLE" =~ ^[a-z][a-z-]*$ ]] || { echo "guard: ROLE must be a lowercase role name" >&2; exit 2; }

      # the session cwd, the command and every working-directory field must be strings free of control characters
      # (a newline-only workdir would read as empty and skip the directory check; a trailing newline in cwd would
      # be stripped by $(...) and compare equal to the checkout)
      jq -e '[.cwd, .tool_input.command, .tool_input.workdir, .tool_input.cwd, .tool_input.working_directory, .tool_input.working_dir]
             | map(select(. != null)) | all(type == "string" and (explode | all(. >= 32 and . != 127)))' <<<"$input" >/dev/null 2>&1 \
        || { echo "$ROLE: control characters or unparseable input" >&2; exit 2; }
      cmd=$(jq -r '.tool_input.command // empty' <<<"$input" 2>/dev/null) || cmd=""
      cwd=$(jq -r '.cwd // empty' <<<"$input" 2>/dev/null) || cwd=""
      [ -n "$cmd" ] || { echo "$ROLE: empty Bash command" >&2; exit 2; }
      [ -n "$cwd" ] || { echo "$ROLE: hook input carries no cwd" >&2; exit 2; }

      COORDINATOR_CHECKOUT="''${COORDINATOR_CHECKOUT:-''${SKILLS_CHECKOUT:-''${HOME:-/nonexistent}/claude-code-skills}}"
      [[ "$COORDINATOR_CHECKOUT" =~ ^/[A-Za-z0-9_./-]+$ ]] && [[ "/$COORDINATOR_CHECKOUT/" != *"/../"* ]] || { echo "$ROLE: the skills checkout path must be absolute and plain ([A-Za-z0-9_./-], no ..): $COORDINATOR_CHECKOUT" >&2; exit 2; }
      want=$(readlink -e -- "$COORDINATOR_CHECKOUT" 2>/dev/null) || { echo "$ROLE: skills checkout $COORDINATOR_CHECKOUT does not exist (set SKILLS_CHECKOUT to a sammasak/skills checkout)" >&2; exit 2; }
      # a subagent inherits the parent session's cwd, so `cd <checkout> && <task call>` is the normal form. bash's cd moves
      # logically and expands ~+ ~- and -, so the target is checked as TEXT: absolute (or ~/), no . or .. segments, no
      # doubled slashes, and equal to the checkout path itself; `&&` is the only join accepted
      effective_dir="$cwd"
      if [[ "$cmd" =~ ^cd[[:space:]]+([^[:space:]]+)[[:space:]]+\&\&[[:space:]]+(.+)$ ]]; then
        cdpath="''${BASH_REMATCH[1]}"; rest="''${BASH_REMATCH[2]}"
        # shellcheck disable=SC2088  # a literal ~ from the agent's command is matched here, then expanded like bash would
        case "$cdpath" in "~") cdpath="''${HOME:-}" ;; "~/"*) cdpath="''${HOME:-}/''${cdpath#\~/}" ;; esac
        if [[ ! "$cdpath" =~ ^/[A-Za-z0-9_./-]*$ ]] || [[ "/$cdpath/" == *"/../"* || "/$cdpath/" == *"/./"* || "$cdpath" == *//* ]]; then
          echo "$ROLE: the cd target must be the skills checkout as a plain absolute path (got '$cdpath')" >&2; exit 2
        fi
        cdpath="''${cdpath%/}"
        if [ "$cdpath" != "''${COORDINATOR_CHECKOUT%/}" ] && [ "$cdpath" != "$want" ]; then
          echo "$ROLE: tasks run only from the skills checkout $COORDINATOR_CHECKOUT (cd target: $cdpath)" >&2; exit 2
        fi
        effective_dir="$cdpath"; cmd="$rest"
      fi
      if [ "$(readlink -e -- "$effective_dir" 2>/dev/null)" != "$want" ]; then
        echo "$ROLE: tasks run only from the skills checkout $COORDINATOR_CHECKOUT: run from it, or prefix the call with 'cd $COORDINATOR_CHECKOUT && ' (cwd: ''${cwd:-unknown})" >&2; exit 2
      fi
      # a harness may run one call from another directory (Codex's per-call workdir); a planted devenv.nix in a
      # subdirectory would then evaluate instead of the checkout's, so any such field must name the checkout too
      # every such field present is checked; a relative one resolves against the session cwd the harness reported
      while IFS= read -r wd; do
        [ -n "$wd" ] || continue
        if [ "$(cd -- "$cwd" 2>/dev/null && readlink -e -- "$wd" 2>/dev/null)" != "$want" ]; then
          echo "$ROLE: the call's working directory must be $COORDINATOR_CHECKOUT (workdir: $wd)" >&2; exit 2
        fi
      done < <(jq -r '.tool_input | (.workdir, .cwd, .working_directory, .working_dir) | select(. != null) | tostring' <<<"$input" 2>/dev/null)

      role_md="$want/agents/$ROLE/ROLE.md"
      [ -r "$role_md" ] || { echo "$ROLE: no role contract at $role_md" >&2; exit 2; }
      # An installed checkout carries .integrity (sha256 of the roots in hooks/lib/integrity-paths). A managed session
      # (the launcher sets COORDINATOR_REQUIRE_INTEGRITY=1 and pins the manifest's own hash in COORDINATOR_INTEGRITY_SHA256,
      # kept outside the checkout) needs both: a missing manifest, a missing pin, a rewritten manifest, a changed listed
      # file, or an unlisted policy file (devenv.local.*, .claude/settings*.json, AGENTS*.md, CLAUDE.md, .mcp.json,
      # .codex/*) all block every call. Without the launcher a present
      # manifest is still checked. The predicate lives in lib/integrity_check, shared with the nixos-config activation.
      if { [ -n "''${COORDINATOR_REQUIRE_INTEGRITY:-}" ] && [ "''${COORDINATOR_REQUIRE_INTEGRITY}" != 0 ]; } || [ -n "''${COORDINATOR_INTEGRITY_SHA256:-}" ]; then
        [ -f "$want/.integrity" ] || { echo "$ROLE: no .integrity manifest in $want; refusing (managed session)" >&2; exit 2; }
        [[ "''${COORDINATOR_INTEGRITY_SHA256:-}" =~ ^[0-9a-f]{64}$ ]] || { echo "$ROLE: managed session without a valid integrity pin; refusing" >&2; exit 2; }
      fi
      if [ -f "$want/.integrity" ]; then
        msg=$(integrity_check "$want" "''${COORDINATOR_INTEGRITY_SHA256:--}" "$ROLE" 2>&1) || { echo "$ROLE: $msg; refusing" >&2; exit 2; }
      fi

      role_list() { local out; out=$(role_list_awk "$1" "$role_md") || return 3; paste -sd'|' - <<<"$out"; }
      READ=$(role_list read) || { echo "$ROLE: role contract rejected by the guard parser" >&2; exit 2; }
      RUN=$(role_list run) || { echo "$ROLE: role contract rejected by the guard parser" >&2; exit 2; }
      ACT=$(role_list act) || { echo "$ROLE: role contract rejected by the guard parser" >&2; exit 2; }
      allow_re="''${READ}''${RUN:+''${READ:+|}$RUN}"
      [ -n "$allow_re" ] || { echo "$ROLE: role contract lists no tasks" >&2; exit 2; }

      re="^devenv tasks run (''${allow_re}''${ACT:+|$ACT})( --input-json '([^']*)')?( --show-output)?\$"
      if [[ ! "$cmd" =~ $re ]]; then
        echo "$ROLE: only '[cd <checkout> && ]devenv tasks run <allowed task> [--input-json '<json>'] [--show-output]' is permitted" >&2; exit 2
      fi
      # The anchored regex leaves no room for metacharacters outside the quoted body.
      task="''${BASH_REMATCH[1]}"; input_arg="''${BASH_REMATCH[2]:-}"; body="''${BASH_REMATCH[3]:-}"
      if [ -n "$input_arg" ] && ! jq -se 'length == 1 and (.[0] | type == "object")' <<<"$body" >/dev/null 2>&1; then
        echo "$ROLE: --input-json must be exactly one JSON object literal" >&2; exit 2
      fi

      decision=allow; [ -n "$ACT" ] && [[ "$task" =~ ^(''${ACT})$ ]] && decision=ask
      jq -cn --arg d "$decision" --arg t "$task" --arg r "$ROLE" \
        '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d,permissionDecisionReason:($r + " task " + $t + " (" + $d + ")")}}'
    )

    # guard_check <role> <hook-json>: always exits 0 and prints {decision: allow|ask|block, reason}; a crash is a block
    guard_check() {
      local role="$1" input="$2" out err rc reason dec
      err=$(mktemp) || { printf '%s\n' '{"decision":"block","reason":"guard could not create a temp file"}'; return 0; }
      # errexit-safe capture: the store-built binary runs with set -e, and a block is an exit 2 from the inner function
      rc=0; out=$(_guard_inner "$role" "$input" 2>"$err") || rc=$?
      reason=$(tr '\n' ' ' <"$err" | sed -E 's/ +$//'); rm -f "$err"
      if [ "$rc" -eq 0 ]; then
        dec=$(jq -r '.hookSpecificOutput.permissionDecision // empty' <<<"$out" 2>/dev/null) || dec=""
        case "$dec" in allow|ask) jq -cn --arg d "$dec" --arg r "$(jq -r '.hookSpecificOutput.permissionDecisionReason // ""' <<<"$out")" '{decision:$d, reason:$r}'; return 0 ;; esac
        reason="guard returned no decision"; rc=1
      fi
      [ "$rc" -eq 2 ] || reason="guard failed (rc=$rc) $reason"
      jq -cn --arg r "$reason" '{decision:"block", reason:$r}'
    }
    # guard_main: the whole guard as one program (a store-built binary when nixos-config installs it): hook JSON on
    # stdin, GUARD_ROLE in the environment, {decision, reason} on stdout, always exit 0
    guard_main() {
      local input; input=$(cat)
      [ -n "''${GUARD_ROLE:-}" ] || { printf '%s\n' '{"decision":"block","reason":"guard_main: GUARD_ROLE is not set"}'; return 0; }
      guard_check "$GUARD_ROLE" "$input"
    }
''
