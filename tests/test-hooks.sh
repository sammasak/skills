#!/usr/bin/env bash
# Hook test suite — exercises the real Claude Code hook contract:
# one JSON object on stdin; feedback via exit 2 (+stderr) or stdout JSON.
# Run: bash tests/test-hooks.sh   (also wired as the repo pre-push gate)

set -uo pipefail

# Tests exercise the WORKTREE hooks (../hooks), not the deployed nix store copy.
# "suite green" proves the store only together with the separate pin==HEAD==store
# byte-diff the deploy flow runs; this suite does not read the store.
HOOKS="$(cd "$(dirname "$0")/../hooks" && pwd)"
TMP=$(mktemp -d)
# State/loop files land under the SAME fallback the hooks use ($HOME/.cache),
# not /tmp — clean both so bare-env runs leave nothing behind.
STATE_DIR="${XDG_RUNTIME_DIR:-$HOME/.cache}"
trap 'rm -rf "$TMP"; rm -f "$STATE_DIR"/claude-hook-state-hooktest-*.json "$STATE_DIR"/claude-loop-hooktest-*.log' EXIT

PASS=0
FAIL=0

# check <name> <want_exit> <stderr_pattern|-> <stdout_pattern|-> <hook> <stdin_json>
check() {
  local name="$1" want_exit="$2" err_pat="$3" out_pat="$4" hook="$5" json="$6"
  local out err code
  out=$(printf '%s' "$json" | "$HOOKS/$hook" 2>"$TMP/err"); code=$?
  err=$(cat "$TMP/err")
  local ok=1
  [ "$code" -eq "$want_exit" ] || ok=0
  if [ "$err_pat" != "-" ]; then echo "$err" | grep -q "$err_pat" || ok=0; fi
  if [ "$out_pat" != "-" ]; then echo "$out" | grep -q "$out_pat" || ok=0; fi
  if [ "$ok" -eq 1 ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $name (exit=$code want=$want_exit; stderr='$err' stdout='$out')"
  fi
}

j() { printf '{"session_id":"hooktest-%s","tool_input":%s}' "$1" "$2"; }

# ── validate-bash (PreToolUse: minimal speed-bump — 4 guards) ──
# 1. force push
check "force push blocked" 2 "BLOCKED: force push" - \
  validate-bash.sh "$(j b1 '{"command":"git push --force origin main"}')"
check "short -f force blocked" 2 "BLOCKED: force push" - \
  validate-bash.sh "$(j b1 '{"command":"git push -f origin main"}')"
check "plus-refspec force blocked" 2 "BLOCKED: force push" - \
  validate-bash.sh "$(j b1 '{"command":"git push origin +main"}')"
check "git -C force blocked" 2 "BLOCKED: force push" - \
  validate-bash.sh "$(j b1 '{"command":"git -C /x push --force"}')"
check "force-with-lease allowed (ancestry guard owns it)" 0 - - \
  validate-bash.sh "$(j b1 '{"command":"git push --force-with-lease origin main"}')"
check "plain push allowed" 0 - - \
  validate-bash.sh "$(j b1 '{"command":"git push origin main"}')"
check "branch suffix force not misblocked" 0 - - \
  validate-bash.sh "$(j b1 '{"command":"git push origin feature--force"}')"
check "force-push mention in echo allowed" 0 - - \
  validate-bash.sh "$(j b1 '{"command":"echo 'git push --force' > note.txt"}')"
check "force-push in commit message allowed" 0 - - \
  validate-bash.sh "$(j b1 '{"command":"git commit -m \"disallow git push -f in hooks\""}')"
check "compound push-then-rm-f allowed" 0 - - \
  validate-bash.sh "$(j b1 '{"command":"git push origin main && rm -f /tmp/x"}')"
# 2. recursive rm of root/home
check "rm -rf slash blocked" 2 "BLOCKED: recursive rm" - \
  validate-bash.sh "$(j b1 '{"command":"rm -rf /"}')"
