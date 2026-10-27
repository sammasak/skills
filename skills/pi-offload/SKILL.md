---
name: pi-offload
description: "Use when a small, mechanical, machine-checkable task (lint or clippy fixes, adding tests, small refactors, repetitive edits) could be delegated to the free-tier Pi worker instead of spending your own context, or when deciding what a pi-offload result (status, dirty source, patch) means before applying it. Not for design, security-sensitive code, work without a check command, or durable issue-to-PR work (pi-ticket)."
allowed-tools: Bash, Read
---

# pi-offload

`pi-offload` runs the Pi worker through the homelab llm-gateway in a detached git worktree based on the source repo's `HEAD`. It loops until a check command passes and prints one JSON line with a patch. The source checkout is not modified by the worker.

Pi sees committed files at `HEAD`; uncommitted and untracked source-checkout changes are not copied into its worktree. Check `dirty_source` in the result. Commit prerequisite tests or other required inputs before dispatching, or Pi will not see them.

## Offload when

- The task is mechanical and small: lint/clippy fixes, adding tests for existing behaviour, renames, small refactors, repetitive edits.
- A crisp check command decides success (`cargo test -p X`, `cargo clippy -p X -- -D warnings`, `devenv tasks run ...`).

Use Pi when the expected iteration or verification savings justify its context and latency; do trivial edits locally. A one-round budget limits retries, not tokens: even a seven-line Herman test patch used 78,469 tokens over 88 seconds. Check `pi-view` results periodically, and do not describe free-tier inference as zero-cost.

## Do not offload

- Design, architecture, or anything judgement-heavy.
- Security-sensitive code, secrets, or private code you would not send to a free tier: prompts leave the machine, and free-tier Gemini prompts may be used by Google.
- Anything without a check command.

Free quotas are per model, shared by every host and project through the gateway, and change often; current limits are in nixos-config `docs/pi.md`. Keep tasks small.

For a Rust failure, put only the relevant findings in `--task` (Factum evidence per `rust-engineering`, matching what Pi sees at `HEAD`), never a whole build log or test inventory.

## How

```bash
pi-offload --repo . --task "Fix all clippy warnings in crate foo" --check "cargo clippy -p foo -- -D warnings"
# devenv repos: add --runner "devenv shell --"
# Add --issue REAL_REPO#N only for a real linked issue; use --via only if auto-detection is insufficient.
```

Optional check-mode flags include `--rounds N`, `--check-timeout S`, `--model homelab/{auto|best|local}` (default `auto`), `--runner CMD`, and `--keep` (keeps `pi.err`/`check.log`, which may echo secrets: do not share the run dir). Provenance flags are `--via NAME`, `--issue REF`, and `--on-behalf-of TEXT`; Codex/Claude callers are detected when possible. Use these to identify the caller and related issue. The runner's [provenance documentation](https://github.com/sammasak/devenv-platform/blob/main/agents/pi/offload/README.md#who-ran-this-and-why) describes recorded fields and masking limits.

For a repository with a configured `platform.sdlc` machine, `--sdlc` uses its non-verdict stages as the check oracle instead of `--check`. Set `--runner "devenv shell --"` when needed. The loop stops at verdict stages for human review; it does not approve or complete them. If the machine is already green, the task may not be attempted and Pi can return an empty patch. Treat that as no implementation. Read the runner's [SDLC mode guide](https://github.com/sammasak/devenv-platform/blob/main/agents/pi/offload/README.md#sdlc-the-sdlc-machine-as-the-oracle) for stage boundaries, budgets, and failure modes. Use `pi-ticket` for durable issue-to-PR work.

Before dispatch: `git status --porcelain` (Pi sees only `HEAD`) and `git rev-parse HEAD`. Read ONLY the JSON on stdout (`status`, `rounds`, `patch`, `diffstat`, `added_files`, `dirty_source`, `check_timed_out`, `new_refs`, `moved_refs`, `summary`). Exit codes: 0 passed, 1 failed, 2 invalid, 70 error, 64 usage (via a `pi:*` devenv task every non-zero collapses to 1; trust `status`).

1. `passed`: the patch is a candidate, not a result. Read `patch`, `git apply --check` it against the same `HEAD`, apply, then run the repo's authoritative gate yourself.
2. `failed`: read `summary`. A 429 there means the gateway's free models are spent or cooling down (daily quotas reset at 00:00 UTC): do not rerun now; do the work yourself or wait. A timeout or other error may be an outage.
3. `invalid` (check passed but the diff is empty) or `error`: never trust the output; do the work yourself or fix the invocation.
4. `new_refs` and `moved_refs`: inspect refs Pi created or moved before deciding whether to keep them.
5. `dirty_source` or `check_timed_out` true: treat the result with suspicion and re-verify.
