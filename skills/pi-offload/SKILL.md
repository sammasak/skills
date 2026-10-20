---
name: pi-offload
description: "Use when a small, mechanical, machine-checkable task (lint or clippy fixes, adding tests, small refactors, repetitive edits) could be delegated to the free-tier Pi worker instead of spending your own context. Not for design, security-sensitive code, work without a check command, or durable issue-to-PR work (pi-ticket)."
allowed-tools: Bash, Read
---

# pi-offload

`pi-offload` runs the Pi worker through the homelab llm-gateway in a detached git worktree based on the source repo's `HEAD`. It loops until a check command passes and prints one JSON line with a patch. The source checkout is not modified by the worker.

Pi sees committed files at `HEAD`; uncommitted and untracked source-checkout changes are not copied into its worktree. Check `dirty_source` in the result. Commit prerequisite tests or other required inputs before dispatching, or Pi will not see them.

## Offload when

- The task is mechanical and small: lint/clippy fixes, adding tests for existing behaviour, renames, small refactors, repetitive edits.
- A crisp check command decides success (`cargo test -p X`, `cargo clippy -p X -- -D warnings`, `devenv tasks run ...`).

## Do not offload

- Design, architecture, or anything judgement-heavy.
- Security-sensitive code, secrets, or private code you would not send to a free Gemini tier (prompts leave the machine).
- Anything without a check command.

The free tiers are small (Gemini Flash 20 requests/day, Cloudflare 10k neurons/day, flash-lite 15 RPM) and shared by every host and project through the gateway: keep tasks small.

## How

```bash
pi-offload --repo . --task "Fix all clippy warnings in crate foo" --check "cargo clippy -p foo -- -D warnings" --via codex --issue owner/repo#12
# devenv repos: add --runner "devenv shell --"
```

Optional check-mode flags include `--rounds N`, `--check-timeout S`, `--model homelab/{auto|best|local}` (default `auto`), `--runner CMD`, and `--keep`. Provenance flags are `--via NAME`, `--issue REF`, and `--on-behalf-of TEXT`; Codex/Claude callers are detected when possible. Use these to identify the caller and related issue. The runner's [provenance documentation](https://github.com/sammasak/devenv-platform/blob/main/agents/pi/offload/README.md#who-ran-this-and-why) describes recorded fields and masking limits.

For a repository with a configured `platform.sdlc` machine, `--sdlc` uses its non-verdict stages as the check oracle instead of `--check`. Set `--runner "devenv shell --"` when needed. The loop stops at verdict stages for human review; it does not approve or complete them. If the machine is already green, the task may not be attempted and Pi can return an empty patch. Treat that as no implementation. Read the runner's [SDLC mode guide](https://github.com/sammasak/devenv-platform/blob/main/agents/pi/offload/README.md#sdlc-the-sdlc-machine-as-the-oracle) for stage boundaries, budgets, and failure modes. Use `pi-ticket` for durable issue-to-PR work.

Read ONLY the JSON on stdout (`status`, `rounds`, `patch`, `diffstat`, `added_files`, `dirty_source`, `check_timed_out`, `new_refs`, `summary`). Exit codes: 0 passed, 1 failed, 2 invalid, 70 error, 64 usage.

1. `passed`: the patch is a candidate, not a result. Review `patch` (`git apply --check <patch>`, then `git apply`), then run the repo's gate yourself.
2. `failed`: read `summary`. A 429 there means the gateway's free models are spent or cooling down (daily quotas reset at 00:00 UTC): do not rerun now; do the work yourself or wait. A timeout or other error may be an outage.
3. `invalid` or `error`: never trust the output; do the work yourself or fix the invocation.
4. `new_refs` and `moved_refs`: inspect refs Pi created or moved before deciding whether to keep them.
5. `dirty_source` or `check_timed_out` true: treat the result with suspicion and re-verify.
