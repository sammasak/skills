#!/usr/bin/env bash
# The one shell file the roles keep: Claude Code hooks must be a command, and this runs on EVERY Bash call of
# every agent, so the no-op path must not start anything heavy. Settings-level PreToolUse(Bash): a subagent's own
# frontmatter hooks never run (verified 2026-10-27), but this hook does and its input names the agent (agent_type;
# ROLE_GUARD_AGENT covers the main-session `claude --agent <role>` case). For a role shipped next to this file
# (agents/<role>/ROLE.md) the decision comes from the guard library (task-modules/guard-lib.nix): preferably the
# store-built binary nixos-config installs (ROLE_GUARD_BIN, fast, not writable by the agent), else
# `devenv tasks run guard:check` in the skills checkout under an inner timeout. Only exit 2 blocks in Claude Code,
# and a timed-out hook does NOT block, so every failure path, including the inner timeout, exits 2 in time.
set -uo pipefail
export LC_ALL=C
input=$(cat)
here=$(dirname "$(readlink -f "$0")")
if command -v jq >/dev/null 2>&1; then agent=$(jq -r '.agent_type // empty' <<<"$input" 2>/dev/null) || agent=""
else agent=$(grep -oE '"agent_type"[[:space:]]*:[[:space:]]*"[^"]*"' <<<"$input" | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/'); fi
checkout="${COORDINATOR_CHECKOUT:-${SKILLS_CHECKOUT:-${HOME:-/nonexistent}/claude-code-skills}}"
# a name is a role when its contract ships next to this file or sits in the checkout; whichever of agent_type and
# ROLE_GUARD_AGENT names a role wins, so a mismatch between the two can never un-guard a call
is_role() { [[ "$1" =~ ^[a-z][a-z-]*$ ]] && { [ -f "$here/../agents/$1/ROLE.md" ] || [ -f "$checkout/agents/$1/ROLE.md" ]; }; }
norm() { local a="${1##*:}"; printf '%s' "${a,,}"; }
agent=$(norm "$agent"); forced=$(norm "${ROLE_GUARD_AGENT:-}")
if ! is_role "$agent"; then
  if is_role "$forced"; then agent="$forced"; else
    [ -n "$agent" ] || agent="$forced"
    [[ "$agent" =~ ^[a-z][a-z-]*$ ]] || exit 0
  fi
fi
shipped=0; [ -f "$here/../agents/$agent/ROLE.md" ] && shipped=1
present=0; [ -f "$checkout/agents/$agent/ROLE.md" ] && present=1
if [ "$shipped" -eq 0 ] && [ "$present" -eq 0 ]; then
  if [ -f "$here/../agents/$agent.md" ] && grep -qE "role-guard-dispatch\.sh|validate-(role|$agent)\.sh" "$here/../agents/$agent.md"; then
    echo "$agent: adapter declares a role guard but ships no agents/$agent/ROLE.md; refusing" >&2; exit 2
  fi
  exit 0
fi
[ "$present" -eq 1 ] || { echo "$agent: the skills checkout $checkout has no agents/$agent/ROLE.md (missing or stale: git pull it, or set SKILLS_CHECKOUT); refusing" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "$agent: jq is required to run the role guard; refusing" >&2; exit 2; }
tmpd="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}"
df=$(mktemp -p "$tmpd" 2>/dev/null || mktemp) || { echo "$agent: cannot create a decision file; refusing" >&2; exit 2; }
errf=$(mktemp -p "$tmpd" 2>/dev/null || mktemp) || { rm -f "$df"; echo "$agent: cannot create a temp file; refusing" >&2; exit 2; }
trap 'rm -f "$df" "$errf"' EXIT
if [ -n "${ROLE_GUARD_BIN:-}" ] && [ -x "$ROLE_GUARD_BIN" ]; then
  # installed guard: the library built into the Nix store, so the checkout only supplies ROLE.md and .integrity
  printf '%s' "$input" | GUARD_ROLE="$agent" COORDINATOR_CHECKOUT="$checkout" timeout -k 1 "${ROLE_GUARD_TIMEOUT:-8}" "$ROLE_GUARD_BIN" > "$df" 2>"$errf"; rc=$?; how="guard binary"
else
  [ -f "$checkout/devenv.nix" ] || { echo "$agent: $checkout has no devenv.nix and no installed guard; refusing" >&2; exit 2; }
  payload=$(jq -cn --arg r "$agent" --argjson h "$input" --arg f "$df" '{role:$r, hook:$h, decision_file:$f}' 2>/dev/null) || { echo "$agent: hook input is not JSON; refusing" >&2; exit 2; }
  ( cd "$checkout" && COORDINATOR_CHECKOUT="$checkout" timeout -k 1 "${ROLE_GUARD_TIMEOUT:-12}" devenv tasks run guard:check --input-json "$payload" ) >/dev/null 2>"$errf"; rc=$?; how="devenv guard:check"
fi
[ "$rc" -ne 124 ] || { echo "$agent: $how timed out; refusing" >&2; exit 2; }
dec=$(jq -r '.decision // empty' "$df" 2>/dev/null); reason=$(jq -r '.reason // ""' "$df" 2>/dev/null)
[ -n "$reason" ] || reason="$agent: guard refused"
case "$dec" in
  allow|ask) jq -cn --arg d "$dec" --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:$d, permissionDecisionReason:$r}}'; exit 0 ;;
  block) echo "$reason" >&2; exit 2 ;;   # the guard already names the role
  *) echo "$agent: guard did not decide ($how rc=$rc): $(tail -c 400 "$errf" | tr '\n' ' ')" >&2; exit 2 ;;
esac
