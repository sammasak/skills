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

## Differences from the Claude adapter (recorded, not hidden)

- **No permission prompt** in `codex exec`: the guard either allows or blocks.
  This role has no act-class task, so nothing needs a prompt; a role with act
  tasks cannot run under Codex until Codex can ask.
- **No edit denial.** Claude denies Edit/Write; Codex's patch tool is not
  covered by a Bash hook. Codex must therefore run against a checkout whose
  `.integrity` manifest the guard verifies on every call (nixos-config writes
  it at materialisation; the parity test writes it in its copy): editing a
  contract, task, hook or devenv file makes the guard refuse everything.
  Running Codex with `--sandbox workspace-write` on an unmanaged clone is
  **not enforced** and must not be described as such.
- **Global hooks file.** `~/.codex/hooks.json` is per user, so a guard
  registered there applies to every Codex session on the host; the launcher
  has to use a dedicated `CODEX_HOME` for role sessions. Unverified until the
  Codex half of the parity run happens: the exact PreToolUse payload shape
  (`tool_input.command` as a string) and how Codex treats
  `permissionDecision`.
- **Skills are not preloaded**; read them as above.
- **Not yet run** on this fleet: Codex has no credentials on the test host, so
  the parity script skips it and says so.
