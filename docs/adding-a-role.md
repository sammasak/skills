# Adding a role by composition

A role is a contract plus a thin adapter; its capabilities are devenv tasks that
other roles may share. Nothing here needs a new script runner or a hook.

1. **Contract** — `agents/<role>/ROLE.md` with frontmatter `name`, `version: 1`,
   `mission`, `skills` (existing `skills/*`), `tasks.read` / `tasks.run` /
   `tasks.act`, `forbidden`, `evidence`, `adapters`.
   `read` = no side effects beyond local state, `run` = runs something local
   (builds, gates), `act` = remote side effect (the owner confirms first).
   Every listed task must exist in `devenv tasks list`.
2. **Tasks** — reuse first (`gh:work`, `git:recent`, `herdr:*`,
   `quality:report` …). New ones go in `task-modules/<family>.nix` or
   `agents/<role>/tasks.nix`: `${cfg.prelude}` first, inputs via `input .key`,
   machine labels checked with `valid_machine`, ids with `valid_id`, remote
   reads through `herdr_at <timeout> <machine-or-empty> <args…>`, output through
   `emit` as record schema v1 (`{schema_version:1} + ctx + {...}`), failures
   as `fail <exit> <kind> <message> "$ctx"`. Remember devenv runs execs with
   errexit: no command may end a loop or pipeline with a non-zero status
   unless you mean to abort.
3. **Adapter** — `agents/<role>.md` (Claude: `tools: [Bash, Read]`,
   `disallowedTools`, `permissionMode: default` so the owner is prompted,
   `skills:` = the contract's list, a short prompt that points at ROLE.md and
   spells out the single allowed command form). No hooks: the owner's
   permission prompt and the role prompt are the boundary.
4. **Tests** — fixture suite as a task in `agents/<role>/tests.nix` driving the real
   tasks with `--option coordinator.*` overrides; the contract suite picks the
   role up automatically (`skills:test:contract` iterates `agents/*/ROLE.md`).
5. **Host** — nothing to do: nixos-config `skills.nix` links every
   `agents/*.md` as a subagent on devTools hosts.

The quality role (`agents/quality/`) is the worked example: three existing
skills, two shared tasks, two new tasks and 26 fixture assertions.