check "rm -rf root glob blocked" 2 "BLOCKED: recursive rm" - \
  validate-bash.sh "$(j b1 '{"command":"rm -rf /*"}')"
check "rm -rf tilde blocked" 2 "BLOCKED: recursive rm" - \
  validate-bash.sh "$(j b1 '{"command":"rm -rf ~"}')"
check "rm -rf HOME blocked" 2 "BLOCKED: recursive rm" - \
  validate-bash.sh "$(j b1 '{"command":"rm -rf $HOME"}')"
check "rm -rf whole home blocked" 2 "BLOCKED: recursive rm" - \
  validate-bash.sh "$(j b1 '{"command":"rm -fr /home/lukas"}')"
check "rm -rf etc blocked" 2 "BLOCKED: recursive rm" - \
  validate-bash.sh "$(j b1 '{"command":"rm -rf /etc"}')"
check "sudo rm -rf slash blocked" 2 "BLOCKED: recursive rm" - \
  validate-bash.sh "$(j b1 '{"command":"sudo rm -rf /"}')"
check "rm -rf project dir allowed" 0 - - \
  validate-bash.sh "$(j b1 '{"command":"rm -rf ./target"}')"
check "rm -rf deep path allowed" 0 - - \
  validate-bash.sh "$(j b1 '{"command":"rm -rf /home/lukas/tmp/build"}')"
check "rm -f non-recursive allowed" 0 - - \
  validate-bash.sh "$(j b1 '{"command":"rm -f /tmp/x.lock"}')"
check "rm -rf quoted-var glob allowed" 0 - - \
  validate-bash.sh "$(j b1 '{"command":"rm -rf \"$TMP\"/*"}')"
check "rm -rf quoted-var trailing-slash allowed" 0 - - \
  validate-bash.sh "$(j b1 '{"command":"rm -rf \"$out\"/"}')"
check "rm mention in echo allowed" 0 - - \
  validate-bash.sh "$(j b1 '{"command":"echo 'never rm -rf /' >> doc.md"}')"
# 3. destructive kubectl delete
check "kubectl delete pvc blocked" 2 "BLOCKED: destructive kubectl" - \
  validate-bash.sh "$(j b1 '{"command":"kubectl -n herman delete pvc data-0"}')"
check "kubectl delete namespace blocked" 2 "BLOCKED: destructive kubectl" - \
  validate-bash.sh "$(j b1 '{"command":"kubectl delete namespace staging"}')"
check "kubectl delete pv blocked" 2 "BLOCKED: destructive kubectl" - \
  validate-bash.sh "$(j b1 '{"command":"kubectl delete pv data-volume-7"}')"
check "kubectl delete pod allowed" 0 - - \
  validate-bash.sh "$(j b1 '{"command":"kubectl delete pod crashed-xyz -n app"}')"
check "kubectl get pvc allowed" 0 - - \
  validate-bash.sh "$(j b1 '{"command":"kubectl get pvc -A"}')"
check "kubectl delete mention in echo allowed" 0 - - \
  validate-bash.sh "$(j b1 '{"command":"echo 'kubectl delete pvc x' >> runbook.md"}')"
# 3a. a plain server/client dry run of it deletes nothing and is allowed
check "server dry-run delete pvc allowed" 0 - - \
  validate-bash.sh "$(j b1 '{"command":"kubectl -n herman delete pvc data-0 --dry-run=server"}')"
check "client dry-run delete namespace allowed" 0 - - \
  validate-bash.sh "$(j b1 '{"command":"kubectl delete namespace staging --dry-run=client"}')"
check "dry-run flag before the kind allowed" 0 - - \
  validate-bash.sh "$(j b1 '{"command":"kubectl delete --dry-run=server pv data-volume-7"}')"
check "impersonated server dry-run allowed" 0 - - \
  validate-bash.sh "$(j b1 '{"command":"kubectl delete pvc data-0 -n herman --as=system:serviceaccount:flux-system:kustomize-controller --dry-run=server"}')"
check "dry-run with 2>&1 and pipe allowed" 0 - - \
  validate-bash.sh "$(j b1 '{"command":"kubectl delete ns staging --dry-run=server -o name 2>&1 | tail -5"}')"
check "two dry-run segments allowed" 0 - - \
  validate-bash.sh "$(j b1 '{"command":"kubectl delete pvc a -n x --dry-run=server; kubectl delete ns x --dry-run=server"}')"
check "dry-run delete next to get pvc allowed" 0 - - \
  validate-bash.sh "$(j b1 '{"command":"kubectl delete pod a; kubectl get pvc -A && kubectl delete pvc y --dry-run=server"}')"
check "dry-run on a later line allowed" 0 - - \
  validate-bash.sh "$(j b1 '{"command":"kubectl get ns\nkubectl delete ns x --dry-run=server"}')"
# 3b. anything else stays blocked (fail closed)
check "block message names the dry-run allowance" 2 "dry-run=server or --dry-run=client run of it is allowed" - \
  validate-bash.sh "$(j b1 '{"command":"kubectl delete pvc data-0"}')"
check "bare --dry-run blocked" 2 "BLOCKED: destructive kubectl" - \
  validate-bash.sh "$(j b1 '{"command":"kubectl delete pvc data-0 --dry-run"}')"
check "--dry-run=none blocked" 2 "BLOCKED: destructive kubectl" - \
  validate-bash.sh "$(j b1 '{"command":"kubectl delete pvc data-0 --dry-run=none"}')"
check "--dry-run without = blocked" 2 "BLOCKED: destructive kubectl" - \
  validate-bash.sh "$(j b1 '{"command":"kubectl delete pvc data-0 --dry-run server"}')"
check "--dry-run=true blocked" 2 "BLOCKED: destructive kubectl" - \
  validate-bash.sh "$(j b1 '{"command":"kubectl delete pvc data-0 --dry-run=true"}')"
check "--dry-run=servers blocked" 2 "BLOCKED: destructive kubectl" - \
  validate-bash.sh "$(j b1 '{"command":"kubectl delete pvc data-0 --dry-run=servers"}')"
check "uppercase dry-run flag blocked" 2 "BLOCKED: destructive kubectl" - \
  validate-bash.sh "$(j b1 '{"command":"kubectl delete pvc data-0 --DRY-RUN=server"}')"
check "--dry-run variable blocked" 2 "BLOCKED: destructive kubectl" - \
  validate-bash.sh "$(j b1 '{"command":"kubectl delete pvc data-0 --dry-run=$MODE"}')"
check "variable elsewhere in dry-run segment blocked" 2 "BLOCKED: destructive kubectl" - \
  validate-bash.sh "$(j b1 '{"command":"kubectl delete pvc data-0 --dry-run=server $EXTRA"}')"
check "later --dry-run=none override blocked" 2 "BLOCKED: destructive kubectl" - \
  validate-bash.sh "$(j b1 '{"command":"kubectl delete pvc data-0 --dry-run=server --dry-run=none"}')"
check "repeated dry-run flag blocked" 2 "BLOCKED: destructive kubectl" - \
  validate-bash.sh "$(j b1 '{"command":"kubectl delete pvc data-0 --dry-run=server --dry-run=client"}')"
check "quoted override flag blocked" 2 "BLOCKED: destructive kubectl" - \
  validate-bash.sh "$(j b1 '{"command":"kubectl delete pvc data-0 --dry-run=server \"--dry-run=none\""}')"
check "quoted dry-run value blocked" 2 "BLOCKED: destructive kubectl" - \
  validate-bash.sh "$(j b1 '{"command":"kubectl delete pvc data-0 --dry-run=\"server\""}')"
check "dry-run then real delete blocked" 2 "BLOCKED: destructive kubectl" - \
  validate-bash.sh "$(j b1 '{"command":"kubectl delete pvc x --dry-run=server; kubectl delete pvc x"}')"
check "real delete then dry-run blocked" 2 "BLOCKED: destructive kubectl" - \
  validate-bash.sh "$(j b1 '{"command":"kubectl delete pvc x && kubectl delete pvc x --dry-run=server"}')"
check "flag-before-verb real delete after dry-run blocked" 2 "BLOCKED: destructive kubectl" - \
  validate-bash.sh "$(j b1 '{"command":"kubectl delete ns x --dry-run=client | cat; kubectl -n ns delete pvc x"}')"
check "dry-run flag only in echo segment blocked" 2 "BLOCKED: destructive kubectl" - \
  validate-bash.sh "$(j b1 '{"command":"echo --dry-run=server; kubectl delete pvc x"}')"
check "dry-run flag only in comment blocked" 2 "BLOCKED: destructive kubectl" - \
  validate-bash.sh "$(j b1 '{"command":"kubectl delete pvc x # --dry-run=server"}')"
check "dry-run flag on next line blocked" 2 "BLOCKED: destructive kubectl" - \
  validate-bash.sh "$(j b1 '{"command":"kubectl delete pvc x\n--dry-run=server"}')"
check "dry-run flag after -- blocked" 2 "BLOCKED: destructive kubectl" - \
  validate-bash.sh "$(j b1 '{"command":"kubectl delete pvc x -- --dry-run=server"}')"
check "dry-run flag as redirect target blocked" 2 "BLOCKED: destructive kubectl" - \
  validate-bash.sh "$(j b1 '{"command":"kubectl delete pvc x > --dry-run=server"}')"
check "dry-run flag in command substitution blocked" 2 "BLOCKED: destructive kubectl" - \
  validate-bash.sh "$(j b1 '{"command":"kubectl delete pvc x $(echo --dry-run=server)"}')"
check "continuation-line real delete after dry-run blocked" 2 "BLOCKED: destructive kubectl" - \
  validate-bash.sh "$(j b1 '{"command":"kubectl delete pvc x --dry-run=server\nkubectl \\\n  delete pvc y"}')"
# 4. SOPS from /tmp
check "sops from /tmp blocked" 2 "BLOCKED: SOPS" - \
  validate-bash.sh "$(j b1 '{"command":"sops -e /tmp/secret.yaml"}')"
check "sops in repo allowed" 0 - - \
  validate-bash.sh "$(j b1 '{"command":"sops -d apps/x/secret.yaml"}')"
check "sops --extract to /tmp allowed" 0 - - \
  validate-bash.sh "$(j b1 '{"command":"sops -d --extract '\''[\"k\"]'\'' x.yaml > /tmp/val"}')"
check "normal command allowed" 0 - - \
  validate-bash.sh "$(j b1 '{"command":"cargo test"}')"
check "empty input tolerated" 0 - - validate-bash.sh ""
check "garbage input tolerated" 0 - - validate-bash.sh "not json at all"

# ── validate-nix (PostToolUse: exit 2 feeds stderr to the model) ──
printf '{ foo = ; }' > "$TMP/broken.nix"
printf '{ foo = 1; }' > "$TMP/ok.nix"
if command -v nix-instantiate >/dev/null 2>&1; then
  check "broken nix reported" 2 "Nix parse failed" - \
    validate-nix.sh "$(j n1 "{\"file_path\":\"$TMP/broken.nix\"}")"
  check "valid nix silent" 0 - - \
    validate-nix.sh "$(j n1 "{\"file_path\":\"$TMP/ok.nix\"}")"
fi
check "non-nix skipped" 0 - - \
  validate-nix.sh "$(j n1 "{\"file_path\":\"$TMP/whatever.txt\"}")"

# ── validate-shell (PostToolUse) ──
if command -v shellcheck >/dev/null 2>&1; then
  printf '#!/usr/bin/env bash\nrm $(ls)\n' > "$TMP/warn.sh"
  printf '#!/usr/bin/env bash\nls -- "$1"\n' > "$TMP/clean.sh"
  check "shellcheck finding reported" 2 "shellcheck:" - \
    validate-shell.sh "$(j s1 "{\"file_path\":\"$TMP/warn.sh\"}")"
  check "clean script silent" 0 - - \
    validate-shell.sh "$(j s1 "{\"file_path\":\"$TMP/clean.sh\"}")"
fi
check "non-shell skipped" 0 - - \
  validate-shell.sh "$(j s1 "{\"file_path\":\"$TMP/ok.nix\"}")"

# validate-rust was removed: per-edit `cargo check` re-improvised heavy
# verification the pre-push rust:ci gate already owns (lean-code), and its
# 120s cold-build could stall a memory-constrained host. Rust verification
# now lives only at the owning layer.

# ── validate-manifest (PostToolUse) ──
if command -v yq >/dev/null 2>&1; then
  printf 'kind: Deployment\nspec: {}\n' > "$TMP/workload.yaml"
  printf 'a: 1\n' > "$TMP/plain.yaml"
  printf 'kind: Deployment\n# seccompProfile allowPrivilegeEscalation resources:\nspec: {}\n' > "$TMP/comments.yaml"
  cat > "$TMP/compliant.yaml" <<'YAML'
kind: Deployment
spec:
  template:
    spec:
      securityContext:
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: app
          securityContext:
            allowPrivilegeEscalation: false
          resources:
            requests: { cpu: 10m, memory: 64Mi }
            limits: { memory: 128Mi }
YAML
  check "workload missing baseline reported" 2 "missing" - \
    validate-manifest.sh "$(j m1 "{\"file_path\":\"$TMP/workload.yaml\"}")"
  check "commented keys do not satisfy probes" 2 "missing" - \
    validate-manifest.sh "$(j m1 "{\"file_path\":\"$TMP/comments.yaml\"}")"
  check "compliant workload silent" 0 - - \
    validate-manifest.sh "$(j m1 "{\"file_path\":\"$TMP/compliant.yaml\"}")"
  check "plain yaml silent" 0 - - \
    validate-manifest.sh "$(j m1 "{\"file_path\":\"$TMP/plain.yaml\"}")"
fi
check "non-yaml skipped" 0 - - \
  validate-manifest.sh "$(j m1 "{\"file_path\":\"$TMP/ok.nix\"}")"

# ── check-loop (PreToolUse: JSON advisory at 5+, exit 2 block at 12+) ──
LOOP_JSON="$(j loop '{"command":"cargo test --all"}')"
for _ in 1 2 3 4; do printf '%s' "$LOOP_JSON" | "$HOOKS/check-loop.sh" >/dev/null 2>&1; done
check "5th repeat advisory JSON" 0 - "additionalContext" check-loop.sh "$LOOP_JSON"
for _ in 6 7 8 9 10 11; do printf '%s' "$LOOP_JSON" | "$HOOKS/check-loop.sh" >/dev/null 2>&1; done
check "12th repeat blocked" 2 "Loop detected" - check-loop.sh "$LOOP_JSON"
check "different command unaffected" 0 - - \
  check-loop.sh "$(j loop '{"command":"git status"}')"

# ── check-git-state (Stop: human-facing stdout, always exit 0) ──
check "stop report exits zero" 0 - - check-git-state.sh "$(j g1 'null')"

# ── eval-contamination guard (mechanical; prevents the round-27 failure) ──
# The solving runner injects each SKILL.md body as the solver's system prompt,
# so a grader-distinctive token from a task's test.sh appearing in a skill body
# is answer-injection. Fail loudly if any does.
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ -d "$REPO_ROOT/evals" ]; then
  # Curated tripwire tokens: grader-distinctive identifiers from
  # evals/*/tasks/*/test.sh that a generic skill would never need to name, and
  # that are absent from the legitimate de-contaminated skills (so real infra
  # names like sops-age / cert-manager, documented legitimately, never trip).
  # Auto-derivation was tried and rejected — it floods on common words
  # (API/JSON/HTTP) and on k8s fields skills rightly use (seccompProfile).
  # REVIEW this list when a solving task's distinctive entities change.
  CONTAM=""
  for tok in jetstack WORKSTATION_NAMESPACE installCRDs driftDetection; do
    grep -rqwF "$tok" "$REPO_ROOT"/skills/*/SKILL.md 2>/dev/null && CONTAM="$CONTAM $tok"
  done
  if [ -n "$CONTAM" ]; then
    FAIL=$((FAIL + 1)); echo "FAIL: eval-answer token(s) in a SKILL.md body:$CONTAM"
  else
    PASS=$((PASS + 1))
  fi
