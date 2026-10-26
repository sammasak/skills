---
name: herdr-operations
description: Use when asked what coding agents are doing, whether an agent is idle, working, blocked or done, how fresh that status is, or to read a bounded excerpt of one agent's terminal through Herdr. Not for sending prompts to agents (agent-handoff) or for running Claude on another machine (agent-orchestration).
---

# Herdr operations (read-only)

Herdr 0.9.5 is the live source for pane and agent state. Durable engineering
status comes from GitHub and git, never from Herdr.

## Commands

Run them from the skills checkout (the devenv graph lives there). Every output
is JSON with `schema_version: 1`; `coord:brief` also prints Markdown.

| Need | Run |
|---|---|
| The whole picture: who needs you, every agent with `herdr_state` and `work_verdict` | `devenv tasks run coord:brief --show-output` |
| Every agent on every configured host (`state_age_s`, `stale`, per-host `error`) | `devenv tasks run herdr:inventory --show-output` |
| Bounded terminal excerpt of one agent (cap 200 lines) | `devenv tasks run herdr:inspect --input-json '{"host":"<host>","agent_id":"<id>","lines":40}'` |
| What a session was last doing, from the harness's own store (last prompt, last answer, tools, `awaiting_input`) | `devenv tasks run harness:session-summary --input-json '{"host":"<host>","harness":"claude","session_id":"<id>","cwd":"<cwd>"}'` |
| Open issues and recent PRs per fleet repo | `devenv tasks run gh:work --show-output` |
| Recent commits, dirty files, unpushed work per checkout | `devenv tasks run git:recent --show-output` |
| Per-agent join of Herdr state and GitHub/git evidence | `devenv tasks run work:status --show-output` |

`host`, `agent_id`, `session_id` and `cwd` come from `herdr:inventory` records;
never guess them. Hosts and repos come from `fleet.json`; anything not listed is
refused with exit 3 (`error.kind: invalid_input`).

## Reading the output

- `herdr_state` is Herdr's word (`idle|working|blocked|done|unknown`).
- `work_verdict` comes only from GitHub/git: `verified` (a merged PR closes or
  names the agent's `#N`), `unverified` (open PR or open issue only), `blocked`
  (Herdr shows an approval/question UI), `unknown` (no `#N` or no evidence).
- `partial: true` with `failed_sources` means a source failed; say which, then
  answer from what remains. A verdict computed without GitHub is `unknown`.
- `needs_owner: true` items go first in any summary.

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
