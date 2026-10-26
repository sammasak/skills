# Task: Snapshot two generations with the installed nix-audit

The current README says to snapshot with `--json-out FILE`. On this host:

```
$ nix-audit --version
nix-audit 0.1.0 (a1b2c3d4e5f6)
$ nix-audit scan --help
Usage: nix-audit scan [OPTIONS] <TARGET>
Options:
      --json             print the JSON report instead of the terminal summary
      --policy <FILE>    evaluate a nix-audit-policy/v0 file
      --scanners <LIST>  which scanners run [default: grype,vulnix]
      --no-scan          inventory only
      --offline          do not update scanner databases
  -h, --help             Print help
```

The candidate is already built at `$NEXT_GEN`. Write `snapshot.sh`: a bash script that
produces `gen-now.json` (from `/run/current-system`) and `gen-next.json` (from `$NEXT_GEN`)
with the policy file whose path is in `$AUDIT_POLICY`, ready for a later `nix-audit diff`. A snapshot from a
scan that could not complete must not be left looking like a usable one. Do not run a gate.
