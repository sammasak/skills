---
name: nix-audit-operator
description: "Use when running, interpreting, or safely dogfooding nix-audit on a built NixOS closure, comparing running and candidate generations, or checking an incomplete vulnerability scan. Not for flake development or creating a bug report (use tooling-feedback)."
allowed-tools: Bash, Read
---

# nix-audit operator

Authority: the [USER-GUIDE](https://github.com/sammasak/nix-audit/blob/main/docs/USER-GUIDE.md), [PILOT](https://github.com/sammasak/nix-audit/blob/main/docs/PILOT.md) and [README](https://github.com/sammasak/nix-audit/blob/main/README.md) of the revision you run ([CHANGELOG](https://github.com/sammasak/nix-audit/blob/main/CHANGELOG.md) for what changed). This skill is the safe entrypoint, not a copy.

**Status:** advisory, report-only pilot. #32 is closed (ready to integrate as advisory), but automatic enforcement stays **off**: never add `--gate` to a rebuild, deploy or CI path. Blocking integration needs a separate explicit owner decision. A manual `diff … --gate` run is fine; report its exit code as evidence, not as approval.

## Find the binary first

```sh
command -v nix-audit && nix-audit --version   # nix-audit 0.1.0 (<12-char rev>)
nix-audit scan --help | grep -q -- --json-out && echo json-out || echo json-only
```

Installed only on Lenovo (nixos-config `nix-audit-lenovo.nix`, pinned `12d640a`, which predates `--json-out`; release candidate rc1 = `bbd58d5`, untagged, pin bump awaiting owner approval). Do not build one just to produce an example; if the pilot needs a binary, follow USER-GUIDE §1 (clean build, `devenv tasks run nix-audit:verify-build`). Refuse a binary whose version ends `-dirty)` or `(unknown revision)` for any claim about a release.

## Read-only runs

```sh
nix-audit scan /run/current-system --no-scan    # inventory only: no scanners, no root, no vulnerability claim
```

Full scans (`--scanners grype,vulnix`, the default) may download databases and vulnix needs network; run them only when asked, under the host's shared lock (`flock /tmp/$(hostname)-heavy-work.lock …`, PILOT.md). `--scanners grype --offline` is the offline option; it refuses a grype DB older than 5 days (exit 3): check `grype db status`, refresh online with `grype db update`. Do not drop a scanner to get a green result.

## Compare running vs an already-built candidate

Same binary, scanners and policy on both sides; pass the policy as an absolute path (`examples/policy.toml` exists only in a checkout). Remove old snapshots first: a usage error (exit 2) leaves an existing file untouched.

```sh
rm -f current.json candidate.json
# json-out builds:
nix-audit scan /run/current-system --policy p.toml --json-out current.json
nix-audit scan "$candidate"        --policy p.toml --json-out candidate.json
# json-only builds (12d640a): keep exit-3 output as incomplete evidence, never as a snapshot to gate
#   nix-audit scan … --json > current.json; [ $? -le 1 ] || mv current.json current.incomplete.json
nix-audit diff current.json candidate.json --policy p.toml   # add --gate only when explicitly asked
```

`--json-out` writes the report on exit 0, 1 and 3 (exit 3 = incomplete) and removes FILE only when the scan fails before a report exists (unresolved or unbuilt target). Do not pipe `diff` into `head` on `12d640a`: it exits 3 on a closed pipe (fixed on main).

**Hosts built elsewhere** (deploy-rs targets such as acer/msi) have no local `.drv`: vulnix fails (`no local derivation … (built on another host?)`), scan and `diff --gate` exit 3. Record that first. The documented fallback is an explicit grype-only comparison (`diff a.json b.json --scanners grype --policy p.toml --gate`), which labels itself `[scanners compared: grype only]`; report it as grype-only, never as the full verdict, and review any `N findings after not compared` in the candidate's own scan before calling the upgrade clean. Config-only upgrades of such hosts can show `unscannable` regressions with `findings: +0`: fail-closed identity matching, not new vulnerabilities.

## Exit codes and what they prove

| | 0 | 1 | 2 | 3 |
|---|---|---|---|---|
| `scan` | no violations **among evidence evaluated** | policy violations | usage / bad policy / bad target | tool failure: nix or a scanner missing or failed (outranks 1), unwritable output; report incomplete |
| `diff` | computed (even when "not comparable") / `--gate` pass | `--gate` fail | usage (incl. `--gate`/`--today` without `--policy`) / bad snapshot | unwritable output; `--gate` **not evaluated** (incomplete side, not comparable, cross-host without `--allow-cross-host`) |

- Always read `policy.complete` / `incomplete`: exit 0 with `complete: false` is not clean, and `--no-scan` with finding rules is always incomplete (so gating two `--no-scan` snapshots is exit 3, not evaluated).
- `gate: pass` means "no new violations vs the baseline", not a strict pass; standing violations still count.
- Exit 3, a failed or stale scanner, or a missing scan section means **unknown coverage, never zero vulnerabilities**.
- `confirmed` = two scanners matched an advisory, not proven exploitable.
- Report with any verdict: `producer` (rev, dirty), `policy.source.sha256` (must equal `sha256sum` of the policy file), `scan.scanners[].outcome` (`status`, `tool_version`, `db_built`), offline mode, `policy.complete`, comparability and any `--allow-cross-host`.

## Feedback

A real bug or confusing output → `tooling-feedback`. CLI behaviour: `sammasak/nix-audit`, using its [FEEDBACK.md](https://github.com/sammasak/nix-audit/blob/main/docs/FEEDBACK.md) template and `jq` evidence extract. Packaging, PATH, pin: `sammasak/nixos-config` (public). Never file without authorization.
