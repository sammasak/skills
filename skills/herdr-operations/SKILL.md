---
name: herdr-operations
description: Use when asked what coding agents are doing, whether an agent is idle, working, blocked or done, how fresh that status is, or to read a bounded excerpt of one agent's terminal through Herdr. Not for sending prompts to agents (agent-orchestration until the agent-handoff skill lands in M2) or for running Claude on another machine (agent-orchestration).
---

# Herdr operations (read-only)

Herdr 0.9.5 is the live source for pane and agent state. Durable engineering
status comes from GitHub and git, never from Herdr.

## Commands

| Need | Run | Output |
|---|---|---|
| Every agent on every configured host | `devenv tasks run herdr:inventory --show-output` | hosts[] with agent records, `state_age_s`, `stale`, per-host `error` |
| Bounded terminal excerpt of one agent | `devenv tasks run herdr:inspect --input-json '{"host":"<host>","agent_id":"<id>","lines":40}'` | `excerpt`, `lines_returned` (cap 200) |
| Everything above plus GitHub/git evidence in one call | `devenv tasks run coord:brief --show-output` | JSON + Markdown summary |

Run them from the skills checkout (the devenv graph lives there). Hosts come
from `fleet.json`; a host that is not listed is refused with exit 3.

## Reading the states

- `working`: a turn is in progress.
- `idle` or `done`: the agent is waiting for input. `done` only means the
  server has not marked the last turn as seen. Neither means the task passed.
- `blocked`: the agent shows an approval or question UI. It needs a human;
  never prompt a blocked agent.
- `unknown`: an agent is present but unclassified. Treat as "no information".
- Host `error.kind` of `timeout` or `unreachable`: say so; do not guess.

## Freshness

Herdr publishes no timestamps. `observed_at` is when the task ran;
`state_age_s` is how long `state_change_seq` has been unchanged in the local
snapshot history. `stale: true` means the snapshot is older than the task's
`max_age_s`. Quote both when asked how current a fact is.

If a task fails or is unavailable, report its `error` verbatim. Do not fall
back to raw `herdr` or `ssh` commands; those are outside the Coordinator's
allowed surface.
