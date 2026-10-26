# Task: Is this repo's pipeline green?

In a repo whose devenv enables `platform.sdlc`:

```
$ devenv shell -q -- sdlc-status --context; echo "exit=$?"
SDLC machine: billing -- migrate (unverified) -- not yet verified

### Current stage brief (migrate)

Replay migrations against disposable PostgreSQL.
exit=0
$ devenv shell -q -- sh -c 'jq -c .order "$SDLC_MACHINE"'
["migrate","contract","e2e"]
```

A release script asks: "sdlc-status exited 0 — is the pipeline green?"

Write `status.md` with a line `Green: yes` or `Green: no`, one sentence why, the stages that must
pass for this repo, and the single command whose exit code actually decides.

Reply with only the file content as plain text, without code fences.
