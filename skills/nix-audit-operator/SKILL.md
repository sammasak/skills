---
name: nix-audit-operator
description: "Use when running, interpreting, or safely dogfooding nix-audit on a built NixOS closure, comparing running and candidate generations, or checking an incomplete vulnerability scan. Not for flake development or creating a bug report (use tooling-feedback)."
allowed-tools: Bash, Read
---

# nix-audit operator

Authority: nix-audit's [USER-GUIDE](https://github.com/sammasak/nix-audit/blob/main/docs/USER-GUIDE.md) and [PILOT](https://github.com/sammasak/nix-audit/blob/main/docs/PILOT.md) for the revision you run (exit codes: USER-GUIDE §4 scan, §5 diff; hosts built elsewhere §6; provenance §7; troubleshooting §8; changes: CHANGELOG). This skill is the safe entrypoint, not a copy.

**Status:** advisory, report-only pilot. #32 is closed, but automatic enforcement stays **off**: never add `--gate` to a rebuild, deploy or CI path; blocking integration needs a separate owner decision. A manual `diff … --gate` is evidence to report, not approval.

## Find the binary first

```sh
command -v nix-audit && nix-audit --version        # nix-audit 0.1.0 (<12-char rev>)
nix-audit scan --help | grep -q -- --json-out && echo json-out || echo json-only
```

Installed only where nixos-config enables it (Lenovo); the pinned build may predate `--json-out`, so branch on `--help`, not on the README. Current release candidate: CHANGELOG. Refuse a binary whose version ends `-dirty)` or `(unknown revision)` for any release claim; do not build one just for an example (USER-GUIDE §1 if the pilot needs one).

## Run it safely

Inventory only (no scanners, no root, no vulnerability claim): `nix-audit scan /run/current-system --no-scan`. Full scans download databases and vulnix needs network: run them only when asked, under the host lock, with the same binary, scanners and policy (absolute path) on both sides.

```sh
L="flock /tmp/$(hostname)-heavy-work.lock"; P=/abs/path/policy.toml
rm -f current.json candidate.json                  # a usage error (exit 2) leaves an old file
$L nix-audit scan /run/current-system --policy "$P" --json-out current.json
$L nix-audit scan "$candidate"        --policy "$P" --json-out candidate.json
nix-audit diff current.json candidate.json --policy "$P"   # --gate only when asked
```

On a json-only build (no `--json-out` in `--help`) redirect `--json` and act on the exit code; exit 1 is still a valid report, exit 3 is incomplete evidence, never a snapshot to gate:

```sh
rc=0; $L nix-audit scan /run/current-system --policy "$P" --json > current.json || rc=$?   # stdout only
case $rc in 0|1) ;; 3) mv current.json current.incomplete.json ;; *) rm -f current.json ;; esac
```

## Interpret

- Exit 3, a failed or stale scanner, or a missing scan section means **unknown coverage, never zero vulnerabilities**. Exit 0 with `policy.complete: false` is not clean.
- A target built on another host often has no local `.drv`, so vulnix fails (exit 3). The documented fallback is an explicit `--scanners grype` comparison, reported as grype-only; review any `findings after not compared` before calling an upgrade clean (§6).
- `gate: pass` = no new violations vs the baseline, not a strict pass. `confirmed` = two scanners matched, not proven exploitable.
- Report the binary revision, scanners and their outcomes, `policy.source.sha256`, `policy.complete` and comparability with any verdict (§7).

## Feedback

A real defect → `tooling-feedback`: CLI behaviour to `sammasak/nix-audit` (its `docs/FEEDBACK.md` template and `jq` extract); packaging, PATH or pin to `sammasak/nixos-config` (public). Never file without authorization.
