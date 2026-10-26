# Eval Runner

This directory contains the evaluation framework for `skills`. There are three distinct eval modes, each testing a different aspect of skill quality.

## Overview

### Trigger evals
**What they test:** Does Claude invoke the right skill?

The dispatcher agent (claude-haiku) receives a user query and must return the correct skill name or `"none"`. Trigger evals measure the quality of skill *descriptions* — the one-line summaries in SKILL.md frontmatter that tell the dispatcher when to activate each skill.

Cases come from `<skill>/trigger.yaml` files and are categorized as:
- `positive` — queries that should activate the skill
- `hard_negative` — queries that look similar but should activate a *different* skill (or none)
- `true_negative` — generic queries that should return `"none"`

### Solving evals
**What they test:** Does Claude produce correct output?

A full `claude -p` session receives the task instruction and must produce a file artifact. Solving evals measure the quality of the skill *body* — its guidance, patterns, and examples.

Each task has a deterministic `test.sh` script (BashGrader) and an optional `quality.md` rubric for LLM-based scoring (StructuredRubricJudge).

### GEPA optimization
**What it does:** Auto-improve skill descriptions via evolutionary search.

GEPA (Generative Evolutionary Prompt Adaptation) treats each skill's description string as a "gene" and evolves them to maximize trigger accuracy. It uses failure analysis to guide the proposer: when a skill is mis-classified, GEPA asks the LLM to revise that skill's description to be more distinctive.

## Setup

```bash
cd evals
uv sync
export ANTHROPIC_API_KEY="sk-ant-..."  # or CLAUDE_CODE_OAUTH_TOKEN
```

On NixOS the profile Python may lack `_ssl`; use nixpkgs' interpreter and the sops token:

```bash
nix shell nixpkgs#uv nixpkgs#python312 -c bash -c \
  'export CLAUDE_CODE_OAUTH_TOKEN="$(cat /run/secrets/claude_oauth_token)"
   UV_PYTHON=$(command -v python3.12) UV_PYTHON_DOWNLOADS=never uv run python -m runner.trigger'
```

## Running trigger evals

```bash
uv run python -m runner.trigger                              # all committed trigger cases (see evals/results for the current count)
uv run python -m runner.trigger --skill kubernetes-gitops   # one skill
uv run python -m runner.trigger --repeat 3                  # 3x for variance measurement
uv run python -m runner.trigger --no-save                   # skip JSON report save
```

**Output explained:**
- Per-case table — shows query, expected skill, predicted skill, and pass/fail
- Confusion matrix — reveals which skills are being confused with each other
- Per-skill precision/recall — identifies which skills have poor descriptions

## Running solving evals

```bash
uv run python -m runner.solving                           # all 15 tasks
uv run python -m runner.solving --skill rust-engineering  # one skill
uv run python -m runner.solving --task task-1             # one task
uv run python -m runner.solving --no-cleanup              # keep tmpdirs for debugging
```

**Evaluators:**
- **BashGrader** (deterministic) — runs `test.sh` with `EVAL_OUTPUT_DIR` pointing to the task's tmpdir; passes if exit code is 0
- **StructuredRubricJudge** (LLM-based) — reads `quality.md` dimensions and asks claude-haiku to score the output; only runs when `quality.md` exists

Temporary output directories are created under `/tmp/eval-*/` and cleaned up automatically after each run. Use `--no-cleanup` to keep them for post-mortem inspection.

## Running GEPA optimization

```bash
uv run python -m runner.gepa --iterations 10               # quick test
uv run python -m runner.gepa --iterations 30 --write-back  # full run + write back to SKILL.md
uv run python -m runner.gepa --dry-run                     # preview proposed changes only, skips write-back
```

**How it works:**
1. Seeds the candidate from current SKILL.md frontmatter descriptions
2. Runs trigger evals to score the current descriptions
3. For each failure, routes the case to the affected skills' reflection data
4. Asks the proposer LLM to revise each mis-classified skill's description
5. Repeats until `--iterations` is exhausted or accuracy plateaus