fi

# ── session keying (jq derives the per-session path; skipped without it) ──
if command -v jq >/dev/null 2>&1; then
  printf '%s' "$(j key '{"command":"true"}')" | "$HOOKS/check-loop.sh" >/dev/null 2>&1
  if [ -f "${XDG_RUNTIME_DIR:-$HOME/.cache}/claude-loop-hooktest-key.log" ]; then PASS=$((PASS + 1)); else
    FAIL=$((FAIL + 1)); echo "FAIL: loop state not keyed by session_id"
  fi
fi

# ── check-merge (PreToolUse, worker hosts: skills#28 review gate for merges) ──
# A fake gh serves one PR view from $FAKE_PR (or fails); who may merge comes from the session transcript's
# Coordinator handoffs (as herdr:message delivers them), never from comment signatures.
FB="$TMP/fakebin"; mkdir -p "$FB"
printf '#!/bin/sh\n[ -n "${FAKE_GH_FAIL:-}" ] && { echo "gh: HTTP 502" >&2; exit 1; }\ncat "$FAKE_PR"\n' >"$FB/gh"
chmod +x "$FB/gh"
H=0b436abfc57355f46c1a6d08162e60d62ea5ae69
URL=https://github.com/sammasak/devenv-platform/pull/117
pr() { # pr <body> <comment-body>... -> $FAKE_PR
  jq -n --arg h "$H" --arg u "$URL" --arg b "$1" '{url: $u, headRefOid: $h, body: $b, comments: ($ARGS.positional | map({body: .}))}' --args "${@:2}" >"$TMP/pr.json"
  export FAKE_PR="$TMP/pr.json"; }
