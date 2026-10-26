"""Load solving tasks into a pydantic-evals Dataset."""

from __future__ import annotations

import warnings
from dataclasses import dataclass
from pathlib import Path

from pydantic_evals import Case, Dataset

EVALS_ROOT = Path(__file__).parent.parent.parent

# Skills that have solving tasks
# secrets-management is excluded — it has no solving tasks defined yet
SOLVING_SKILLS = [
    "kubernetes-gitops",
    "rust-engineering",
    "nix-flake-development",
    "nix-audit-operator",
    "tooling-feedback",
    "sdlc-pipeline",
    "pi-offload",
]

# Explicit output filename mapping per task (avoids fragile parsing)
# Format: (skill, task_id) → filename
OUTPUT_FILENAMES: dict[tuple[str, str], str] = {
    ("kubernetes-gitops", "task-1"): "remediation.md",
    ("kubernetes-gitops", "task-2"): "helmrelease.yaml",
    ("kubernetes-gitops", "task-3"): "fix.md",
    ("kubernetes-gitops", "task-4"): "kustomization.yaml",
    ("kubernetes-gitops", "task-5"): "image-automation.md",
    ("rust-engineering", "task-1"): "run_strategy.rs",
    ("rust-engineering", "task-2"): "workspace_name.rs",
    ("rust-engineering", "task-3"): "lints.toml",
    ("rust-engineering", "task-4"): "error.rs",
    ("rust-engineering", "task-5"): "Containerfile",
    ("nix-flake-development", "task-1"): "flake.nix",
    ("nix-flake-development", "task-2"): "module.nix",
    ("nix-flake-development", "task-3"): "fix.md",
    ("nix-flake-development", "task-4"): "flake.nix",
    ("nix-flake-development", "task-5"): "fix.md",
    ("rust-engineering", "task-6"): "assessment.md",
    ("nix-audit-operator", "task-1"): "verdict.md",
    ("nix-audit-operator", "task-2"): "snapshot.sh",
    ("tooling-feedback", "task-1"): "routing.md",
    ("tooling-feedback", "task-2"): "issue.md",
    ("sdlc-pipeline", "task-1"): "status.md",
    ("pi-offload", "task-1"): "decision.md",
}


@dataclass
class SolvingInput:
    instruction: str
    skill: str
    task_id: str
    output_filename: str


@dataclass
class SolvingOutput:
    content: str      # artifact content (empty string if file not created)
    stdout: str       # Claude's full response text
    stderr: str       # Claude's stderr output
    timed_out: bool
    tmpdir: str       # path to tempdir (for BashGrader; must outlive the task fn)
    returncode: int   # process exit code; -1 = timeout, -2 = exception


@dataclass
class SolvingMetadata:
    test_script: Path
    quality_rubric: str | None  # None for tasks without quality.md


def build_solving_dataset(
    skill_filter: str | None = None,
    task_filter: str | None = None,
) -> Dataset[SolvingInput, SolvingOutput, SolvingMetadata]:
    """Build the solving evaluation Dataset."""
    from runner.solving.evaluators import BashGrader, StructuredRubricJudge

    skills = [skill_filter] if skill_filter else SOLVING_SKILLS
    cases: list[Case] = []

    for skill_name in skills:
        task_dir = EVALS_ROOT / skill_name / "tasks"
        if not task_dir.exists():
            continue

        for task_path in sorted(task_dir.iterdir()):
            if not task_path.is_dir():
                continue
            task_id = task_path.name
            if task_filter and task_id != task_filter:
                continue

            instruction_path = task_path / "instruction.md"
            test_sh = task_path / "test.sh"
            quality_path = task_path / "quality.md"

            if not instruction_path.exists() or not test_sh.exists():
                continue

            instruction = instruction_path.read_text()
            quality_rubric = quality_path.read_text() if quality_path.exists() else None

            key = (skill_name, task_id)
            if key in OUTPUT_FILENAMES:
                output_filename = OUTPUT_FILENAMES[key]
            else:
                warnings.warn(
                    f"No output filename mapping for ({skill_name!r}, {task_id!r}); "
                    f"falling back to 'output.md' — task will likely FAIL",
                    stacklevel=2,
                )
                output_filename = "output.md"

            evaluators: tuple = (BashGrader(), StructuredRubricJudge()) if quality_rubric else (BashGrader(),)

            cases.append(
                Case(
                    name=f"{skill_name}::{task_id}",
                    inputs=SolvingInput(
                        instruction=instruction,
                        skill=skill_name,
                        task_id=task_id,
                        output_filename=output_filename,
                    ),
                    metadata=SolvingMetadata(
                        test_script=test_sh,
                        quality_rubric=quality_rubric,
                    ),
                    evaluators=evaluators,
                )
            )

    return Dataset(name="skill-solving-eval", cases=cases)
