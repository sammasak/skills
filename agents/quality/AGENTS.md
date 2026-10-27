# Quality role — Codex adapter

Codex has no per-agent definition files, preloaded skills or agent-scoped
hooks. This file is the whole adapter: pass it as the system context from the
skills checkout (`codex exec --cd "${SKILLS_CHECKOUT:-$HOME/claude-code-skills}"
--sandbox workspace-write "$(cat agents/quality/AGENTS.md)"$'\n\n'"<owner
request>"`), and register the same `hooks/validate-quality.sh` guard in a
dedicated `CODEX_HOME`'s `hooks.json` (never the user's global
`~/.codex/hooks.json`); `agents/quality/tests/two-harness.sh` shows the exact
invocation. Where Codex differs from Claude Code, the difference is noted here
instead of hidden.

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
  `.integrity` manifest the guard verifies on every call, in a session that
  exports `COORDINATOR_REQUIRE_INTEGRITY=1` and the manifest's pinned hash
  (nixos-config writes both at materialisation; the parity test writes them in
  its copy). Then editing or deleting a contract, task, hook, devenv or
  `devenv.local.*` file makes the guard refuse everything. The guard itself
  must run from a path the agent cannot write (nixos-config installs it from
  the store; the parity test runs it from a read-only copy outside the
  checkout and outside `/tmp`), otherwise an agent that can edit its own hook
  has no guard. The check happens at hook time; an edit racing between the
  check and the task's evaluation is not caught. Running Codex with `--sandbox workspace-write` on
  an unmanaged clone, or without the pin, is **not enforced** and must not be
  described as such; the `.devenv/` evaluation cache is not covered either.
- **Global hooks file.** `~/.codex/hooks.json` is per user, so a guard
  registered there applies to every Codex session on the host; use a dedicated
  `CODEX_HOME` for role sessions (hooks are a stable,
  default-on feature in codex-cli 0.162.1). Unverified until the Codex half of
  the parity run happens: the exact PreToolUse payload shape
  (`tool_input.command` as a string), how Codex treats `permissionDecision`,
  and whether a per-call working directory arrives as `tool_input.workdir`.
  The guard refuses any `workdir`, `cwd`, `working_directory` or
  `working_dir` field under `tool_input` that does not resolve to the
  checkout, because a planted `devenv.nix` in a new subdirectory is not caught
  by the manifest and would evaluate instead of the checkout's. The parity
  script ends each half with an enforcement probe: one form that looks
  compliant but only the guard's grammar rejects (the two flags in reverse
  order), run for Claude under probe-only settings that open its own
  permission layer for the task prefix so the guard is the only control. It
  reports ENFORCED when the guard log shows the refusal and the consumer saw no
  call the guard did not allow (a retry in the allowed form is not a leak),
  NOT ENFORCED when the form or an unallowed call reached the consumer (exit
  1), and UNVERIFIED when the harness never issued the form or did not run
  (exit 3). Because this file spells the grammar with ordered flags and says
  not to retry with variations, a compliant Codex may decline the reversed
  form; that yields UNVERIFIED, never a false ENFORCED.
- **The sandbox cannot write fleet checkouts.** `--sandbox workspace-write`
  lets the agent write the skills checkout (and the scratch root) only. A real
  `quality:report` enters the consumer's `devenv shell`, which writes
  `<checkout>/.devenv/`, and `quality:gate` builds and tests inside the
  consumer repo; both fail under Codex unless every fleet checkout is added
  with `-c sandbox_workspace_write.writable_roots=[…]`, which widens what the
  agent can edit. The parity run uses a fake devenv that never writes into the
  consumer repo, so an IDENTICAL verdict says nothing about this.
- **Sandbox scratch.** With `/tmp` and `$TMPDIR` excluded from the writable
  roots (so the agent cannot reach its own guard copy), the tasks still need
  somewhere to write (`mktemp` in `quality:report`, devenv's runtime dir); the
  parity script gives them one dedicated writable root and points `TMPDIR`,
  `DEVENV_RUNTIME` and `XDG_CACHE_HOME` at it. Whether the sandboxed shell inherits those variables
  is unverified until the first live run; the run reports INCOMPLETE rather
  than parity if it does not.
- **Skills are not preloaded**; read them as above.
- **Not yet run** on this fleet: Codex has no credentials on the test host, so
  the parity script skips it and says so.
