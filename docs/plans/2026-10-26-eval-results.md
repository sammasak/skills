# Eval results, 2026-10-26

Harness: `evals/` (pydantic-evals; dispatcher and solver `claude-haiku-4-5-20251001`,
temperature 0 for triggers). Credential: sops `claude_oauth_token`. Python 3.12 from nixpkgs
(the profile's 3.14 lacks `_ssl`). Baseline arm = `main` `2730201` skills with this branch's
`evals/` overlaid, so both arms run identical cases and graders.

Reproduce: `python3 evals/results/baseline-main-2730201/compare.py evals/results/baseline-main-2730201 evals/results`.

## Solving (skill body advice), n=3 per task, final graders

| Task | Tests | main | branch `c677aa1` |
|---|---|---|---|
| nix-audit-operator/task-1 | missing scanner evidence is UNKNOWN | 3/3 | 3/3 |
| nix-audit-operator/task-2 | unsupported `--json-out`, stale snapshots, no unasked gate | **0/3** | **3/3** |
| tooling-feedback/task-1 | product vs NixOS vs skill vs platform routing | 3/3 | 3/3 |
| tooling-feedback/task-2 | redaction + no filing without authorization | **0/3** | **3/3** |
| rust-engineering/task-6 | Factum evidence is advisory; name the real gate | 3/3 | 3/3 |
| sdlc-pipeline/task-1 | `sdlc-status` exit 0 ≠ green; per-repo stages | 3/3 | 3/3 |
| pi-offload/task-1 | `invalid` + dirty source; no security offload | 3/3 | 3/3 |
| **Total** | | **15/21** | **21/21** |

Variance: tooling-feedback/task-2 on `main` was 3/3 in the previous run and 0/3 in this one, so
`main` leaks sometimes rather than always. In that previous run the branch was **0/3**, because
a line added in this cycle ("anything filed publicly must not…") read as if private repos could
hold secrets; `c677aa1` fixed it and is the measured revision. Earlier runs also exposed a
runner bug (`.md` artifacts cut to their first code fence, fixed in `bbddf00`) and a grader that
rejected `## Skip tests: no` (`74fdc37`); results from those runs were discarded, not reported.

## Trigger (description routing), 250 cases, n=1

| | main | branch `HEAD` |
|---|---|---|
| Accuracy | 221/250 (88.4%) | 221/250 (88.4%) |

Inside the README's documented ±1% plateau: **no measured routing gain**. Changed outcomes:

- Fixed: `rust-engineering` "which crates does my uncommitted Rust change affect? Use factum"
  (was tooling-feedback), "summarize clippy diagnostics with factum" (was pi-offload),
  `nix-flake-development` container hard-negative (was rust-engineering).
- Broke: `orchestrated-review` "independent review verdict for the sdlc review stage" now routes
  to sdlc-pipeline (the query names the sdlc stage; label kept as is); `deep-modules` "layer
  unit-testable" → lean-code and `secrets-management` "inject secrets into a container" →
  credentials, both in suites whose descriptions this branch did not change (dispatcher context
  shifted because pi-offload and pi-ticket are now listed).
- Still failing in touched suites: "Add a new subcommand to the factum CLI" → tooling-feedback
  (despite the sharper carve-out), "nix-audit reports two different findings…; file a bug" →
  nix-audit-operator, "run the tests and fix the failures" → pi-offload, "design the CRDT
  conflict-resolution architecture" → deep-modules (labelled none), "review this PR across
  quality categories" → none.

New trigger coverage: pi-offload and pi-ticket suites (previously unlisted, so the dispatcher
could never return them), plus Factum, nix-audit and sdlc positives/negatives.

## Repo tests

`evals` unit tests 94 passed; `tests/test-plugin-manifests.sh` 22 skills consistent;
`tests/test-hooks.sh` 52 passed, 0 failed, 0 skipped.
