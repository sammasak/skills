# Eval results, 2026-10-26

Harness: `evals/` (pydantic-evals; dispatcher and solver `claude-haiku-4-5-20251001`,
temperature 0 for triggers), credential: sops `claude_oauth_token`, Python 3.12 from nixpkgs.
Baseline arm = `main` `2730201` skills with this branch's `evals/` overlaid, so both arms run the
same cases and graders. Branch arm: skill bodies at `dd7f9b0` (nix-audit-operator) / `dd8f0ec`
(others, unchanged since); trigger descriptions at `dd7f9b0`.

Reproduce: `python3 evals/results/baseline-main-2730201/compare.py evals/results/baseline-main-2730201 evals/results`.

## Solving (skill body advice), n=3 per task

| Task | Tests | main | branch |
|---|---|---|---|
| nix-audit-operator/task-1 | missing scanner evidence is UNKNOWN | 3/3 | 3/3 |
| nix-audit-operator/task-2 | json-only binary: no `--json-out`, exit 3 kept apart from exit 1, no unasked gate | **0/3** | **3/3** |
| tooling-feedback/task-1 | product / NixOS / skill / platform / GitOps routing | 3/3 | 3/3 |
| tooling-feedback/task-2 | redaction + no filing without authorization | **0/3** | **3/3** |
| rust-engineering/task-6 | Factum evidence is advisory; name the real gate | 3/3 | 3/3 |
| sdlc-pipeline/task-1 | `sdlc-status` exit 0 ≠ green; per-repo stages | 3/3 | 3/3 |
| pi-offload/task-1 | `invalid` + dirty source; no security or no-check offload | 3/3 | 3/3 |
| **Total** | | **15/21** | **21/21** |

Five of seven tasks also pass on main: they guard against regressions but do not separate the
old skills from the new. The two discriminating tasks:

- nix-audit task-2 uses filenames and paths that appear in no skill (held out). An earlier
  version graded an irrelevant `rm -f` with the skill's own filenames; independent review caught
  it and it was replaced before this measurement. The branch scored 1/3 once while the json-only
  path was prose only; `dd7f9b0` made it a snippet.
- tooling-feedback task-2 on main was 3/3 in one earlier run and 0/3 in two, so main leaks
  sometimes. One run of this cycle's own edit also leaked (0/3) before the redaction rule was
  rewritten.

Grader changes after seeing outputs were format-only: verdict lines may carry `#`, `*` or `-`
markup (`## Skip tests: no` is correct and was rejected); semantics did not change. A runner bug
(`.md` artifacts cut to their first code fence) was fixed and its runs discarded.

## Trigger (description routing), 256 cases, n=1

| | main | branch |
|---|---|---|
| Accuracy | 230/256 (89.8%) | 230/256 (89.8%) |

**No measured routing gain**: 5 fixed, 5 broken. One branch run lost 14 cases to API timeouts and
was rerun in full after a back-off; only complete runs are reported.

- Fixed: "which crates does my uncommitted Rust change affect? Use factum" and "summarize clippy
  diagnostics with factum" (now rust-engineering), an Axum logging hard-negative, a container
  hard-negative, "review this PR across quality categories" (now orchestrated-review).
- Broke: "independent review verdict for the sdlc review stage" → sdlc-pipeline (query names the
  sdlc stage; label kept); "run the tests and fix the failures" → pi-offload; and three in suites
  whose descriptions this branch did not change (deep-modules → lean-code, knowledge-vault →
  lean-code, secrets-management → credentials): the dispatcher's context changed because
  pi-offload and pi-ticket are now listed.
- Still failing in touched suites: newtype query → deep-modules; "Add a new subcommand to the
  factum CLI" → tooling-feedback; "nix-audit reports two different findings…; file a bug" →
  nix-audit-operator; "run the tests and fix the failures" → pi-offload.

New coverage: pi-offload/pi-ticket suites (the dispatcher could never return them before), Factum,
nix-audit, sdlc, Fish/`nixos:qa`, `gitops:validate` and native-OTLP privacy cases.

## Repo tests

`evals` unit tests 94 passed; `tests/test-plugin-manifests.sh` 22 skills consistent;
`tests/test-hooks.sh` 52 passed, 0 failed, 0 skipped.
