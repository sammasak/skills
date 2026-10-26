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

Installed only where nixos-config enables it (Lenovo); the pinned build may predate `--json-out`, so branch on `--help`, not on the README. Current release candidate: CHANGELOG. Refuse a binary whose version ends `-dirty)` or `(unknown revision)` for any release claim. A Nix-packaged build prints `(<rev>, declared by the build)`: accept it only when the full `producer.revision` is the reviewed release commit, equals the config's locked `nix-audit` input, and `command -v nix-audit` resolves into that configuration (USER-GUIDE §1); do not build one just for an example (USER-GUIDE §1 if the pilot needs one).

## Run it safely

Inventory only (no scanners, no root, no vulnerability claim): `nix-audit scan /run/current-system --no-scan`. Full scans download databases and vulnix needs network: run them only when asked, under the host lock, with the same binary, scanners and policy (absolute path) on both sides.

```sh
L="flock /tmp/$(hostname)-heavy-work.lock"; P=/abs/path/policy.toml
rm -f current.json candidate.json                  # a usage error (exit 2) leaves an old file; the dir must be writable
$L nix-audit scan /run/current-system --policy "$P" --json-out current.json
$L nix-audit scan "$candidate"        --policy "$P" --json-out candidate.json
nix-audit diff current.json candidate.json --policy "$P"   # --gate only when asked
```

Capture each scan's exit with `|| rc=$?` and classify it as below on every build: `--json-out` (rc1 on) also writes a report on exit 3, under a name that looks complete. On a json-only build (no `--json-out` in `--help`) redirect `--json`, keep stderr out of the JSON (`2> X.err`, never `2>&1`) and capture the status with `|| rc=$?` (`if ! cmd; then rc=$?` records 0). Keep every report as private evidence: rename, never delete. Classify from the report itself; `scan.scanners[].outcome` exists on every build, the stderr reason line does not:

```sh
rc=0; $L nix-audit scan /run/current-system --policy "$P" --json > current.json 2> current.err || rc=$?
case $rc in
  0|1) ;;                                                  # complete report (1 = violations)
  3) if jq -e '[.scan.scanners[]? | select(.outcome.status == "failed")] as $f
         | ($f | length) == 1 and $f[0].scanner == "vulnix"
           and ($f[0].outcome.detail | startswith("vulnix failed: no local derivation"))
           and any(.scan.scanners[]; .scanner == "grype" and .outcome.status == "ran")' current.json >/dev/null 2>&1
     then mv current.json current.grype-only.json          # usable only for the grype-only route
     else mv current.json current.incomplete.json; fi ;;   # evidence, never gated
  *) mv current.json current.failed.json ;;                # usage/tool failure: keep, never gate
esac
```

Set aside only the side that failed. Rescanning just that side is valid only if the kept report has the same `producer.revision`, the same policy (`policy.source.sha256` from rc1 on; on `12d640a`, which has no hash, identical `policy.source.content`) and the same scanner selection, with those scanners `ran`; otherwise rescan both. A `.grype-only`, `.incomplete` or `.failed` snapshot is never a complete assessment.

## Interpret

- Exit 3, a failed or stale scanner, or a missing scan section means **unknown coverage, never zero vulnerabilities**. Exit 0 with `policy.complete: false` is not clean.
- Typed causes (`policy.incomplete_kinds[].kind`, diff `policy.gate.causes[].kind`) are newer than rc1: check they exist (`jq '.policy | has("incomplete_kinds")'`) and branch on `kind`, never on prose; otherwise use `policy.complete`/`incomplete` and `scan.scanners[].outcome` for a scan, and `policy.gate.result` plus the exit code for a diff (§7). Atomic `--json-out` is also post-rc1.
- A target built on another host often has no local `.drv`, so vulnix fails (exit 3); prefer the deploy build host (Lenovo), where derivations exist. Otherwise record the full gate's exit 3 first, then, only if grype `ran` on both sides, run the explicit `diff … --scanners grype --policy "$P"` and report it as grype-only; review any `findings after not compared` before calling an upgrade clean (§6).
- `gate: pass` = no new violations vs the baseline, not a strict pass. `confirmed` = two scanners matched, not proven exploitable.
- Report the binary revision, scanners and their outcomes, the policy identity (`policy.source.sha256`, or `bytes`/`path` on `12d640a`), `policy.complete` and comparability with any verdict (§7).

## Feedback

A real defect → `tooling-feedback`: CLI behaviour to `sammasak/nix-audit` (its `docs/FEEDBACK.md` template and `jq` extract); packaging, PATH or pin to `sammasak/nixos-config` (public). Never file without authorization.
