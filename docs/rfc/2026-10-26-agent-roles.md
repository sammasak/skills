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
| **Adapter** | `agents/<role>.md` (Claude), `agents/<role>/AGENTS.md` (Codex) | Thin harness-specific file that points at ROLE.md, preloads the role's skills and restricts tools to what the harness supports. | A second copy of the role logic. |
| **Guard** | `task-modules/guard.nix` (`guard:check`, `guard:integrity`) behind `hooks/role-guard-dispatch.sh` | PreToolUse(Bash) hook wired in the Claude adapter's frontmatter, so it applies only when that agent runs; resolved from the skills checkout (`$SKILLS_CHECKOUT`, default `~/claude-code-skills`). The authority for allowing a call: one strict grammar (`[cd <checkout> && ]devenv tasks run <task> [--input-json '<object>'] [--show-output]`), exactly one JSON object as body, the call run from or `cd`-ed into exactly the checkout, every per-call working-directory field equal to it, and (hardened mode only) the checkout's `.integrity` manifest intact (the `integrity_check` function in `task-modules/guard.nix` (also the `guard:integrity` task)); returns `allow` for read tasks, `ask` for act tasks, blocks everything else. | An OS boundary. |
| **Permissions** | `agents/<role>/permissions.json` | Settings rules for the optional hardened (launcher) mode: exact input-less forms allowed, act form `ask`, denies for `-O`/`--option`/`--from`/`--override-input`, Edit/Write, and `Read` of key, token and secret paths. Not needed for subagent use, where the owner's session rules apply. | Enforced in subagent mode. |
| **Host install** | nixos-config `skills.nix` | Links every `agents/*.md` into `~/.claude/agents` on devTools hosts; the owner keeps one writable skills checkout for the tasks. The hardened launcher module (`sam.profile.coordinator`) was removed on 2026-10-27 with the herdr-native rework (#25); workers are Herdr saved machines (`sam.herdr.machines` on the coordinator host). | Part of this repo. |

## Operation classes

- **read**: no side effects beyond local state under `$XDG_STATE_HOME/coordinator`. Allowed without prompting. Includes bounded waits (`herdr:await`) and local drafts (`coord:handoff`).
- **act**: a remote side effect (today only `herdr:message`). Never allowlisted; the guard returns `ask` and the harness permission prompt is the human gate, plus an audit record and duplicate detection inside the task.
- **privileged**: merge, deploy, switch, tag, secrets, delete, arbitrary ssh. No role may list these; the negative test suite asserts the allowlist cannot express them.

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

## Guard placement (verified live 2026-10-26 and 2026-10-27)

Two facts fix where the guard must live:

- **Main session** (`claude --agent <role>`): a PreToolUse `allow` from the
  agent-frontmatter hook is not honoured (every Bash call stayed at the
  permission prompt in print mode); a settings-level hook is. A frontmatter
  hook's *block* does fire here.
- **Subagent** (the normal use: "ask the coordinator …" from any session): the
  agent-frontmatter hooks are **not run at all** (an always-block hook never
  fired; the subagent's command ran). A settings-level PreToolUse hook does
  run, and its input carries `agent_type` and `agent_id`.

So the guard is a settings-level hook, `hooks/role-guard-dispatch.sh`, installed
by nixos-config next to the other user-scope hooks: it reads `agent_type`,
and when that role ships next to it (`agents/<agent_type>/ROLE.md` in the
installed copy) or is present in the skills checkout, it decides through the
guard library (`task-modules/guard-lib.nix`): the store-built binary nixos-config
hands over as `ROLE_GUARD_BIN`, or, where none is installed (Codex, unmanaged
main sessions), the checkout's own `guard:check` task, which then trusts the
checkout; a shipped role whose checkout lacks the contract is refused; for every
other agent and for the main session it is a silent no-op. The frontmatter hook in each adapter stays as the
main-session backstop. Installing this repo as a Claude Code plugin loads the
adapters without that settings hook, so a plugin-installed role is unguarded
unless the dispatcher is registered separately; the nixos-config install path
is the supported one.

## Adapters

Claude today (`agents/<role>.md`: tools, `permissionMode: default`, preloaded
skills, the guard hook). Codex: `agents/<role>/AGENTS.md`; its harness has no
per-agent hook, so the same guard is registered in a dedicated `CODEX_HOME`'s
`hooks.json` and the limitations are recorded, not hidden.

## Claude Code permission gotchas (verified against docs 2026-10-26)

- Rules live in settings, not in agent files; agent files only restrict tools.
- `Bash(x:*)` means `x *` (a space is required), so a rule ending in a task
  name such as `coord:brief:*` would never match the task. Do not use prefix
  globs for tasks at all (next bullet); list exact forms.
- Deny and ask beat allow for any subcommand, including `$(...)`; allow needs
  every subcommand of a compound to match. Matching is textual, so these
  rules are guardrails; the OS-level boundary is nixos-config's job.
- `devenv tasks run` accepts several task names and `-O`/`--option` overrides
  that replace a task's `exec`, so any rule with a wildcard after the task
  name (`coord:brief*`, `--input-json *`) allows arbitrary code. Settings
  rules therefore list only exact input-less forms and deny `-O`, `--option`,
  `--from`, `--override-input`; every call that carries input is allowed only
  by the guard hook, which returns `allow` after validating the grammar, the
  JSON body and the working directory. Both the dispatcher and the adapter's
  hook command refuse every role-agent Bash call when the skills checkout or
  the guard is missing (fail closed).
- `Read(~/...)` and `Read(./**)` rules are checked as rule text; the emulator
  does not expand `~` or `./`. The launcher renders the real state directory
  (`$XDG_STATE_HOME/coordinator`) in place of the portable default.
- The test matcher (`tests/lib/claude-permission-match.sh`) is deliberately
  stricter than Claude Code in two places: it never auto-allows a command with
  substitutions or redirections, and it splits on separators without quote
  awareness. Both only make the suite report `none` where the real matcher
  might allow; they never report `allow` where it would prompt.
