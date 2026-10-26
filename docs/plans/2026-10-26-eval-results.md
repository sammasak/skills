# Eval results, 2026-10-26

Harness: `evals/` (pydantic-evals; dispatcher and solver `claude-haiku-4-5-20251001`,
temperature 0 for triggers), credential: sops `claude_oauth_token`, Python 3.12 from nixpkgs.
Baseline arm = `main` `2730201` skills with this branch's `evals/` overlaid, so both arms run the
same cases and graders. Branch arm = skills at `570baa1`, except nix-audit-operator at `a7c1da3`, measured n=6 on both arms
(its solving runs were redone after the last grader and skill changes; descriptions unchanged
since `570baa1`, so the trigger run stands). Results are committed for both arms, local paths
stripped; reproduce:

```sh
python3 evals/results/baseline-main-2730201/compare.py evals/results/baseline-main-2730201 evals/results/branch-dogfood
```

## Solving (skill body advice); nix-audit-operator n=6, others n=3

| Task | Tests | main | branch |
|---|---|---|---|
| nix-audit-operator/task-1 | missing scanner evidence is UNKNOWN | 6/6 | 6/6 |
| nix-audit-operator/task-2 | json-only binary, behavioural grader (below) | **0/6** | **6/6** |
| nix-audit-operator/task-3 | retained-snapshot boundary: one-side rescan only with same revision, policy, scanners | 4/6 | **6/6** |
| tooling-feedback/task-1 | product / NixOS / skill / platform / GitOps routing | 3/3 | 3/3 |
| tooling-feedback/task-2 | redaction + no filing without authorization | 2/3 | 3/3 |
| rust-engineering/task-6 | Factum evidence is advisory; name the real gate | 3/3 | 3/3 |
| sdlc-pipeline/task-1 | `sdlc-status` exit 0 ≠ green; per-repo stages | 3/3 | 3/3 |
| pi-offload/task-1 | `invalid` + dirty source; no security or no-check offload | 3/3 | 3/3 |
| **Total** | | **24/33** | **33/33** |

The task-2 grader runs the model's `snapshot.sh` against a stub `nix-audit` (json-only `--help`,
JSON with per-scanner outcomes on stdout, noise on stderr) and a stub `flock` under six exit
scenarios: clean; exit 1 on either side; exit 3 from a grype failure on either side (report
kept as evidence, not left looking complete); exit 3 from `vulnix failed: no local derivation`
(report kept, renamed, grype evidence usable). Names and paths are held out of the skill.

Offline regressions (`evals/tests/test_nix_audit_regressions.py`, 19 cases, no model): the
skill's own json-only snippet is extracted from SKILL.md and run against stub reports for
exit 0/1/2, grype-failed exit 3, vulnix-no-derivation exit 3, and three guard cases (vulnix
failed for another reason; vulnix no-derivation with grype failed; with grype skipped); the
task-2 and task-3 graders are self-tested against correct and known-wrong answers. Mutating
three of the four classifier guards fails a test; the fourth (`scanner == "vulnix"`) is
redundant with the detail check, which only vulnix produces.

Earlier n=3/n=6 rounds of this cycle (not reported as results): the branch moved from 1/3 to
4/6 to 3/6 to 6/6 as the skill gained exit-capture pitfalls, report preservation and JSON
classification and as review rounds tightened the graders; main stayed at 0 on task-2 in every
run under every grader version. tooling-feedback/task-2 on main varied between runs (not
committed). Grader changes after seeing outputs were format-only or tightened requirements
the task text states; none loosened a check.

## Trigger (description routing), 256 cases, n=1, both runs complete (0 errors)

| | main | branch |
|---|---|---|
| Accuracy | 229/256 (89.5%) | 231/256 (90.2%) |

A +2, within run-to-run noise (earlier, uncommitted runs of the same arms moved by up to ±3): **no claimed routing
gain**. Changed outcomes:

- Fixed (6): Factum "which crates does my change affect" and "summarize clippy diagnostics" →
  rust-engineering; native-OTLP collector privacy → kubernetes-gitops (was the archived
  `observability-patterns`); "check pod status and the public URL" → verify-service; an Axum
  logging and a container-image hard negative.
- Broke (4): "independent review verdict for the sdlc review stage" → sdlc-pipeline (the query
  names the sdlc stage); "run the tests and fix the failures" → pi-offload; deep-modules →
  lean-code and secrets-management → credentials in suites whose descriptions did not change.

Failing on the branch in suites this branch changed (computed from `git diff`, all 9):
container-image-size and async-Rust negatives → rust-engineering (kubernetes-gitops suite);
NixOS-image deploy → rust-engineering and cluster-SOPS → kubernetes-gitops (nix-flake suite);
"review this PR across quality categories" → none (pi-ticket); newtype → deep-modules;
"run the tests and fix the failures" → pi-offload; "add a subcommand to the factum CLI" →
tooling-feedback; "nix-audit reports two findings…; file a bug" → nix-audit-operator.

New coverage: pi-offload/pi-ticket suites (the dispatcher could never return them before), Factum,
nix-audit, sdlc, Fish/`nixos:qa`, `gitops:validate` and native-OTLP privacy cases.

## Repo tests

`evals` unit tests 94 passed; `tests/test-plugin-manifests.sh` 22 skills consistent;
`tests/test-hooks.sh` 52 passed, 0 failed, 0 skipped.
