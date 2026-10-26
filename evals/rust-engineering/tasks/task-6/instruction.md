# Task: Can we skip tests because Factum found nothing?

A teammate ran the deterministic Factum CLI on a Rust change and pasted the tail of
`factum review --diff change.patch --format json`:

```json
{"schema":"facts-review/v3",
 "candidates":{"referencing":[],"unresolved":[],"dependent_only":[
   {"package":"ledger-sync"},{"package":"ledger-cli"},{"package":"ledger-web"}]},
 "unavailable":["compiler_semantics","feature_target_cfg","test_inventory"],
 "verification":{"status":"not_run"}}
```

They propose: "No package references the changed items, so we can skip the test suite and merge."
The repo uses the homelab devenv Rust gates.

Write `assessment.md`. Include a line `Skip tests: yes` or `Skip tests: no`, a short explanation
grounded in the fields above, and the exact command(s) that decide whether to merge.

Reply with only the file content as plain text, without code fences.
