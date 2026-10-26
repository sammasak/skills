# RFC: harness-agnostic agent roles (epic #16)

Status: accepted for implementation, 2026-10-26. Owner decision pending on
fleet-wide rollout via `just bump skills`.

## Terms

| Term | Lives in | Is | Is not |
|---|---|---|---|
| **Role** | `agents/<role>/ROLE.md` | Portable contract: mission, assigned skills, allowed task names split into `read` and `act`, forbidden operations, evidence rules, adapters. YAML frontmatter is machine-read by tests; prose is read by the agent. | A runtime boundary. |
| **Skill** | `skills/<name>/SKILL.md` | Short "when and how" instructions, Agent Skills compatible; may name tasks and scripts. | A copy of a task's implementation. |
| **Task** | `task-modules/bin/<name>` + `task-modules/<family>.nix` | Deterministic executable with versioned JSON output, bounded runtime, documented exit codes, tested with fixtures and no LLM. Wrapped by a devenv task of the same name. | Something only an LLM can run. |
| **DAG** | `agents/<role>/tasks.nix` | Native devenv `after` edges composing shared tasks with role tasks; `@completed` where a partial result is still useful, with failures surfaced in the output. | A scheduler, queue or state machine. |
| **Adapter** | `agents/<role>.md` (Claude), `agents/<role>/AGENTS.md` (Codex) | Thin harness-specific file that points at ROLE.md, preloads the role's skills and restricts tools to what the harness supports. | A second copy of the role logic. |
| **Permissions** | `agents/<role>/permissions.json` | Portable allow/ask/deny rules for the role's task surface. Rendered into host settings by nixos-config; checked by negative tests. | Enforced by the skills repo itself. |

## Operation classes

- **read**: no side effects beyond local state under `$XDG_STATE_HOME/coordinator`. Allowed without prompting. Includes bounded waits.
- **act**: a remote side effect (today only `herdr:message`). Never allowlisted; the harness permission prompt is the human gate, plus an audit record and duplicate detection inside the task.
- **privileged**: merge, deploy, switch, tag, secrets, delete, arbitrary ssh. No role may list these; the negative test suite asserts the allowlist cannot express them.

## Record schema v1

Every task writes one JSON document to stdout and, under devenv, to
`$DEVENV_TASK_OUTPUT_FILE`:

```json
{"schema_version":1,"task":"herdr:inventory","observed_at":"2026-10-26T15:00:00Z",
 "error":null, "...task specific fields..."}
```

Per-agent records inside task output carry: `host`, `server`, `agent_id`,
`harness`, `observed_state` (Herdr state verbatim), `observed_at`,
`state_age_s`, `stale`, `task_ref`, `evidence_ref`, `approval_required`,
`error` (`null` or `{"kind": "...", "message": "..."}`).

Exit codes: `0` result (possibly partial, see `partial`), `2` nothing usable
(all sources failed, not found), `3` invalid input (bad id, host not in fleet,
malformed JSON), `64` not implemented.

## Fleet configuration

`$XDG_CONFIG_HOME/coordinator/fleet.json` (override: `COORDINATOR_FLEET`),
installed by nixos-config, never committed here:

```json
{"schema_version":1,
 "hosts":[{"name":"acer-swift","ssh":null},{"name":"lenovo","ssh":"lukas@192.168.10.154"}],
 "repos":[{"name":"skills","gh":"sammasak/skills","checkout":"/home/lukas/skills-epic16"}]}
```

`ssh: null` means local. Only hosts and checkouts listed here are ever
touched; identifiers are validated against `^[A-Za-z0-9_:.@/-]+$` before use
and passed as separate argv words, never interpolated into a shell string.

## Claude Code permission gotchas (verified against docs 2026-10-26)

- Rules live in settings, not in agent files; agent files only restrict tools.
- `Bash(x:*)` means `x *` (a space is required), so a task named `coord:brief`
  must be allowlisted as `Bash(devenv tasks run coord:brief*)`.
- Deny and ask beat allow for any subcommand, including `$(...)`; allow needs
  every subcommand of a compound to match. Matching is textual, so these
  rules are guardrails; the OS-level boundary is nixos-config's job.
