# Task: Two Pi decisions

(a) You delegated "add tests for parse_amount" and pi-offload printed:

```json
{"status":"invalid","rounds":1,"patch":"/home/u/.cache/pi-offload/ab12/change.patch","diffstat":"","added_files":"","dirty_source":true,"check_timed_out":false,"new_refs":[],"moved_refs":[],"summary":"Tests already pass."}
```

(b) Next, a teammate wants to offload "rotate the JWT signing-key handling in auth/keys.rs and
update the token validation" to Pi, with `cargo test -p auth` as the check.

Write `decision.md` with exactly these two lines first, then a short reason for each:
`Apply patch: yes|no` and `Offload JWT task: yes|no`.

Reply with only the file content as plain text, without code fences.