With `--write-back`, the best-found descriptions are written back to the `description:` field in each skill's `SKILL.md` frontmatter.

## Running tests

```bash
cd evals && uv run pytest tests/ -v
```

## Adding a new skill's evals

To add evals for a new skill:

1. **Register the skill** — add its name to the `SKILLS` list in `runner/trigger/dataset.py`
2. **Create the trigger file** — `<skill>/trigger.yaml` with sections:
   ```yaml
   skill: my-new-skill
   positives:
     - "A query that clearly needs this skill"
   hard_negatives:
     - "A similar-looking query that needs a different skill"  # → other-skill
   true_negatives:
     - "A generic query that needs no skill"
   ```
3. **Create task directories** — `<skill>/tasks/task-N/` with `instruction.md`, `test.sh`, and optionally `quality.md`
4. **Register output filenames** — add `(skill, task_id): filename` entries to the `OUTPUT_FILENAMES` dict in `runner/solving/dataset.py`

## Adding a new task

Checklist for each task:

- Create `instruction.md` with the task description. You do not need to hardcode an output path — the runner injects a preamble directing Claude to an isolated tmpdir automatically.
- Create `test.sh` using the `EVAL_OUTPUT_DIR` environment variable:
  ```bash
  OUTPUT="${EVAL_OUTPUT_DIR:-/tmp/eval-output}/filename"
  # assertions against $OUTPUT ...
  ```
- Optionally create `quality.md` with rubric dimensions (enables StructuredRubricJudge scoring).
- Add `(skill, task_id): filename` to `OUTPUT_FILENAMES` in `runner/solving/dataset.py`.

## Results

JSON reports are saved to:
- `results/trigger-TIMESTAMP.json`
- `results/solving-TIMESTAMP.json`

Reports include per-case inputs, outputs, evaluator scores, and reasons. Use `--no-save` on either runner to skip writing the report.

Latest measured comparison (tool skills, baseline vs branch): `docs/plans/2026-10-26-eval-results.md`.

## Earlier baselines (2026-10-09, superseded by the comparison above)

- Trigger dispatch: 135/152 (89±1% plateau across reruns). A real GEPA run
  (4 rollouts, local qwen2.5-coder-7b reflection via ollama; committed
  artifact gepa-*.json) adopted zero changes — seed equals final at 88.8%.
  An earlier uncommitted run landed in the same band (89.5 seed, 88.8 best). A stronger reflection LM (needs an API credential) is the
  only untried lever.
- Solving (haiku solver, strict = all assertions): **8/15 strict, 9/15
  BashGrader** — the measured task-solving pass rate. The weak skill is
  kubernetes-gitops at **1–2/5 BashGrader** (run-to-run variance; n=1
  per-task rollout).
  **CONTAMINATION NOTE (2026-10-12), kept as a standing warning:** the
  solving runner injects each SKILL.md body as the solver's system prompt
  (`runner/solving/task.py`). An attempt that day to "fix" the
  kubernetes-gitops score added a Reference-shapes section that reproduced
  the eval tasks' own entity names and values (cert-manager/jetstack,
  monitoring/infrastructure/sops-age, etc.) — i.e. it fed the solver the
  answers. That is eval-gaming, not a skill improvement; it was reverted
  the same day and the skill is back to its generic content. **Rule: never
  put a solving task's specific entities/values into a skill body.** If a
  skill and a task must share domain facts, hold the task's specifics out
  of the skill or use a held-out task set.
  The honest reading of the 1–2/5: the solver's rubric scores vary run to
  run and the BashGrader's exact-field/path checks are strict; whether the
  true lever is solver capability or grader contract is **not yet
  established** without a de-contaminated n≥3 measurement, which has not
  been run. Graders stay strict; loosening them to raise the number would
  be the slop this setup exists to prevent.
  "0 failures" in any run output means evaluator infrastructure health,
  never the pass rate; quote the strict number.
