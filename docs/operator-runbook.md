# Operator runbook — roles and tasks (epic #16, herdr-native)

## What runs where

| Piece | Lives in | Installed by |
|---|---|---|
| Role contracts `agents/<role>/ROLE.md`, Claude adapters `agents/<role>.md` | this repo | nixos-config `skills.nix` links every `agents/*.md` into `~/.claude/agents` on devTools hosts, so the roles are ordinary subagents |
| Tasks (`task-modules/*.nix`, `agents/<role>/tasks.nix`) | this repo | run from one writable skills checkout: `~/claude-code-skills` (or the path you tell the agent) |
| Worker machines | Herdr's own saved machines (`~/.local/state/herdr/client/endpoints.json`, Herdr-owned) | `herdr machine add <ssh-target> --label <name>` on the coordinator host; nixos-config declares them as `sam.herdr.machines` and runs that idempotently at activation. Workers declare nothing: an empty list means "this host only" |
| State (drafts, `audit.jsonl`, `brief/latest.json`) | `~/.local/state/coordinator/` | the tasks |

There is no guard hook: the role prompt states what the agent may run, and
Claude Code's permission prompt (`permissionMode: default`) asks you before a
Bash call your own settings do not already allow.

## Daily use

Open Claude Code in any directory and talk to the subagent: "ask the
coordinator what my agents are doing", "is #16 really done", "hand the
docs fix to the agent in pane wF:p2". Claude delegates to `coordinator`
(or pick it explicitly with `/agents`); it runs

```bash
cd ~/claude-code-skills && devenv tasks run coord:brief --show-output
```

and answers from the brief, keeping `herdr_state` and `work_verdict`
separate. The same tasks work without an LLM from the checkout:

```bash
cd ~/claude-code-skills
devenv tasks run coord:brief --show-output          # this host + every saved Herdr machine
herdr machine list --json                           # which machines that is (empty on a worker)
tail -n 5 ~/.local/state/coordinator/audit.jsonl    # every herdr:message attempt and outcome
```

To hand work over: the coordinator drafts (`coord:handoff`) with the
`allowed_actions` the agent may take on that handoff (`merge`, `close`,
`label`, `comment`, `deploy:none`, `deploy:<host>`; the brief shows them as
its `Allowed actions:` line, which also says that reading, committing and
opening a PR are implied and everything else, deleting included, stays
forbidden), you confirm the `handoff_id` and target in the conversation and
name the GitHub issue URL and label that authorize it (the coordinator asks
when you have not; it never invents one), it sends (`herdr:message` with
`authorized_by`, which Claude Code prompts for), awaits (`herdr:await`), and
verifies with `work:status`. Every attempt in `audit.jsonl` records
`allowed_actions` and `authorized_by` (as stated, `verified: false`; the
label is not yet checked through `gh`). "delivered" is not "done"; only a
merged PR for the agent's `#N` in its own repo makes `work_verdict: verified`.

Keep the checkout current (`git -C ~/claude-code-skills pull`): the tasks and
contracts the subagent uses are the ones in that working tree.

## Running the quality role

"ask the quality agent whether devenv-platform's gates pass"; it runs
`quality:report` (and `quality:gate` only when asked) from the checkout against
the consumer's own `platform.sdlc` machine. `quality:gate` is bounded to
540 s; raise Claude's Bash timeout (`BASH_MAX_TIMEOUT_MS`) if a long gate must
report.

## Reading failures

- `partial: true`: a host did not answer (`answered_hosts`/`hosts_total`,
  each `hosts[].error`) or `herdr machine list` failed (`machines_error`); the
  rest of the brief is still valid. There are no snapshots: an unreachable
  machine is shown as `reachable: false`, never from memory.
- `error.kind` on a task: `invalid_input` (unsafe id or machine label you
  passed), `invalid_label` (a saved machine whose label the coordinator will
  not forward; rename it), `timeout`/`command_failed` (Herdr's own stderr line
  follows in `error.message`: unknown machine, failed ssh connection, server
  down), `not_found`, `unsupported`. devenv itself exits 1 for any failed
  task; the kind is in the record, not the exit code.
- `herdr:message` outcomes: `delivered`; `unknown_delivery` /
  `agent_prompt_stalled` (text may already sit in the input box: inspect, do
  not resend blindly); `agent_blocked`/`agent_busy`/`agent_changed`/
  `agent_not_found` (nothing sent).

## Verifying a change to this repo

```bash
devenv tasks run skills:test            # policy, manifests, contract, hooks, tasks suites, herdr skill drift
```