handoff() { # handoff <file> <pane> <allowed> <extra-line>: a transcript with one delivered Coordinator prompt
  jq -nc --arg t "Assignment #92 for acer-swift/$2"$'\n\nScope: s\n\nAllowed actions: '"$3"$'. Reading, committing and opening a PR are always implied.\n'"${4:+$'\n'$4}" \
    '{type: "user", message: {role: "user", content: $t}}' >"$1"; }
handoff "$TMP/t-review" wW:p1 "merge, comment" "Review of: sammasak/devenv-platform#117 at head $H"
handoff "$TMP/t-merge" w12:p1 "merge, comment" "Merge target: $URL"
handoff "$TMP/t-impl" wF:p1 "comment, deploy:none" ""
handoff "$TMP/t-oldhead" wW:p1 "merge, comment" "Review of: sammasak/devenv-platform#117 at head caef8b86d58a5e18c74b81b26ec013d2383ce610"
handoff "$TMP/t-other" w12:p1 "merge, comment" "Review of: sammasak/devenv-platform#117 at head $H"
handoff "$TMP/t-nomerge" wW:p1 "comment" "Review of: sammasak/devenv-platform#117 at head $H"
mc() { # mc <name> <want_exit> <stderr_pattern> <pane> <transcript> <command>
  local name=$1 want=$2 pat=$3 pane=$4 tr=$5 cmd=$6 code err
  jq -nc --arg c "$cmd" --arg t "$tr" '{session_id: "hooktest-m1", transcript_path: $t, tool_input: {command: $c}}' \
    | PATH="$FB:$PATH" HERDR_PANE_ID="$pane" CHECK_MERGE_TEST_HOST=acer-swift "$HOOKS/check-merge.sh" 2>"$TMP/err"; code=$?
  err=$(cat "$TMP/err")
  if [ "$code" -eq "$want" ] && { [ "$pat" = - ] || echo "$err" | grep -q "$pat"; }; then PASS=$((PASS + 1)); else
    FAIL=$((FAIL + 1)); echo "FAIL: check-merge: $name (exit=$code want=$want; stderr='$err')"; fi; }
