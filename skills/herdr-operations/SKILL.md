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
| The whole picture: who needs you, every agent with `herdr_state` and `work_verdict` | `devenv tasks run coord:brief >/dev/null; cat ~/.local/state/coordinator/brief/latest.md` (the Markdown; `latest.json` beside it is the full record; `--show-output` also prints every upstream task's JSON, more than ten times the size; a non-zero exit still leaves a fresh `latest.md` when the brief rendered, and none when it did not) |
| Every agent on this host and on each enabled saved machine (`hosts[].machine`, per-host `reachable` and `error`, `machines_error`) | `devenv tasks run herdr:inventory --show-output` |
| What moved since the last check (the wake-up timer's question): silent when nothing is actionable, else one line per change, `idle` included (every agent idle/done while an ungraded open PR, an authorized issue without an open handoff or an unverified handoff is left; once per fleet+work fingerprint); the snapshot moves on | `devenv tasks run coord:changed --show-output` (reads without consuming; only the timer passes `--input-json '{"consume":true}'`, which moves the snapshot and spends the wake budget) |
| Bounded terminal excerpt of one agent (cap 200 lines); omit `machine` for this host | `devenv tasks run herdr:inspect --input-json '{"machine":"<label>","agent_id":"<id>","lines":40}'` |
| What a session on this host was last doing, from the harness's own store (last prompt, last answer, tools, `awaiting_input`) | `devenv tasks run harness:session-summary --input-json '{"harness":"claude","session_id":"<id>","cwd":"<cwd>"}'` |
| The owner's repositories by recent push with open PR/issue and approved-issue counts (one GraphQL call plus one issue search per authorizing label, so a repo pushed earlier than the page that still holds an approved issue is listed with `found_by: search`; `truncated` when the cap is hit) | `devenv tasks run gh:repos --show-output` |
| Open issues and recent PRs of one repo | `devenv tasks run gh:work --input-json '{"repo":"OWNER/REPO"}'` |
| Recent commits, dirty files, unpushed work of one checkout | `devenv tasks run git:recent --input-json '{"checkout":"/abs/path"}'` |
| Per-agent join of Herdr state and GitHub evidence | `devenv tasks run work:status --show-output` |
| Worker pool: per host the workers (idle/busy/unknown), worker and heavy-job slots left, whether a spawn fits, which assignment kinds fit (opus planning/review, sonnet implementation, haiku mechanical), and a `/clear` or `/compact` hint per idle worker | `devenv tasks run coord:capacity --show-output` (add `--input-json '{"next":{"repo":"OWNER/REPO","task_ref":"#N"}}'` to judge the next assignment's independence) |

You may also use Herdr's own read commands as typed, without a task:
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
- `work_verdict` comes only from GitHub. An agent with a delivered handoff on
  its current session (audit log, matched by host, pane and Herdr session) is
  judged by that handoff, whatever its title says (`correlation.by:
  handoff`); only an agent without one falls back to an `OWNER/REPO #N` title
  (`correlation.by: title`). `verified` (the handoff's PRs are merged and
  `reviewed`, or for a title: a merged PR and the issue closed; a merged PR
  without that review is `unverified`), `unverified` (an open PR or open
  issue), `blocked` (Herdr shows an approval/question UI), `unknown` (no
  evidence, or GitHub unreachable; `reasons` says which). `evidence_ref` is a
  merged PR URL, set only on `verified`.
- Each handoff carries `stages`, distinct and each `null` until met:
  `implemented` (a PR naming its `task_ref` opened, or given commits, from the
  send until the next handoff to that pane), `reviewed` (a grade of 9/10 or more on the PR's
  exact head, signed `(<host> <agent>` or `-- <host> <agent>`), `merged` (the
  merged PR URLs), `live` (a PR comment with a `Live acceptance:` line). A PR
  the handoff's own agent graded, at any grade, is that agent's review, not
  its work: it leaves the handoff's PRs instead of counting as reviewed. A
  grade on a line naming another pane (`(wR:p1, 8/10)` in the author's reply)
  quotes that pane and is no one's grade. Children of an epic that stays open are verified per handoff;
  `stale: true` marks a handoff whose pane is gone, restarted, or superseded
  without a PR.
- Only the newest 50 handoffs in the audit log are evaluated; `handoffs_omitted`
  counts the rest and the brief header says how many. An agent whose latest
  delivered handoff on its current session is among them reports
  `correlation.by: omitted` and `work_verdict: unknown` (`blocked` when Herdr
  shows it blocked), never a verdict from its title.
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
