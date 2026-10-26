#!/usr/bin/env bash
# LIVE (costs tokens; not part of skills:test): the same quality-role request through Claude Code and
# Codex against one fixture checkout, then a field-by-field comparison of what each harness reported.
# Both runs use a temp copy of this checkout with devenv.local.nix pointing the tasks at the fake devenv.
# Run: bash agents/quality/tests/two-harness.sh [out-dir]
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT="${1:-$(mktemp -d)}"; mkdir -p "$OUT"
FX="$ROOT/task-modules/fixtures"
CK="$OUT/checkout"; REPO="$OUT/repo"
rm -rf "$CK" "$REPO"; mkdir -p "$CK"
git -C "$ROOT" archive --format=tar HEAD | tar -x -C "$CK"
git init -q "$REPO" && (cd "$REPO" && git config user.email t@t && git config user.name t && echo a > a && printf '.devenv/\n' > .gitignore && git add a .gitignore && git commit -qm init && mkdir -p .devenv/state/sdlc && printf '{"wrapper":"sdlc:test-rust-test","stage":"test","guard":"rust:test","at":"2026-10-26T10:00:00Z","tail":"test result: FAILED. 1 failed","fingerprint":"fp1"}' > .devenv/state/sdlc/last-red-test-rust-test.json)
printf '{"schema_version":1,"hosts":[{"name":"local","ssh":null}],"repos":[{"name":"repo","gh":null,"checkout":"%s"}]}' "$REPO" > "$OUT/fleet.json"
cat > "$CK/devenv.local.nix" <<NIX
{ ... }: { coordinator.fleetFile = $OUT/fleet.json; coordinator.devenvCommand = "$FX/bin/devenv"; coordinator.timeoutSeconds = 10; }
NIX
mkdir -p "$CK/.claude/agents" "$CK/.claude/skills"
ln -sfn ../../agents/quality.md "$CK/.claude/agents/quality.md"
for sk in sdlc-pipeline rust-engineering orchestrated-review; do ln -sfn "../../skills/$sk" "$CK/.claude/skills/$sk"; done
export COORDINATOR_CHECKOUT="$CK" FAKE_SDLC_DIR="$FX/sdlc" FAKE_LOG="$OUT/fake-calls.log"
[ -x "$HOME/.claude/hooks/validate-quality.sh" ] || ln -sfn "$ROOT/hooks/validate-quality.sh" "$HOME/.claude/hooks/validate-quality.sh"
ASK="Report the SDLC quality state of the checkout $REPO. Run exactly one command: devenv tasks run quality:report --input-json '{\"checkout\":\"$REPO\"}' --show-output. Then answer from its JSON with exactly one line per stage in the form 'STAGE <name>: <state>' followed by one line 'HEAD <sha>' and one line 'ALL_FRESH <true|false>'. Do not run any gate and do not run anything else."
# Claude honours a PreToolUse allow only from settings-level hooks in this mode (an agent-frontmatter hook alone
# left every Bash call at the permission prompt in a live run), so the guard is registered the way the launcher does it.
jq -n --arg g "$ROOT/hooks/validate-quality.sh" '{permissions:{allow:[],deny:["Edit","Write","NotebookEdit"]}, hooks:{PreToolUse:[{matcher:"Bash",hooks:[{type:"command",command:$g,timeout:10}]}]}}' > "$OUT/claude-settings.json"

echo "== claude"; : > "$FAKE_LOG"
( cd "$CK" && CLAUDE_CODE_OAUTH_TOKEN="${CLAUDE_CODE_OAUTH_TOKEN:-$(cat /run/secrets/claude_oauth_token 2>/dev/null)}" timeout 600 claude -p --agent quality --permission-mode default --setting-sources project,local --settings "$OUT/claude-settings.json" --output-format json --max-turns 10 "$ASK" > "$OUT/claude.json" 2> "$OUT/claude.err" ); echo "claude exit=$?"
jq -r '.result' "$OUT/claude.json" > "$OUT/claude.txt" 2>/dev/null; cp "$FAKE_LOG" "$OUT/claude-fake-calls.log"
sid=$(jq -r .session_id "$OUT/claude.json" 2>/dev/null); f=$(ls ~/.claude/projects/*/"$sid".jsonl 2>/dev/null | head -1)
[ -n "$f" ] && jq -r 'select(.type=="assistant") | .message.content[]? | select(.type=="tool_use") | "\(.name): \(.input.command // .input.file_path // "")"' "$f" > "$OUT/claude-tools.txt"
jq -c '{num_turns, total_cost_usd, is_error, denials: (.permission_denials|length), model: (.modelUsage|keys)}' "$OUT/claude.json" 2>/dev/null

echo "== codex"; : > "$FAKE_LOG"
if ! codex login status 2>/dev/null | grep -qi 'logged in'; then echo "codex: not logged in on this host (owner gate: OpenAI credentials); skipping the Codex run" | tee "$OUT/codex.txt"; else
( cd "$CK" && timeout 600 codex exec --cd "$CK" --sandbox workspace-write --skip-git-repo-check -c model_reasoning_effort=low --color never "$(cat agents/quality/AGENTS.md)"$'\n\n'"$ASK" > "$OUT/codex.txt" 2> "$OUT/codex.err" ); echo "codex exit=$?"; fi
cp "$FAKE_LOG" "$OUT/codex-fake-calls.log"

echo "== compare"
extract() { grep -oE '^(STAGE [a-z]+: [a-z]+|HEAD [0-9a-f]+|ALL_FRESH (true|false))' "$1" | sort -u; }
extract "$OUT/claude.txt" > "$OUT/claude.fields"; extract "$OUT/codex.txt" > "$OUT/codex.fields"
echo "claude fields: $(wc -l < "$OUT/claude.fields")  codex fields: $(wc -l < "$OUT/codex.fields")"
if diff -u "$OUT/claude.fields" "$OUT/codex.fields" > "$OUT/fields.diff"; then echo "IDENTICAL reported fields"; else echo "DIFFER:"; cat "$OUT/fields.diff"; fi
echo "claude task calls: $(grep -c 'sdlc-status' "$OUT/claude-fake-calls.log")  codex task calls: $(grep -c 'sdlc-status' "$OUT/codex-fake-calls.log")"
echo "gates run (must be 0): claude $(grep -c 'tasks run sdlc:' "$OUT/claude-fake-calls.log") codex $(grep -c 'tasks run sdlc:' "$OUT/codex-fake-calls.log")"
echo "artefacts in $OUT"
