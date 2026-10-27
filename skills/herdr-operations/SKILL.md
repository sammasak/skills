---
name: herdr-operations
description: Use when asked what coding agents are doing on this host or on the saved Herdr machines, whether an agent is idle, working, blocked or done, how fresh that status is, or to read a bounded excerpt of one agent's terminal through Herdr. Not for sending prompts to agents (agent-handoff) or for running Claude on another machine (agent-orchestration).
---

# Herdr operations (read-only)

Herdr 0.9.5 is the live source for pane and agent state; its own skill
(`herdr`, vendored verbatim from `herdr --skill`) documents the CLI. Durable
engineering status comes from GitHub and git, never from Herdr.

## Where the agents are

There is no fleet file. This host's agents come from its own Herdr server.
Other hosts are Herdr **saved machines** (`herdr machine list --json`) and are
read through Herdr's command forwarding (`herdr --machine <label> …`). On a
worker the machine list is empty, so you see that host only; on the
coordinator host you see every enabled saved machine. A worker is added with
Herdr's own `herdr machine add <ssh-target> --label <name>` on the coordinator
host (nixos-config declares them as `sam.herdr.machines`); nothing in this repo
knows hosts by name.

## Commands

Run them from the skills checkout (the devenv graph lives there). Every output
is JSON with `schema_version: 1`; `coord:brief` also prints Markdown.

| Need | Run |
|---|---|
| The whole picture: who needs you, every agent with `herdr_state` and `work_verdict` | `devenv tasks run coord:brief --show-output` |
| Every agent on this host and on each enabled saved machine (`hosts[].machine`, per-host `reachable` and `error`, `machines_error`) | `devenv tasks run herdr:inventory --show-output` |
| Bounded terminal excerpt of one agent (cap 200 lines); omit `machine` for this host | `devenv tasks run herdr:inspect --input-json '{"machine":"<label>","agent_id":"<id>","lines":40}'` |
| What a session on this host was last doing, from the harness's own store (last prompt, last answer, tools, `awaiting_input`) | `devenv tasks run harness:session-summary --input-json '{"harness":"claude","session_id":"<id>","cwd":"<cwd>"}'` |
| Open issues and recent PRs of one repo | `devenv tasks run gh:work --input-json '{"repo":"OWNER/REPO"}'` |
| Recent commits, dirty files, unpushed work of one checkout | `devenv tasks run git:recent --input-json '{"checkout":"/abs/path"}'` |
| Per-agent join of Herdr state and GitHub evidence | `devenv tasks run work:status --show-output` |

The guard also admits Herdr's own read verbs as typed, without a task:
`herdr [--machine <label>] machine list [--json]`, `machine status [<label>]
[--json]`, `agent list`, `pane list`, `agent get|read|wait <target> …` and
`herdr --skill`. Use them to answer a Herdr-specific question the tasks do not
cover; `herdr agent prompt` is act-class and prompts like `herdr:message`. A
raw `herdr agent read` is not bounded and `--lines` beyond the viewport may
scroll an idle agent's pane; prefer `herdr:inspect` for excerpts.

`machine`, `agent_id`, `session_id` and `cwd` come from `herdr:inventory`
records; never guess them. `machine: null` means this host. A label Herdr does
not know makes Herdr itself fail (`error.kind: command_failed`, exit 2 and
Herdr's own message inside the record); an unsafe label or id you pass is
refused as `invalid_input`, and a saved machine whose label the coordinator
cannot pass safely (Herdr's default `host/session` form) appears in the
inventory as `error.kind: invalid_label` until it is renamed.

## Reading the output

- `herdr_state` is Herdr's word (`idle|working|blocked|done|unknown`).
- `work_verdict` comes only from GitHub: `verified` (a merged PR closes or
  names the agent's `#N` in the `OWNER/REPO` its title names), `unverified`
  (open PR or open issue only), `blocked` (Herdr shows an approval/question
  UI), `unknown` (no `OWNER/REPO` or `#N` in the title, or GitHub unreachable;
  `reasons` says which).
- `partial: true` means a host did not answer or `herdr machine list` failed:
  `answered_hosts`/`hosts_total`, each `hosts[].error` and `machines_error`
  say what; answer from the hosts that did answer and name the missing ones.
- `needs_owner: true` items go first in any summary.

## Reading the states

- `working`: a turn is in progress.
- `idle` or `done`: the agent is waiting for input. `done` only means the
  server has not marked the last turn as seen. Neither means the task passed.
- `blocked`: the agent shows an approval or question UI. It needs a human;
  never prompt a blocked agent.
- `unknown`: an agent is present but unclassified. Treat as "no information".
- Host `error.kind` of `timeout` or `command_failed` (Herdr's own message,
  e.g. a failed ssh connection, follows in `error.message`): say so; do not
  guess what the host is doing.

## Freshness

Herdr publishes no timestamps and the tasks keep no snapshots: `observed_at`
is when the task ran, and `state_change_seq` only moves when Herdr saw the
agent's state change. To show movement, run the inventory twice and compare
`state_change_seq`. An unreachable machine is reported with `reachable: false`
and its error, never from memory.

If a task fails or is unavailable, report its `error` verbatim. Do not fall
back to `ssh` or any command outside the tasks and the Herdr read verbs above.
