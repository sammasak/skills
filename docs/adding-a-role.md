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
4. **Guard** — `hooks/validate-<role>.sh` is two lines:
   `ROLE=<role> exec "$(dirname "$(readlink -f "$0")")/validate-role.sh"`.
5. **Adapters** — `agents/<role>.md` (Claude: `tools: [Bash, Read]`,
   `disallowedTools`, `permissionMode: default`, `skills:` = the contract's
   list, the fail-closed `hooks.PreToolUse` command) and
   `agents/<role>/AGENTS.md` (Codex: the contract pointer, the single allowed
   command form, and the harness differences spelled out).
6. **Tests** — fixture suite under `agents/<role>/tests/` driving the real
   tasks with `--option coordinator.*` overrides; the contract and negative
   suites pick the role up automatically (`tests/test-role-contract.sh`
   iterates `agents/*/ROLE.md`; add the role's allow/block cases to
   `tests/test-coordinator-negative.sh`).
7. **Host** — nixos-config renders the role's `permissions.json` into a
   launcher settings file and links the guard; see
   `nixos-config/docs/coordinator.md` for the pattern.

The quality role (`agents/quality/`) is the worked example: three existing
skills, two shared tasks, two new tasks, 26 fixture assertions, and the same
guard as the coordinator.
