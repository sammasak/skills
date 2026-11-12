#!/usr/bin/env bash
# Shared session state — read/write JSON file scoped to CLAUDE_SESSION_ID.
# Source this file from any hook: source "$(dirname "$0")/lib/state.sh"
#
# Schema v3: only fields a live hook writes (errors_seen, loop_count);
# upgrade_state() migrates older files.

STATE_SCHEMA_VERSION=3

init_state() {
  # Resolved here, not at source time: hooks learn the session id from stdin
  # (read_hook_input) after sourcing this file.
  STATE_FILE="${XDG_RUNTIME_DIR:-$HOME/.cache}/claude-hook-state-${CLAUDE_SESSION_ID:-$$}.json"
  find "${XDG_RUNTIME_DIR:-$HOME/.cache}" -maxdepth 1 -name 'claude-hook-state-*.json' -mtime +2 -delete 2>/dev/null || true
  if [ -f "$STATE_FILE" ]; then
    upgrade_state
    return
  fi
  cat > "$STATE_FILE" << STATEEOF
{
  "schema_version": ${STATE_SCHEMA_VERSION},
  "session_id": "${CLAUDE_SESSION_ID:-$$}",
  "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "errors_seen": 0,
  "loop_count": 0
}
STATEEOF
}

# Migrate v1 state files (missing schema_version) to current schema version.
upgrade_state() {
  local ver
  ver=$(jq -r '.schema_version // 1' "$STATE_FILE" 2>/dev/null || echo "1")
  if [ "$ver" -lt "$STATE_SCHEMA_VERSION" ] 2>/dev/null; then
    update_state ".schema_version = ${STATE_SCHEMA_VERSION}"
  fi
}

read_state() {
  jq -r "$1" "$STATE_FILE" 2>/dev/null
}

update_state() {
  local tmp
  tmp=$(mktemp)
  if jq "$1" "$STATE_FILE" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$STATE_FILE"
  else
    rm -f "$tmp"
  fi
}

inc_state() {
  update_state ".$1 = (.$1 // 0) + 1"
}

# seen_before <kind> <key>: 0 when <key> was already recorded this session,
# 1 after recording it now, 2 when no state can be kept (no session id, one
# that is not [A-Za-z0-9_-]+ and so could leave the state dir, or the file is
# not writable). Kept in its own append-only file, not the JSON above:
# PreToolUse hooks run in parallel, and check-loop's update_state would clobber
# a concurrent write to the shared state file.
seen_before() {
  local dir="${XDG_RUNTIME_DIR:-${HOME:+$HOME/.cache}}" file hash line
  [ -n "$dir" ] || return 2
  [ -n "${CLAUDE_SESSION_ID:-}" ] && [ "$CLAUDE_SESSION_ID" != "nosession" ] || return 2
  case "$CLAUDE_SESSION_ID" in *[!A-Za-z0-9_-]*) return 2 ;; esac
  file="$dir/claude-$1-${CLAUDE_SESSION_ID}.seen"
  mkdir -p "$dir" 2>/dev/null || return 2
  find "$dir" -maxdepth 1 -name "claude-$1-*.seen" -mtime +2 -delete 2>/dev/null || true
  hash=$(printf '%s' "$2" | sha256sum | cut -c1-32) || return 2
  [ -n "$hash" ] || return 2
  if [ -f "$file" ]; then
    while IFS= read -r line; do
      if [ "$line" = "$hash" ]; then return 0; fi
    done 2>/dev/null < "$file" || return 2
  fi
  printf '%s\n' "$hash" 2>/dev/null >> "$file" || return 2   # 2> first: a failed >> must stay silent
  return 1
}
