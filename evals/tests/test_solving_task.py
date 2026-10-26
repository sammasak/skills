"""Unit tests for runner.solving.task — _load_skill_body, _strip_code_fence, run_solving."""

from __future__ import annotations

from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from runner.solving.dataset import SolvingInput
from runner.solving.task import _artifact_content, _load_skill_body, _strip_code_fence, run_solving

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def make_input(
    instruction: str = "Write a hello world program.",
    skill: str = "rust-engineering",
    task_id: str = "task-1",
    output_filename: str = "main.rs",
) -> SolvingInput:
    return SolvingInput(
        instruction=instruction,
        skill=skill,
        task_id=task_id,
        output_filename=output_filename,
    )


def _make_agent_result(text: str) -> MagicMock:
    result = MagicMock()
    result.output = text
    return result


# ---------------------------------------------------------------------------
# _load_skill_body
# ---------------------------------------------------------------------------


def test_load_skill_body_missing_skill(tmp_path):
    with patch("runner.solving.task.SKILLS_ROOT", tmp_path):
        assert _load_skill_body("nonexistent-skill") == ""


def test_load_skill_body_strips_frontmatter(tmp_path):
    skill_dir = tmp_path / "my-skill"
    skill_dir.mkdir()
    (skill_dir / "SKILL.md").write_text(
        "---\nname: my-skill\ndescription: test\n---\n\n# Body\n\nDo things.\n"
    )
    with patch("runner.solving.task.SKILLS_ROOT", tmp_path):
        body = _load_skill_body("my-skill")
    assert body == "# Body\n\nDo things."
    assert "name:" not in body


def test_load_skill_body_no_frontmatter(tmp_path):
    skill_dir = tmp_path / "raw-skill"
    skill_dir.mkdir()
    content = "# Raw skill\n\nNo frontmatter here."
    (skill_dir / "SKILL.md").write_text(content)
    with patch("runner.solving.task.SKILLS_ROOT", tmp_path):
        assert _load_skill_body("raw-skill") == content


# ---------------------------------------------------------------------------
# _strip_code_fence
# ---------------------------------------------------------------------------


def test_strip_code_fence_rust():
    text = "```rust\nfn main() {}\n```"
    assert _strip_code_fence(text) == "fn main() {}"


def test_strip_code_fence_no_lang():
    text = "```\nsome code\n```"
    assert _strip_code_fence(text) == "some code"


def test_strip_code_fence_plain_text():
    text = "No fence here, just plain text."
    assert _strip_code_fence(text) == text


def test_strip_code_fence_multiline():
    text = "```rust\nfn a() {}\nfn b() {}\n```"
    assert _strip_code_fence(text) == "fn a() {}\nfn b() {}"


def test_strip_code_fence_with_surrounding_text():
    """Only the fenced block is extracted, preamble is dropped."""
    text = "Here is the code:\n```rust\nfn main() {}\n```\nDone."
    assert _strip_code_fence(text) == "fn main() {}"


def test_markdown_artifact_keeps_text_around_fences():
    """A .md answer whose body contains a fenced command must not shrink to that command."""
    text = "Skip tests: no\nWhy: not_run.\n```bash\ndevenv tasks run rust:ci\n```\n"
    assert _artifact_content(text, "assessment.md") == text


def test_markdown_artifact_unwraps_a_whole_markdown_fence():
    assert _artifact_content("```markdown\nGreen: no\n```", "status.md") == "Green: no"


def test_code_artifact_still_extracts_the_fence():
    assert _artifact_content("Here:\n```bash\nrm -f x\n```\nDone.", "snapshot.sh") == "rm -f x"


# ---------------------------------------------------------------------------
# run_solving — success path
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_run_solving_success_writes_artifact(tmp_path):
    """Agent returns code → stripped and written to tmpdir/output_filename."""
    inputs = make_input(output_filename="result.rs")
    agent_result = _make_agent_result("```rust\nfn main() {}\n```")

    mock_agent = MagicMock()
    mock_agent.run = AsyncMock(return_value=agent_result)

    with (
        patch("runner.solving.task.Agent", return_value=mock_agent),
        patch("runner.solving.task.tempfile.mkdtemp", return_value=str(tmp_path)),
    ):
        output = await run_solving(inputs)

    assert output.content == "fn main() {}"
    assert output.returncode == 0
    assert output.timed_out is False
    assert (tmp_path / "result.rs").read_text() == "fn main() {}"


@pytest.mark.anyio
async def test_run_solving_success_no_fence(tmp_path):
    """Plain text response (no code fence) is stored verbatim."""
    inputs = make_input(output_filename="answer.rs")
    agent_result = _make_agent_result("fn main() {}")

    mock_agent = MagicMock()
    mock_agent.run = AsyncMock(return_value=agent_result)

    with (
        patch("runner.solving.task.Agent", return_value=mock_agent),
        patch("runner.solving.task.tempfile.mkdtemp", return_value=str(tmp_path)),
    ):
        output = await run_solving(inputs)

    assert output.content == "fn main() {}"
    assert output.returncode == 0


@pytest.mark.anyio
async def test_run_solving_injects_skill_body(tmp_path):
    """Agent is constructed with the skill body as instructions."""
    skill_body = "# My skill\n\nAlways use iterators."

    inputs = make_input(skill="rust-engineering")
    mock_agent = MagicMock()
    mock_agent.run = AsyncMock(return_value=_make_agent_result("fn f() {}"))

    with (
        patch("runner.solving.task._load_skill_body", return_value=skill_body),
        patch("runner.solving.task.Agent", return_value=mock_agent) as mock_agent_cls,
        patch("runner.solving.task.tempfile.mkdtemp", return_value=str(tmp_path)),
    ):
        await run_solving(inputs)

    mock_agent_cls.assert_called_once()
    _, kwargs = mock_agent_cls.call_args
    assert kwargs.get("instructions") == skill_body


@pytest.mark.anyio
async def test_run_solving_empty_skill_body_passes_none(tmp_path):
    """Empty skill body → instructions=None (no system prompt)."""
    inputs = make_input(skill="unknown-skill")
    mock_agent = MagicMock()
    mock_agent.run = AsyncMock(return_value=_make_agent_result("output"))

    with (
        patch("runner.solving.task._load_skill_body", return_value=""),
        patch("runner.solving.task.Agent", return_value=mock_agent) as mock_agent_cls,
        patch("runner.solving.task.tempfile.mkdtemp", return_value=str(tmp_path)),
    ):
        await run_solving(inputs)

    _, kwargs = mock_agent_cls.call_args
    assert kwargs.get("instructions") is None


# ---------------------------------------------------------------------------
# run_solving — exception path
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_run_solving_agent_exception(tmp_path):
    """agent.run() raises → returncode=-1, stderr contains message."""
    inputs = make_input()
    mock_agent = MagicMock()
    mock_agent.run = AsyncMock(side_effect=Exception("API error"))

    with (
        patch("runner.solving.task.Agent", return_value=mock_agent),
        patch("runner.solving.task.tempfile.mkdtemp", return_value=str(tmp_path)),
    ):
        output = await run_solving(inputs)

    assert output.returncode == -1
    assert output.timed_out is False
    assert "API error" in output.stderr
    assert output.content == ""
