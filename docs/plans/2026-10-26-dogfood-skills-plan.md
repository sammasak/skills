# Plan: dogfood our tooling, make skills trustworthy

Goal and definition of done: [2026-10-26-dogfood-skills-goal.md](2026-10-26-dogfood-skills-goal.md).
Branch `dogfood-skills-trust` off `main` (`2730201`). Work in `~/skills` (fresh clone);
`~/claude-code-skills` is a diverged pre-squash checkout with uncommitted work — do not touch it.

## Phase 0 — Compatibility audit (read-only; no edits)

Output: `docs/plans/2026-10-26-compat-audit.md` — one table row per discrepancy:
skill · claim in skill · reality (source doc / installed tool) · evidence (command + output) · action.

0.1 **Skills + manifests.** Read the 8 priority SKILL.md files, `plugin.json`, `global-context.md`,
    `hooks/`, `evals/`, `tests/`, `README.md`. Note how each is triggered (description text).
0.2 **Discovery per harness.** Determine how Claude Code (plugin manifest / HM symlinks from
    nixos-config), Codex (`AGENTS.md`/skills path) and Pi discover and activate these skills.
    Confirm from nixos-config which revision of this repo is actually installed (flake.lock) vs main.
0.3 **Installed tools.** For each tool: `command -v`, resolved store path, `--version`/rev,
    `--help` flags, exit codes on a trivial/invalid input. Tools: `nix-audit`, Factum CLI,
    `sdlc-status` + `devenv tasks list` in a platform.sdlc repo, Pi worker entrypoint(s),
    `kubectl`/`flux` as referenced by kubernetes-gitops/verify-service.
0.4 **Canonical docs.** Read (don't edit) each tool's current upstream README/guide on main via
    `gh api`/`gh repo view`; record rev. For nix-audit: confirm `--json-out`, scan/diff/policy
    commands, advisory gate semantics, incomplete-evaluation handling, #32 state
    (`gh issue view 32 -R <nix-audit repo>`), enforcement-disabled status.
0.5 **Coordinate** with the nix-audit agent: locate its command/guide compatibility note
    (ListAgents / SendMessage, or its branch/PR) and adopt its final CLI as the source for
    nix-audit-operator. Do not duplicate its scanning work.

Gate: audit table complete; every later edit cites a row.

## Phase 1 — Correct the tool skills (Task 1)

Per skill, a concise operational entrypoint: installed command + how to find version · correct
commands/flags · output format/schema pointer · exit codes & failure interpretation · when to
use / not use · verified vs incomplete/unknown evidence · where to report (→ tooling-feedback) ·
link to canonical doc. Move nothing upstream-sized into the skill.

- **nix-audit-operator** — scan, diff, policy, `--json-out`; advisory gate; incomplete evaluation
  ≠ clean; #32 accepted, automatic enforcement disabled.
- **rust-engineering** — short Factum section: discover pinned CLI; consume diagnostics / impact /
  tests-for / brief / review evidence only where the pinned CLI supports it; advisory only;
  disclose unsupported/unverified lanes; cargo/clippy/tests remain authoritative; the experimental
  model worker is not the supported CLI.
- **sdlc-pipeline** — discover the repo's configured stage machine (don't assume rust preset);
  `sdlc-status --context`; declared devenv tasks; green graph ≠ requirements outside the graph;
  handling missing executables, failed tasks, stale fingerprints, schema mismatches.
- **pi-offload / pi-ticket** — when bounded offload fits; verify HEAD + clean worktree; inspect
  returned patch; rerun authoritative checks; quota, privacy, failure behaviour explicit.
- **tooling-feedback** — repo routing table (product bug vs NixOS/GitOps integration bug vs
  skill/doc regression); sanitized reproducer (no secrets, no raw user content); draft only,
  never file without owner authorization.
- **kubernetes-gitops / verify-service** — fix only audited discrepancies.

Commit per skill (or tightly related pair), subject + one line of why.

## Phase 2 — Normal-workflow nudge (Task 2)

Smallest change that works: sharpen `description:` triggers first; add at most a few lines to the
existing always-loaded entrypoint (`global-context.md` or equivalent) for the 7-step loop
(inspect env → applicable skill → existing tool → authoritative check → honest interpretation →
tooling-feedback → flag skill/doc regression). Deduplicate any copies of the same advice across
skills into one place and link. Measure before/after line/token counts of always-loaded text.

## Phase 3 — Evals (Task 3)

Use the existing `evals/` harness and `tests/` (learn its case format and runner first). Add
positive + negative cases for:

1. nix-audit-operator activation (and non-activation, e.g. flake editing).
2. tooling-feedback activation (and non-activation, e.g. generic feature work).
3. Rust engineering using Factum when appropriate (and not claiming it as authoritative).
4. SDLC-equipped repo → sdlc-pipeline; non-SDLC repo → not.
5. Pi should / should not be used (design, security, no check command → no).
6. Routing: product bug vs NixOS/GitOps integration bug.
7. Detecting outdated/unsupported CLI options (e.g. `nix-audit --json`).
8. Refusing to read missing scanner evidence as success.
9. Not filing issues without owner authorization.
10. Keeping secrets and raw user content out of reports.

Run the harness for real; record raw output path, pass/fail counts, model/harness used. If
execution is unavailable, record that — no invented score. Run existing manifest/hook tests.
Fix skills on genuine failures, re-run.

## Phase 4 — Dogfood (Task 4)

Read-only, bounded, no full Rust builds; check host load first (another Acer session runs heavy
verification). Prefer Factum CLI and/or platform.sdlc in an already-configured repo
(e.g. `sdlc-status --context`, a Factum `brief`/`impact` on a small diff).

Record in `docs/plans/2026-10-26-dogfood-evidence.md`: skill applied + why · discovered executable
path + pinned version · exact invocation · raw result (trimmed) · helped? · confusing/broken ·
owning repo + sanitized issue draft if a genuine defect. Inconclusive is a valid outcome.
Feed real findings back into Phase 1 skills.

## Phase 5 — Cross-repo sync (Task 5)

Reconcile nix-audit-operator with the nix-audit agent's final note. For each upstream doc gap,
write a sanitized tooling-feedback-format draft with a proposed small change → collect in
`docs/plans/2026-10-26-upstream-mismatches.md`. Do not edit or file upstream.

## Phase 6 — Deliver

1. Re-run existing tests + evals; capture results.
2. Push `dogfood-skills-trust`; open PR: corrected skills, manifest fixes, eval cases, test
   results, dogfood evidence, upstream mismatch list, before/after always-loaded size.
3. Independent reviewer subagent reviews the PR; fix findings; re-push.
4. Stop. Do **not** merge, touch issues, or deploy (nixos-config flake.lock bump) — hand to owner.

## Risks

- Installed skills revision ≠ main → note in audit; deployment is the owner's call.
- nix-audit agent's CLI still moving → pin to its stated final version, cite rev.
- Eval harness may need model access/credits → record "not executed" rather than fake results.
