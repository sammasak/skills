---
name: nix-audit-operator
description: "Use when running, interpreting, or safely dogfooding nix-audit on a built NixOS closure, comparing running and candidate generations, or checking an incomplete vulnerability scan. Not for flake development or creating a bug report (use tooling-feedback)."
allowed-tools: Bash, Read
---

# nix-audit operator

Use the **installed and pinned** `nix-audit` executable, not an old `target/release` binary. Source of truth: [upstream README](https://github.com/sammasak/nix-audit/blob/main/README.md). Current source maturity is a **candidate for read-only use**, not an automatically approved deploy-security gate.

## First run (safe, read-only)

```sh
command -v nix-audit
nix-audit --version
nix --version
nix-audit scan /run/current-system --no-scan
```

The `--no-scan` run inventories an already-built closure; it does **not** check vulnerability exposure. Avoid `sudo`, and do not build or switch hosts merely to produce an example. `nix-audit scan /run/current-system` invokes scanners (`grype`, `vulnix`), which may download large vulnerability databases. Check their availability and use the documented offline options rather than assuming an isolated or fully offline scan.

## Compare the running system with a built candidate

If requested, and only after the candidate is already built, capture both using the **same scanner selection, policy and tool version**:

```sh
nix-audit scan /run/current-system --no-scan --json > before.json
nix-audit scan "$candidate_store_path" --no-scan --json > after.json
nix-audit diff before.json after.json
```

This first comparison is **inventory only**, not a security gate. Full scan comparisons require actual scanner evidence on both sides. Never report `diff` exit 0 as "safe" if scans were absent, incomplete or incomparable, or if policy evaluation was not performed. Do not use `--gate` automatically until the upstream pre-deploy-gate correctness work ([issue #32](https://github.com/sammasak/nix-audit/issues/32)) has been accepted on the deployed version.

## Interpret defensively

- `confirmed` means *two scanners matched the advisory*, not that exploitability is confirmed.
- Scanner failure or stale/missing database means unknown coverage, **not zero vulnerabilities**.
- An old binary built with dirty or unknown revision is unsuitable for a claim about a particular release.
- When a closure was built on another machine, missing local derivations may limit Vulnix. Do not silently drop scanners to obtain a green result.
- Preserve/report `producer`, scanner choices, policy completeness and comparability. A scan showing no findings is not itself evidence of a clean policy evaluation.

## Feedback handoff

When a real run exposes a bug or confusing output, invoke `tooling-feedback` for a sanitized report with: binary version and revision, current host/Nix version, store path or fixture, exact command, selected scanners, exit code, expected/actual, report provenance, and what was not checked. File **CLI behavior** under `sammasak/nix-audit`; file **NixOS packaging, PATH or pinned input** under `sammasak/nixos-config`. Search for existing issues before filing, and never create a GitHub issue without authorization.
