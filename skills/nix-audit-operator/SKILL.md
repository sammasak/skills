---
name: nix-audit-operator
description: "Use when running, interpreting, or safely dogfooding nix-audit on a built NixOS closure, comparing running and candidate generations, or checking an incomplete vulnerability scan. Not for flake development or creating a bug report (use tooling-feedback)."
allowed-tools: Bash, Read
---

# nix-audit operator

Authority: the [README](https://github.com/sammasak/nix-audit/blob/main/README.md) of the revision you run (operator guide: `docs/USER-GUIDE.md` once nix-audit PR #46 lands). This skill is the safe entrypoint, not a copy.

**Status:** advisory, report-only pilot. #32 is closed (ready to integrate as advisory), but automatic enforcement stays **off**: never add `--gate` to a rebuild, deploy or CI path. Blocking integration needs a separate explicit owner decision. A manual `diff … --gate` run is fine; report its exit code as evidence, not as approval.

## Find the binary first

```sh
command -v nix-audit && nix-audit --version   # nix-audit 0.1.0 (<12-char rev>)
nix-audit scan --help | grep -q -- --json-out && echo json-out || echo json-only
```

Installed only on Lenovo (nixos-config `nix-audit-lenovo.nix`, pinned `12d640a`, which predates `--json-out`). Elsewhere it is absent; do not build one to produce an example. Refuse a binary whose version ends `-dirty)` or `(unknown revision)` for any claim about a release.

## Read-only runs

```sh
nix-audit scan /run/current-system --no-scan    # inventory only: no scanners, no root, no vulnerability claim
```

Full scans (`--scanners grype,vulnix`, the default) may download databases and vulnix needs network; run them only when asked. `--scanners grype --offline` is the offline option. Do not drop a scanner to get a green result.

## Compare running vs an already-built candidate

Same binary, scanners and policy on both sides. Remove old snapshots first: a usage error (unknown flag) leaves an existing file in place, and only `--json-out` deletes it on exit 2/3.

```sh
rm -f current.json candidate.json
# json-out builds:
nix-audit scan /run/current-system --policy p.toml --json-out current.json
nix-audit scan "$candidate"        --policy p.toml --json-out candidate.json
# json-only builds (12d640a): exit 1 still writes a valid report; discard only on 2/3
#   nix-audit scan … --json > current.json; [ $? -le 1 ] || rm -f current.json
nix-audit diff current.json candidate.json --policy p.toml   # add --gate only when explicitly asked
```

Do not pipe `diff` into `head` on `12d640a`: it exits 3 on a closed pipe (fixed on main).

## Exit codes and what they prove

| | 0 | 1 | 2 | 3 |
|---|---|---|---|---|
| `scan` | no violations **among evidence evaluated** | policy violations | usage / bad policy / bad target | tool failure: nix or a scanner missing or failed (outranks 1); report printed but incomplete |
| `diff` | computed (even when "not comparable") / `--gate` pass | `--gate` fail | usage / bad snapshot | `--gate` **not evaluated** (incomplete side, not comparable, cross-host) |

- Always read `policy.complete` / `incomplete`: exit 0 with `complete: false` is not clean, and `--no-scan` with finding rules is always incomplete (so gating two `--no-scan` snapshots is exit 3, not evaluated).
- `gate: pass` means "no new violations vs the baseline", not a strict pass; standing violations still count.
- Exit 3, a failed or stale scanner, or a missing scan section means **unknown coverage, never zero vulnerabilities**.
- `confirmed` = two scanners matched an advisory, not proven exploitable.
- Report `producer`, scanners, offline mode, `policy.complete` and comparability alongside any verdict.

## Feedback

A real bug or confusing output → `tooling-feedback`. CLI behaviour: `sammasak/nix-audit` (its `docs/FEEDBACK.md` once PR #46 lands). Packaging, PATH, pin: `sammasak/nixos-config` (public). Never file without authorization.
