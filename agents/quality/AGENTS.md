# Quality role — Codex adapter

Codex has no per-agent definition files, preloaded skills or agent-scoped
hooks. This file is the whole adapter: the launcher passes it as the system
context (`codex exec --cd "$COORDINATOR_CHECKOUT" --sandbox workspace-write
"$(cat agents/quality/AGENTS.md)"$'\n\n'"<owner request>"`), and the same
`hooks/validate-quality.sh` guard is registered in `~/.codex/hooks.json` by
nixos-config. Where Codex differs from Claude Code, the difference is noted
here instead of hidden.

## Contract

Read `agents/quality/ROLE.md` in this directory first and follow it exactly.
The skills it names live under `skills/sdlc-pipeline/SKILL.md`,
`skills/rust-engineering/SKILL.md` and `skills/orchestrated-review/SKILL.md`;
read the first one before your first task call, the others when the report
shows a Rust repo or a review stage.

## Allowed commands

Exactly one form, from this directory:

```
devenv tasks run <task> [--input-json '<json object>'] [--show-output]
```

with `<task>` one of `quality:report`, `quality:gate`, `gh:work`,
`git:recent`. Nothing else: no `cargo`, `git`, `gh`, `ssh`, no file edits, no
chaining. A blocked command means the guard refused it; report that, do not
retry with a variation.

## Differences from the Claude adapter

- No permission prompt exists in `codex exec`; the guard either allows or
  blocks. This role has no act-class task, so nothing needs a prompt.
- Skills are not preloaded; read them with your file-reading tool as above.
- The guard reads `tool_input.command` and `cwd` from the hook input; the
  nixos-config launcher sets `COORDINATOR_CHECKOUT` so the cwd check holds.
