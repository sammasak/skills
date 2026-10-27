# RFC: harness-agnostic agent roles (epic #16)

Status: accepted for implementation, 2026-10-26. Reworked herdr-native on
2026-10-27 (#25): no fleet file, hosts are Herdr saved machines.

## Terms

| Term | Lives in | Is | Is not |
|---|---|---|---|
| **Role** | `agents/<role>/ROLE.md` | Portable contract: mission, assigned skills, allowed task names split into `read` and `act`, forbidden operations, evidence rules, adapters. YAML frontmatter is machine-read by tests; prose is read by the agent. | A runtime boundary. |
| **Skill** | `skills/<name>/SKILL.md` | Short "when and how" instructions, Agent Skills compatible; may name tasks and scripts. | A copy of a task's implementation. |
| **Task** | `task-modules/<family>.nix` | A devenv task: `exec` holds the logic (shared helpers sourced from the Nix-held prelude in `task-modules/common.nix`), `input` declares its parameters, output goes to `$DEVENV_TASK_OUTPUT_FILE` as versioned JSON, bounded runtime, documented exit codes, tested by running the task against fixtures with no LLM. | A standalone CLI or a devenv `scripts` entry. |
| **DAG** | `task-modules/*.nix`, `agents/<role>/tasks.nix` | Native devenv `after` edges. `herdr:inventory` is one task that asks this host's Herdr server and, at run time, each enabled saved machine (`herdr --machine <label> agent list`); `work:status` depends on `herdr:inventory@completed`, reads `DEVENV_TASKS_OUTPUTS` and fetches GitHub evidence per agent; `coord:brief` renders it. Evidence tasks take one repo or checkout per call. | A scheduler, queue, state machine or host registry. |
| **Adapter** | `agents/<role>.md` (Claude) | Thin harness file that points at ROLE.md, preloads the role's skills, restricts tools to Bash and Read, keeps `permissionMode: default` so the owner is prompted, and states the one allowed command form. | A second copy of the role logic, or an enforcement hook (dropped 2026-10-27 on the owner's call: "just prompt and be clear about its role"). |
| **Host install** | nixos-config `skills.nix` | Links every `agents/*.md` into `~/.claude/agents` on devTools hosts; the owner keeps one writable skills checkout for the tasks; the coordinator host saves its workers as Herdr machines (`sam.herdr.machines`). | A launcher, a materialised copy, an integrity pin or a hook (all removed 2026-10-27). |

## Operation classes

- **read**: no side effects beyond local state under `$XDG_STATE_HOME/coordinator`. Allowed without prompting. Includes bounded waits (`herdr:await`) and local drafts (`coord:handoff`).
- **act**: a remote side effect (today `herdr:message`, and Herdr's own `agent prompt`). The owner confirms the draft in the conversation and Claude Code's permission prompt is the human gate, plus an audit record and duplicate detection inside the task.
- **privileged**: merge, deploy, switch, tag, secrets, delete, arbitrary ssh. No role lists these; the role prompt names them as out of scope and the owner's prompt refuses them.

## Record schema v1

Every task writes one JSON document to stdout and, under devenv, to
`$DEVENV_TASK_OUTPUT_FILE`:

```json
{"schema_version":1,"task":"herdr:inventory","observed_at":"2026-10-26T15:00:00Z",
 "error":null, "...task specific fields..."}
```

Per-agent records inside task output carry: `host`, `machine` (saved Herdr
machine label, `null` for this host), `agent_id`, `harness`, `session_id`,
`cwd`, `title`, `observed_state` (Herdr state verbatim), `observed_at`,
`state_change_seq` (Herdr's counter; movement shows as a change between two
reads), `task_ref`, `evidence_ref`, `approval_required`, `error` (`null` or
`{"kind": "...", "message": "..."}`). Host records carry `host`, `machine`,
`reachable`, `error`, `agents`.

Composite outputs (`work:status`, `coord:brief`) add per item `herdr_state`
(copy of `observed_state`), `work_verdict` (`verified|unverified|blocked|unknown`,
derived only from GitHub/git evidence), `needs_owner`, `reasons`, `sources`;
and at top level `partial` with `failed_sources` whenever an upstream task
errored. Herdr state never changes `work_verdict`.

Exit codes: `0` result (possibly partial, see `partial`), `2` nothing usable
(all sources failed, not found), `3` invalid input (unsafe id or machine label,
malformed JSON), `64` not implemented.

## Machines (herdr-native, 2026-10-27)

There is no fleet file and no host registry in this repo or in nixos-config.
Herdr is the only abstraction: this host's agents come from its own server,
other hosts are Herdr **saved machines** (`herdr machine add <ssh-target>
--label <name>`, stored by Herdr in `~/.local/state/herdr/client/endpoints.json`)
and are read through Herdr's command forwarding (`herdr --machine <label> …`).
A worker has no saved machines and therefore sees itself only; the coordinator
host sees every enabled machine. nixos-config declares the coordinator host's
machines (`sam.herdr.machines`) and runs `herdr machine add` idempotently at
activation; workers declare nothing.

`herdr:inventory` reads `herdr machine list --json` at run time and asks each
enabled machine in turn, under one bounded timeout each; a failing machine is a
host record with `reachable: false` and an `error`, a failing `machine list` is
`machines_error`, and both set `partial`. Labels are validated against
`^[A-Za-z0-9_][A-Za-z0-9_.-]*$` and runtime identifiers (agent ids, session
ids) again before use; every value is passed to Herdr as a separate argv word,
never through a shell. The ssh transport, forced-command shim, snapshots and
`state_age_s` of the earlier design are gone. Tests point
`coordinator.herdrCommand` at a fake with `--option
coordinator.herdrCommand:string`; devenv's evaluation cache ignores environment
variables, so there is no env override.

## Boundaries (owner decision 2026-10-27)

There is no enforcement hook. The owner's call, verbatim: "We should just
prompt and be clear about its role. We dont need full on guards for this."
A role's boundary is therefore its contract (`ROLE.md`), the adapter prompt
that states the one allowed command form, `permissionMode: default` so Claude
Code asks the owner before every Bash call that is not already allowed by the
owner's own settings, and the tasks themselves (which validate every input and
refuse unsafe identifiers). The earlier guard library, dispatcher hook,
integrity manifest, launcher and permissions files were removed with this
decision; their history is in git before 2026-10-27.

## Adapters

Claude only (`agents/<role>.md`: tools, `permissionMode: default`, preloaded
skills, a short prompt naming the one allowed command form). The Codex
adapter was dropped with the owner's "Drop the Codex requirement" (2026-10-27).

## Claude Code permission gotchas (verified against docs 2026-10-26)

- Rules live in settings, not in agent files; agent files only restrict tools.
- `Bash(x:*)` means `x *` (a space is required), so a rule ending in a task
  name such as `coord:brief:*` would never match the task. Do not use prefix
  globs for tasks at all (next bullet); list exact forms.
- Deny and ask beat allow for any subcommand, including `$(...)`; allow needs
  every subcommand of a compound to match. Matching is textual.
- `devenv tasks run` accepts several task names and `-O`/`--option` overrides
  that replace a task's `exec`, so a settings rule with a wildcard after the
  task name (`coord:brief*`, `--input-json *`) would allow arbitrary code. If
  you allowlist anything in your own settings, list exact input-less forms
  only; calls that carry input stay behind the permission prompt.
- `Read(~/...)` and `Read(./**)` rules are checked as rule text; the emulator
  does not expand `~` or `./`.