M="gh pr merge 117 -R sammasak/devenv-platform --merge --match-head-commit $H"
G9=$'Grade: 9/10 (head 0b436ab)\n\n-- acer-swift wW:p1'
pr $'Closes #92.' "$G9"
mc "a command that is not a merge passes" 0 - wW:p1 "$TMP/t-review" "gh pr view 117"
mc "a quoted mention (echo) is not a merge" 0 - wW:p1 "$TMP/t-impl" "echo 'gh pr merge 117' >notes"
mc "a commit message mentioning gh pr merge is not a merge" 0 - wF:p1 "$TMP/t-impl" 'git commit -m "guard gh pr merge 117"'
mc "a heredoc body mentioning gh pr merge is data, not a merge" 0 - wF:p1 "$TMP/t-impl" $'cat >doc.md <<\'EOF\'\ngh pr merge 117 --merge\nEOF'
mc "the independent reviewer (review handoff for this head, merge allowed) merges at 9/10" 0 - wW:p1 "$TMP/t-review" "$M"
mc "a different pane merges on its merge handoff (Merge target) at 9/10" 0 - w12:p1 "$TMP/t-merge" "$M"
mc "the implementer (no merge or review handoff) is refused even with a reviewer's 9/10" 2 "no Coordinator handoff" wF:p1 "$TMP/t-impl" "$M"
pr $'Closes #92.' $'Grade: 9/10 (head 0b436ab)\n\n-- acer-swift wW:p1 (typed by wF)'
mc "a forged signature: the implementer posts a 9/10 signed as wW, still refused" 2 "no Coordinator handoff" wF:p1 "$TMP/t-impl" "$M"
pr $'Closes #92.' $'Grade: 9/10 (head 0b436ab)\n\n-- acer-swift wF:p1'
mc "an unsigned PR body and the implementer's own 9/10: refused" 2 "no Coordinator handoff" wF:p1 "$TMP/t-impl" "$M"
pr $'Closes #92.'
mc "an unreviewed merge (no grade at all) is refused, handoff or not" 2 "no 'Grade" wW:p1 "$TMP/t-review" "$M"
pr $'Closes #92.' $'Grade: 8/10 (head 0b436ab)'
mc "a merge at 8/10 is refused" 2 "no 'Grade" wW:p1 "$TMP/t-review" "$M"
pr $'Closes #92.' $'Grade: 9/10 (head caef8b8)'
mc "a 9/10 on an older head does not admit the new head" 2 "no 'Grade" wW:p1 "$TMP/t-review" "$M"
pr $'Closes #92.' "$G9"
mc "a review handoff for an older head does not authorize this head" 2 "no Coordinator handoff" wW:p1 "$TMP/t-oldhead" "$M"
mc "a handoff addressed to another pane does not authorize this one" 2 "no Coordinator handoff" wW:p1 "$TMP/t-other" "$M"
mc "a handoff without merge in Allowed actions does not authorize a merge" 2 "no Coordinator handoff" wW:p1 "$TMP/t-nomerge" "$M"
mc "outside a Herdr pane a merge is refused" 2 "not in a Herdr pane" "" "$TMP/t-review" "$M"
pr $'Closes #92.'
mc "bypass: an absolute path to gh is the same merge (no grade -> refused)" 2 "no 'Grade" wW:p1 "$TMP/t-review" "/run/current-system/sw/bin/$M"
mc "bypass: bash -c \"gh pr merge ...\" is the same merge (refused)" 2 "no 'Grade" wW:p1 "$TMP/t-review" "bash -c \"$M\""
mc "bypass: env/command prefixes and a later line are the same merge (refused)" 2 "no 'Grade" wW:p1 "$TMP/t-review" $'cd /tmp\nenv GH_PAGER= command '"$M"
mc "bypass: a REST merge (gh api .../pulls/N/merge) is refused" 2 "not through the API" wW:p1 "$TMP/t-review" "gh api -X PUT repos/sammasak/devenv-platform/pulls/117/merge -f merge_method=merge"
mc "bypass: a GraphQL mergePullRequest is refused" 2 "not through the API" wW:p1 "$TMP/t-review" "gh api graphql -f query='mutation { mergePullRequest(input: {pullRequestId: \"x\"}) { clientMutationId } }'"
mc "a merge without a pinned head is refused" 2 "pin the graded head" wW:p1 "$TMP/t-review" "gh pr merge 117 --merge"
mc "a merge naming no PR is refused" 2 "name the PR number" wW:p1 "$TMP/t-review" "gh pr merge --merge --match-head-commit $H"
pr $'Closes #92.' "$G9"
mc "a head that moved since the grade is refused" 2 "not the pinned" wW:p1 "$TMP/t-review" "gh pr merge 117 --merge --match-head-commit 1111111111111111111111111111111111111111"
FAKE_GH_FAIL=1 mc "a failed gh pr view blocks (fail closed)" 2 "fail closed" wW:p1 "$TMP/t-review" "$M"
unset FAKE_GH_FAIL

SKIPPED=0
MISSING=""
command -v jq >/dev/null 2>&1 || { SKIPPED=$((SKIPPED + 1)); MISSING="$MISSING jq"; }
command -v nix-instantiate >/dev/null 2>&1 || { SKIPPED=$((SKIPPED + 2)); MISSING="$MISSING nix-instantiate"; }
command -v shellcheck >/dev/null 2>&1 || { SKIPPED=$((SKIPPED + 2)); MISSING="$MISSING shellcheck"; }
command -v yq >/dev/null 2>&1 || { SKIPPED=$((SKIPPED + 4)); MISSING="$MISSING yq"; }
echo "---"
echo "passed=$PASS failed=$FAIL skipped=$SKIPPED"
if [ "$SKIPPED" -gt 0 ] && [ "${ALLOW_SKIP:-0}" != "1" ]; then echo "refusing a silently under-tested run — missing tools:$MISSING (set ALLOW_SKIP=1 to accept; the pre-push gate runs them via nix shell)" >&2; exit 1; fi
[ "$FAIL" -eq 0 ]
