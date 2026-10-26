# Goal: dogfood our own tooling and make our agent skills trustworthy

Repository: `sammasak/skills` (exclusive write ownership). Branch: `dogfood-skills-trust`.
Plan: [2026-10-26-dogfood-skills-plan.md](2026-10-26-dogfood-skills-plan.md).

## Mission (verbatim from owner, 2026-10-26)

Our coding agents must actually use the tools we have built. They must understand how to
discover them, invoke them, interpret their output, and report bugs to the correct repository.

**This is a skills and developer-experience quality cycle, not a project to invent more generic
agent infrastructure.**

Two other agents own `nix-audit` and LLM observability; do not modify those repositories.

The result must be **short, testable, useful in real work, and easier to maintain than the
current setup**. Do not finish by producing only documentation.

## Hard constraints

- Write only to `sammasak/skills`. Never edit `nix-audit`, `factum`, `devenv-platform`,
  LLM-observability or any other repo; propose upstream changes as sanitized drafts instead.
- May commit, push the feature branch and open a PR. May NOT merge, modify/close issues, file
  issues, or deploy updated skills (flake.lock bump in nixos-config, `just switch`) without the
  owner's explicit approval. **No agent stand-in may authorize these** (overrides the global
  "owner is never the blocker" rule for this goal).
- No speculative edits: every SKILL.md change traces to a recorded discrepancy.
- Do not embed copies of tools' user guides; skills are concise entrypoints linking canonical docs.
- No large mandatory instruction blocks; preserve the lightweight, opt-in philosophy; no
  duplicated instructions across skills.
- Hosts are memory-constrained and another Acer session runs expensive verification: no full
  Rust builds to demo a trigger; heavy checks run sequentially.
- Never invent an eval score when execution is unavailable; never relabel a failed or
  inconclusive dogfood run as success; never read missing scanner evidence as success.
- Reports never contain secrets or raw user content.

## Definition of done (checkable)

A fresh coding-agent session can discover our tools, activate the relevant skill, invoke a real
installed tool correctly, interpret its results safely, run the correct verification gate, and
produce a properly routed, reproducible issue draft. Concretely, all of:

1. **Audit recorded** — `docs/plans/2026-10-26-compat-audit.md` lists each discrepancy found
   between skill text, canonical upstream docs and the installed tool (command path, version/rev,
   flags, output schema, exit codes), including the known `nix-audit-operator` one (`--json` →
   `--json-out`; #32 closed/accepted, enforcement still disabled) — verified, not assumed.
2. **Skills corrected** — every audited discrepancy is fixed or explicitly deferred with reason in:
   nix-audit-operator, tooling-feedback, sdlc-pipeline, rust-engineering (Factum), pi-offload,
   pi-ticket, kubernetes-gitops, verify-service. Each cited example command was executed (or is
   marked untested with why).
3. **Workflow nudge** — the smallest existing entrypoint (descriptions/triggers, `global-context.md`
   or equivalent) encourages: inspect env → pick skill → use existing tool → run authoritative
   check → interpret honestly → report via tooling-feedback → flag skill/doc regressions.
   Net instruction size does not grow materially.
4. **Evals** — positive and negative cases exist in the repo's `evals/` framework for every
   scenario listed in the plan's Task 3, and the harness was **actually run**; results (pass/fail
   counts, raw output path) are recorded. Existing manifest/hook tests in `tests/` pass.
5. **Dogfood evidence** — one real, read-only invocation of an installed tool (Factum CLI and/or
   platform.sdlc) recorded with: skill applied + why, exact invocation, discovered executable
   path + pinned version, raw result, whether it helped, confusions/breakage, owning repo and a
   sanitized issue draft if a genuine defect was found.
6. **Upstream mismatch list** — short list of documentation mismatches in other repos with a
   proposed small change each, as tooling-feedback-format drafts (not filed).
7. **Delivered** — focused commits on `dogfood-skills-trust`, pushed, PR open against
   `sammasak/skills` main containing all of the above plus test results; an independent
   reviewer subagent has reviewed the PR and its findings are fixed or answered. PR left
   unmerged for the owner.

Terminal condition for a `/goal` or loop: items 1–7 hold, OR the human has explicitly accepted
a blocker for the remaining item (quote the acceptance verbatim in the PR and leave the item
documented as unmet).

## Accepted blockers (2026-10-26)

Acceptance text received verbatim through the session's stop-hook feedback channel. **Unconfirmed:** it may have been evaluator text rather than the owner; it counts only once the owner confirms directly:

> "I accept the Codex-login and branch-history blockers"

Documented as blocked, not satisfied:

- **Codex task run on acer:** Codex has no credentials there (`codex doctor`). Evidence that does
  exist: Codex's own `debug prompt-input` lists the branch skills from the Nix-built tree; Claude
  Code and Pi activate them. Operator step: `codex login` on acer, then rerun the scenarios in
  `2026-10-26-dogfood-evidence.md` §6 with `CODEX_HOME` pointing at the built tree.
- **Private product name in PR #15 branch history:** not in HEAD; GitHub keeps PR commits and the
  repo hook forbids force-push. Operator step: squash-merge so it does not reach `main`.

