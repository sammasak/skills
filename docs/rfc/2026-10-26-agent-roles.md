# RFC: harness-agnostic agent roles (epic #16)

Status: accepted for implementation, 2026-10-26. Owner decision pending on
fleet-wide rollout via `just bump skills`.

## Terms

| Term | Lives in | Is | Is not |
|---|---|---|---|
| **Role** | `agents/<role>/ROLE.md` | Portable contract: mission, assigned skills, allowed task names split into `read` and `act`, forbidden operations, evidence rules, adapters. YAML frontmatter is machine-read by tests; prose is read by the agent. | A runtime boundary. |
| **Skill** | `skills/<name>/SKILL.md` | Short "when and how" instructions, Agent Skills compatible; may name tasks and scripts. | A copy of a task's implementation. |
| **Task** | `task-modules/<family>.nix` | A devenv task: `exec` holds the logic (shared helpers sourced from `task-modules/lib.sh`), `input` declares its parameters, output goes to `$DEVENV_TASK_OUTPUT_FILE` as versioned JSON, bounded runtime, documented exit codes, tested by running the task against fixtures with no LLM. | A standalone CLI or a devenv `scripts` entry. |
| **DAG** | `task-modules/*.nix`, `agents/<role>/tasks.nix` | Native devenv `after` edges. Fan-out is generated at eval time from `fleet.json` (one `herdr:list:<host>`, `gh:work:<repo>`, `git:recent:<repo>` per entry); aggregators depend on `<task>@completed`, read `DEVENV_TASKS_OUTPUTS`, and list every expected upstream that is missing as a failed source. | A scheduler, queue or state machine. |
| **Adapter** | `agents/<role>.md` (Claude), `agents/<role>/AGENTS.md` (Codex) | Thin harness-specific file that points at ROLE.md, preloads the role's skills and restricts tools to what the harness supports. | A second copy of the role logic. |
| **Guard** | `hooks/validate-<role>.sh` | PreToolUse(Bash) hook wired in the Claude adapter's frontmatter, so it applies only when that agent runs. The authority for allowing a call: one strict grammar (`devenv tasks run <task> [--input-json '<object>'] [--show-output]`), exactly one JSON object as body, cwd equal to `$COORDINATOR_CHECKOUT`; returns `allow` for read tasks, `ask` for act tasks, blocks everything else. | An OS boundary. |
| **Permissions** | `agents/<role>/permissions.json` | Fallback settings rules: exact input-less forms allowed, act form `ask`, denies for `-O`/`--option`/`--from`/`--override-input`, Edit/Write, and `Read` of key, token and secret paths. Rendered by nixos-config into a settings file that the role's launcher passes with `--settings`, so the rules never leak into other agents' sessions. | Enforced by the skills repo itself, or sufficient on its own. |
| **Launcher** | nixos-config (M3) | Installs the guard at `~/.claude/hooks/validate-<role>.sh`, exports `COORDINATOR_CHECKOUT`, scopes `Read` to that checkout plus `$XDG_STATE_HOME/coordinator` in the rendered settings, and starts `claude --agent <role> --settings <file>` from the checkout. | Part of this repo. |

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

Per-agent records inside task output carry: `host`, `server`, `agent_id`,
`harness`, `session_id`, `observed_state` (Herdr state verbatim), `observed_at`,
`state_age_s` (seconds `state_change_seq` has been unchanged), `stale` (true
when served from a snapshot rather than a live read; `snapshot_at` then says
when), `task_ref`, `evidence_ref`, `approval_required`, `error` (`null` or
`{"kind": "...", "message": "..."}`).

Composite outputs (`work:status`, `coord:brief`) add per item `herdr_state`
(copy of `observed_state`), `work_verdict` (`verified|unverified|blocked|unknown`,
derived only from GitHub/git evidence), `needs_owner`, `reasons`, `sources`;
and at top level `partial` with `failed_sources` whenever an upstream task
errored. Herdr state never changes `work_verdict`.

Exit codes: `0` result (possibly partial, see `partial`), `2` nothing usable
(all sources failed, not found), `3` invalid input (bad id, host not in fleet,
malformed JSON), `64` not implemented.

## Fleet configuration

`$XDG_CONFIG_HOME/coordinator/fleet.json`, installed by nixos-config, never
committed here (tests and other locations use `--option coordinator.fleetFile:path`;
devenv's evaluation cache ignores environment variables, so there is no env override):

```json
{"schema_version":1,
 "hosts":[{"name":"this-host","ssh":null},{"name":"worker-a","ssh":"user@worker-a"}],
 "repos":[{"name":"skills","gh":"OWNER/skills","checkout":"/home/user/skills"}]}
```

`ssh: null` means local. The file is read at Nix evaluation time
(`coordinator.fleetFile`, default `$XDG_CONFIG_HOME/coordinator/fleet.json`),
so the task graph itself contains exactly the configured hosts and repos;
names and targets are validated during evaluation against
`^[A-Za-z0-9_:.@/-]+$`, and runtime identifiers (agent ids, session ids) are
validated again before use and passed as separate argv words. Over ssh the
argv travels as a base64 blob of NUL-separated words that a remote `bash -c`
turns back into argv with `mapfile` and `exec`: no shell re-parses the words,
so handoff text with quotes, newlines or `$(...)` stays literal, and a
worker's forced-command shim can whitelist argv before exec. Tests point
`coordinator.fleetFile` at fixtures with `--option coordinator.fleetFile:path`.

## Adapters

Claude today (`agents/<role>.md`: tools, `permissionMode: default`, preloaded
skills, the guard hook). Codex arrives in M4 as `agents/<role>/AGENTS.md`; its
harness has no per-agent hook, so the grammar guard runs as a wrapper script
there and the limitation is recorded, not hidden.

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
  JSON body and the working directory. The adapter's hook command refuses every
  Bash call when the guard file is not installed, so a host that has the
  adapter but not the launcher cannot run tasks at all (fail closed).
- `Read(~/...)` and `Read(./**)` rules are checked as rule text; the emulator
  does not expand `~` or `./`. The launcher renders the real state directory
  (`$XDG_STATE_HOME/coordinator`) in place of the portable default.
- The test matcher (`tests/lib/claude-permission-match.sh`) is deliberately
  stricter than Claude Code in two places: it never auto-allows a command with
  substitutions or redirections, and it splits on separators without quote
  awareness. Both only make the suite report `none` where the real matcher
  might allow; they never report `allow` where it would prompt.
