# Adding a role by composition

A role is a contract plus thin adapters; its capabilities are devenv tasks that
other roles may share. Nothing here needs a new script runner.

1. **Contract** — `agents/<role>/ROLE.md` with frontmatter `name`, `version: 1`,
   `mission`, `skills` (existing `skills/*`), `tasks.read` / `tasks.run` /
   `tasks.act` / `tasks.inputless`, `forbidden`, `evidence`, `adapters`.
   `read` = no side effects beyond local state, `run` = runs something local
   (builds, gates), `act` = remote side effect (prompts in Claude; Codex has
   no prompt, so a role with act tasks is Claude-only until that changes). Every listed
   task must exist in `devenv tasks list`.
2. **Tasks** — reuse first (`gh:work`, `git:recent`, `herdr:*`,
   `quality:report` …). New ones go in `task-modules/<family>.nix` or
   `agents/<role>/tasks.nix`: `${cfg.prelude}` first, inputs via `input .key`,
   fleet checks via `${cfg.hostCase}` or a generated `case`, output through
   `emit` as record schema v1 (`{schema_version:1} + ctx + {...}`), failures
   as `fail <exit> <kind> <message> "$ctx"`. Remember devenv runs execs with
   errexit: no command may end a loop or pipeline with a non-zero status
   unless you mean to abort.
3. **Permissions** — `agents/<role>/permissions.json`: exact `Bash(devenv
   tasks run <inputless task>)` forms in `allow` (no wildcards), `ask` for act
   tasks, the shared deny list, `Read(./**)` plus `Read(~/.local/state/<role>/**)`.
4. **Guard** — nothing to write: the settings-level dispatcher routes by agent
   name to the `guard:check` task, and the role's `ROLE.md` task lists are the
   whole guard configuration.
5. **Adapters** — `agents/<role>.md` (Claude: `tools: [Bash, Read]`,
   `disallowedTools`, `permissionMode: default`, `skills:` = the contract's
   list, the fail-closed `hooks.PreToolUse` command) and
   `agents/<role>/AGENTS.md` (Codex: the contract pointer, the single allowed
   command form, and the harness differences spelled out).
6. **Tests** — fixture suite as a task in `agents/<role>/tests.nix` driving the real
   tasks with `--option coordinator.*` overrides; the contract and negative
   suites pick the role up automatically (the `skills:test:contract` task
   iterates `agents/*/ROLE.md`; add the role's allow/block cases to
   the `skills:test:negative` task).
7. **Host** — nothing to do: nixos-config `skills.nix` links every
   `agents/*.md` as a subagent, and the settings-level dispatcher
   (`hooks/role-guard-dispatch.sh`) picks the role up by name because
   `agents/<name>/ROLE.md` ships next to it. The name must match
   `^[a-z][a-z-]*$` (no digits or underscores), or the dispatcher will not
   recognise it. (`permissions.json` only matters for the optional hardened
   launcher mode in `nixos-config/docs/coordinator.md`.)

The quality role (`agents/quality/`) is the worked example: three existing
skills, two shared tasks, two new tasks, 26 fixture assertions, and the same
guard as the coordinator.
