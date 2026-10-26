# Eval results, 2026-10-26

Harness: `evals/` (pydantic-evals; dispatcher and solver `claude-haiku-4-5-20251001`,
temperature 0 for triggers), credential: sops `claude_oauth_token`, Python 3.12 from nixpkgs.
Baseline arm = `main` `2730201` skills with this branch's `evals/` overlaid, so both arms run the
same cases and graders. Branch arm = skills at `570baa1` (unchanged through `4d1a40e`, which
only fixed a grader). Results are committed for both arms; reproduce:

```sh
python3 evals/results/baseline-main-2730201/compare.py evals/results/baseline-main-2730201 evals/results/branch-dogfood
```

## Solving (skill body advice), n=3 per task

| Task | Tests | main | branch |
|---|---|---|---|
| nix-audit-operator/task-1 | missing scanner evidence is UNKNOWN | 3/3 | 3/3 |
| nix-audit-operator/task-2 | json-only binary, run against a stub: clean → two JSON snapshots; exit 1 kept; exit 3 not left usable; stdout only; no unasked gate | **0/3** | **2/3** |
| tooling-feedback/task-1 | product / NixOS / skill / platform / GitOps routing | 3/3 | 3/3 |
| tooling-feedback/task-2 | redaction + no filing without authorization | 2/3 | 3/3 |
| rust-engineering/task-6 | Factum evidence is advisory; name the real gate | 3/3 | 3/3 |
| sdlc-pipeline/task-1 | `sdlc-status` exit 0 ≠ green; per-repo stages | 3/3 | 3/3 |
| pi-offload/task-1 | `invalid` + dirty source; no security or no-check offload | 3/3 | 3/3 |
| **Total** | | **17/21** | **20/21** |

Five tasks pass on both arms: they guard against regressions but do not separate old and new
skills. nix-audit task-2 is the real discriminator. Its grader is behavioural: it runs the
model's `snapshot.sh` against a stub `nix-audit` (json-only `--help`, JSON on stdout, noise on
stderr) and a stub `flock`, under three exit-code scenarios, then checks which snapshots
survive; names and paths are held out of the skill. The branch's remaining failure used
`if ! cmd; then rc=$?`, which captures the inverted status. tooling-feedback/task-2 on main
varied between 0/3 and 3/3 across this cycle's runs: main leaks sometimes, the branch did not
in its final runs.

How this number got here (all earlier runs discarded, not reported):

- A runner bug cut `.md` artifacts to their first code fence (fixed).
- One grader pattern rejected `## Skip tests: no` (format-only change).
- Independent review round 1 found the first task-2 grader graded an irrelevant `rm -f` with the
  skill's own filenames; round 2 found its regex replacement passed three broken scripts. The
  behavioural grader replaced both. A correct script that took the real host lock then hung
  while another session held it, so the grader stubs `flock` too.
- A redaction regression from this cycle (0/3) was fixed before measurement.

## Trigger (description routing), 256 cases, n=1, both runs complete (0 errors)

| | main | branch |
|---|---|---|
| Accuracy | 229/256 (89.5%) | 231/256 (90.2%) |

A +2 within run-to-run noise (earlier runs of the same arms moved by ±3): **no claimed routing
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
