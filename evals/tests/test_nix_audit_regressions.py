"""Offline regressions for nix-audit-operator snapshot handling (no model, no real nix-audit).

1. The json-only snippet in skills/nix-audit-operator/SKILL.md, run against a stub, keeps
   every report and classifies exit 3 by the report's own scanner outcomes.
2. The task-2 grader accepts a correct script and rejects the known failure shapes.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
SKILL = REPO / "skills" / "nix-audit-operator" / "SKILL.md"
GRADER = REPO / "evals" / "nix-audit-operator" / "tasks" / "task-2" / "test.sh"

pytestmark = pytest.mark.skipif(shutil.which("jq") is None, reason="jq not on PATH")


def _report(rc: int, kind: str) -> dict:
    ran = {"status": "ran", "tool_version": "x", "db_built": None, "observations": []}
    grype = {"scanner": "grype", "command": "grype", "outcome": dict(ran)}
    vulnix = {"scanner": "vulnix", "command": "vulnix", "outcome": dict(ran)}
    if rc == 3 and kind == "vulnix":
        vulnix["outcome"] = {"status": "failed", "exit": 1,
                             "detail": "vulnix failed: no local derivation for /nix/store/x (built on another host?)"}
    if rc == 3 and kind == "grype":
        grype["outcome"] = {"status": "failed", "exit": 1, "detail": "grype failed; stderr: database is too old"}
    return {"schema": "nix-audit-report/v0", "scan": {"scanners": [grype, vulnix]},
            "policy": {"source": {"path": "p.toml"}}}


def _stub(tmp: Path, rc: int, kind: str) -> Path:
    bin_dir = tmp / "bin"
    bin_dir.mkdir()
    (tmp / "report.json").write_text(json.dumps(_report(rc, kind)))
    stub = bin_dir / "nix-audit"
    stub.write_text(f'#!/usr/bin/env bash\ncat "{tmp}/report.json"\necho "stub stderr" >&2\nexit {rc}\n')
    stub.chmod(0o755)
    return bin_dir


def _snippet() -> str:
    text = SKILL.read_text()
    start = text.index("On a json-only build")
    block = re.search(r"```sh\n(.*?)```", text[start:], re.DOTALL)
    assert block, "json-only snippet not found in SKILL.md"
    return block.group(1)


@pytest.mark.parametrize(
    ("rc", "kind", "expected"),
    [
        (0, "none", "current.json"),
        (1, "none", "current.json"),
        (3, "vulnix", "current.grype-only.json"),
        (3, "grype", "current.incomplete.json"),
        (2, "none", "current.failed.json"),
    ],
)
def test_skill_snippet_keeps_and_classifies_reports(tmp_path, rc, kind, expected):
    bin_dir = _stub(tmp_path, rc, kind)
    work = tmp_path / "work"
    work.mkdir()
    script = 'set -euo pipefail\nL=""; P=p.toml\n' + _snippet()
    env = {**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}"}
    result = subprocess.run(["bash", "-c", script], cwd=work, env=env, capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    jsons = sorted(p.name for p in work.glob("current*.json"))
    assert jsons == [expected], jsons  # exactly one report, never deleted, never 2>&1-polluted
    json.loads((work / expected).read_text())


GOOD = """set -euo pipefail
for side in now next; do t=/run/current-system; [ $side = next ] && t=$NEXT_GEN
  rc=0; nix-audit scan "$t" --policy "$AUDIT_POLICY" --json > gen-$side.json 2> gen-$side.err || rc=$?
  case $rc in
    0|1) ;;
    3) if jq -e '[.scan.scanners[]? | select(.outcome.status == "failed")] as $f
           | ($f | length) == 1 and $f[0].scanner == "vulnix"' gen-$side.json >/dev/null 2>&1
       then mv gen-$side.json gen-$side.grype-only.json
       else mv gen-$side.json gen-$side.incomplete.json; fi ;;
    *) mv gen-$side.json gen-$side.failed.json ;;
  esac
done
"""

BAD = {
    "deletes_exit3": GOOD.replace("then mv gen-$side.json gen-$side.grype-only.json", "then rm -f gen-$side.json")
                         .replace("else mv gen-$side.json gen-$side.incomplete.json", "else rm -f gen-$side.json"),
    "keeps_exit3_as_complete": GOOD.replace("then mv gen-$side.json gen-$side.grype-only.json", "then :")
                                   .replace("else mv gen-$side.json gen-$side.incomplete.json", "else :"),
    "stderr_into_json": GOOD.replace("2> gen-$side.err", "2>&1"),
    "if_not_status": """for side in now next; do t=/run/current-system; [ $side = next ] && t=$NEXT_GEN
  if ! nix-audit scan "$t" --policy "$AUDIT_POLICY" --json > gen-$side.json; then rc=$?
    [ $rc -le 1 ] || mv gen-$side.json gen-$side.incomplete.json; fi
done
""",
}


def _grade(tmp: Path, script: str) -> subprocess.CompletedProcess:
    (tmp / "snapshot.sh").write_text(script)
    return subprocess.run(["bash", str(GRADER)], env={**os.environ, "EVAL_OUTPUT_DIR": str(tmp)},
                          capture_output=True, text=True, timeout=120)


def test_grader_accepts_correct_script(tmp_path):
    result = _grade(tmp_path, GOOD)
    assert result.returncode == 0, result.stdout + result.stderr


@pytest.mark.parametrize("name", sorted(BAD))
def test_grader_rejects_known_failures(tmp_path, name):
    result = _grade(tmp_path, BAD[name])
    assert result.returncode != 0, f"{name} passed: {result.stdout}"
