"""Unit tests for runner.trigger.dataset."""

from __future__ import annotations

import pytest

from runner.trigger.dataset import (
    EVALS_ROOT,
    _parse_hard_negative,
    _parse_hard_negatives_raw,
    _slugify,
    build_trigger_dataset,
    load_trigger_cases,
)

# ---------------------------------------------------------------------------
# _slugify
# ---------------------------------------------------------------------------


def test_slugify_normal():
    result = _slugify("My Flux HelmRelease is stuck in a reconciliation loop")
    assert result == "my-flux-helmrelease-is-stuck-in-a-reconciliation-loop"


def test_slugify_empty_string():
    result = _slugify("")
    assert result == ""


def test_slugify_all_special_chars():
    result = _slugify("!@#$%^&*()")
    assert result == ""


def test_slugify_truncates_at_60():
    long_input = "a" * 80
    result = _slugify(long_input)
    assert len(result) == 60
    assert result == "a" * 60


def test_slugify_strips_leading_trailing_dashes():
    result = _slugify("  ---hello world---  ")
    assert not result.startswith("-")
    assert not result.endswith("-")
    assert "hello" in result
    assert "world" in result


def test_slugify_lowercases():
    result = _slugify("KubernetesGitOps")
    assert result == result.lower()


# ---------------------------------------------------------------------------
# _parse_hard_negative
# ---------------------------------------------------------------------------


def test_parse_hard_negative_with_comment():
    # _parse_hard_negative receives raw item text (not yaml.safe_load output)
    item_text = '"How do I encrypt a new SOPS secret for my cluster?"             # → secrets-management'
    query, expected = _parse_hard_negative(item_text)
    assert expected == "secrets-management"
    assert "encrypt" in query or "SOPS" in query


def test_parse_hard_negative_kubernetes_gitops():
    item_text = '"My Flux HelmRelease can\'t find the Kubernetes secret"  # → kubernetes-gitops'
    _, expected = _parse_hard_negative(item_text)
    assert expected == "kubernetes-gitops"


def test_parse_hard_negative_nix_flake_development():
    item_text = '"How do I write a Nix flake devShell for Rust development?"       # → nix-flake-development'
    _, expected = _parse_hard_negative(item_text)
    assert expected == "nix-flake-development"


def test_parse_hard_negative_without_comment_warns():
    item_text = "How do I do something suspicious without annotation"
    with pytest.warns(UserWarning, match="hard_negative has no '# → skill' comment"):
        query, expected = _parse_hard_negative(item_text)
    assert expected == "none"
    assert query == item_text.strip()


def test_parse_hard_negative_arrow_variations():
    item_text = '"Some query"  # → container-workflows'
    query, expected = _parse_hard_negative(item_text)
    assert expected == "container-workflows"
    # Quotes are stripped from the query
    assert not query.startswith('"')
    assert not query.endswith('"')


def test_parse_hard_negative_only_first_word_taken():
    item_text = '"Some query"  # → observability-patterns extra words here'
    _, expected = _parse_hard_negative(item_text)
    assert expected == "observability-patterns"


def test_parse_hard_negatives_raw_kubernetes_gitops():
    """Integration test: raw parser correctly extracts expected skills from a real file."""
    trigger_path = K8S_SKILL_DIR / "trigger.yaml"
    pairs = _parse_hard_negatives_raw(trigger_path)
    assert len(pairs) >= 5  # hard negatives in kubernetes-gitops; exact counts rot
    expected_skills = [e for _, e in pairs]
    # All hard_negatives should have non-empty, non-"kubernetes-gitops" expected skills
    for skill in expected_skills:
        assert skill != "kubernetes-gitops"
        assert skill != ""
        # "none" is a valid target since the archival of overlapping skills


# ---------------------------------------------------------------------------
# load_trigger_cases — using the real kubernetes-gitops trigger.yaml
# ---------------------------------------------------------------------------

K8S_SKILL_DIR = EVALS_ROOT / "kubernetes-gitops"


def test_load_trigger_cases_returns_cases():
    cases = load_trigger_cases(K8S_SKILL_DIR)
    assert len(cases) == 19  # 8 positives + 7 hard_neg + 4 true_neg


def test_load_trigger_cases_positive_expected_output():
    cases = load_trigger_cases(K8S_SKILL_DIR)
    positives = [c for c in cases if c.metadata.category == "positive"]
    assert len(positives) >= 8
    for c in positives:
        assert c.expected_output == "kubernetes-gitops"


def test_load_trigger_cases_hard_negative_categories():
    cases = load_trigger_cases(K8S_SKILL_DIR)
    hard_negs = [c for c in cases if c.metadata.category == "hard_negative"]
    assert len(hard_negs) >= 5
    # All hard negatives should have an expected output that is NOT kubernetes-gitops
    for c in hard_negs:
        assert c.expected_output != "kubernetes-gitops"
        assert c.expected_output != ""


def test_load_trigger_cases_true_negative_expected_output():
    cases = load_trigger_cases(K8S_SKILL_DIR)
    true_negs = [c for c in cases if c.metadata.category == "true_negative"]
    assert len(true_negs) == 4
    for c in true_negs:
        assert c.expected_output == "none"


def test_load_trigger_cases_source_skill_metadata():
    cases = load_trigger_cases(K8S_SKILL_DIR)
    for c in cases:
        assert c.metadata.source_skill == "kubernetes-gitops"


def test_load_trigger_cases_nonexistent_dir(tmp_path):
    cases = load_trigger_cases(tmp_path / "does-not-exist")
    assert cases == []


def test_load_trigger_cases_missing_skill_key_raises(tmp_path):
    bad_yaml = tmp_path / "trigger.yaml"
    bad_yaml.write_text("positives:\n  - some query\n")
    with pytest.raises(ValueError, match="missing 'skill' key"):
        load_trigger_cases(tmp_path)


# ---------------------------------------------------------------------------
# build_trigger_dataset — full dataset across all 4 skills
# ---------------------------------------------------------------------------


def test_build_trigger_dataset_total_count():
    dataset = build_trigger_dataset()
    assert len(dataset.cases) >= 67  # grows with the suite; exact counts rot


def test_build_trigger_dataset_category_distribution():
    dataset = build_trigger_dataset()
    positives = [c for c in dataset.cases if c.metadata.category == "positive"]
    hard_negs = [c for c in dataset.cases if c.metadata.category == "hard_negative"]
    true_negs = [c for c in dataset.cases if c.metadata.category == "true_negative"]
    # 8+9+8+8 = 33 positives
    assert len(positives) >= 33
    # 7+5+5+4 = 21 hard negatives
    assert len(hard_negs) >= 21
    # 4+3+3+3 = 13 true negatives
    assert len(true_negs) >= 13


def test_build_trigger_dataset_skill_filter():
    dataset = build_trigger_dataset(skill_filter="rust-engineering")
    assert len(dataset.cases) >= 17  # grows with the suite; exact counts rot
    for c in dataset.cases:
        assert c.metadata.source_skill == "rust-engineering"


def test_build_trigger_dataset_case_names_unique():
    dataset = build_trigger_dataset()
    names = [c.name for c in dataset.cases]
    assert len(names) == len(set(names)), "Case names must be unique"


def test_build_trigger_dataset_name():
    dataset = build_trigger_dataset()
    assert dataset.name == "skill-trigger-eval"


def test_build_trigger_dataset_has_evaluators():
    dataset = build_trigger_dataset()
    assert len(dataset.evaluators) >= 1
