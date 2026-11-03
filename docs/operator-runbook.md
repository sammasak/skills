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
forbidden), it sends, authorized by the label you applied on the GitHub
item (the coordinator takes the issue URL and label from `gh:work`, never
invents one, and does not ask you to confirm each draft; ROLE.md, Autonomy), (`herdr:message` with
`authorized_by`, which Claude Code prompts for; it reads that issue's labels
through `gh` first and refuses with `authorization_missing` when the label is
not there), awaits (`herdr:await`), and verifies with `work:status`. Every
attempt in `audit.jsonl` records `allowed_actions` and `authorized_by`
(`verified: true`, `verified_at`). "delivered" is not "done"; only a merged
PR for the agent's `#N` in its own repo makes `work_verdict: verified`.

The coordinator's GitHub writes are `gh:label` (add or remove one of
`needs-decision`, `blocked`, `needs-live` on one issue or PR) and
`gh:comment` (one comment, at most 4000 characters, signed `Coordinator`;
it never speaks as you). Both need the `handoff_id` they serve or a `reason`,
and append two `phase: gh` lines (attempt, outcome) to the same
`audit.jsonl`. The label that authorizes a send is yours to apply and must
be one the coordinator cannot write: `herdr:message` refuses the three
labels above as authorization, and any label its own audit log says it
added. The record keeps who applied the label and when, from the issue's
label events.

Keep the checkout current (`git -C ~/claude-code-skills pull`): the tasks and
contracts the subagent uses are the ones in that working tree.

## Working the queue

"ask the coordinator to work the queue" (or any coordinator session, by
default; ROLE.md, Autonomy) runs ticks of `docs/process.md` until nothing
eligible is left:
discover (`coord:brief`, whose `handoffs` section is rebuilt from
`audit.jsonl`, and `gh:work` per repository; `truncated: true` means a list
reached `coordinator.ghLimit` and may have been cut), prioritize, delegate every
eligible authorized item through the unchanged send gate, follow up delivered
handoffs, report; a blocked item is recorded and skipped, not a stop. A new session continues from `brief/latest.json` and
`audit.jsonl`; nothing is kept in memory. Codex runs the same contract through
`agents/coordinator/codex.toml`, a custom-agent file in Codex's `agents_dir`
format whose instructions point at the same ROLE.md; nixos-config installs it
as `~/.codex/agents/coordinator.toml` on the coordinator host, so Codex lists
a `coordinator` agent there. No shell command is involved in loading it.

## Waking up without tokens

`coord:changed` is the check a timer runs between sessions. It costs no model
call: `herdr:inventory` (and, once sammasak/skills#38 is merged and the task
depends on it, `gh:repos`; until then a `repos_file` holding such a record)
plus a jq read of `audit.jsonl`, diffed against
`~/.local/state/coordinator/changed/snapshot.json`. It prints nothing and
exits 0 when nothing is actionable; otherwise one line per change: an agent
newly `blocked`; an agent holding a delivered handoff that `settled` (its
`state_change_seq` moved and it is idle or done), is `gone` or was `replaced`
by another session; a `new` agent; a saved machine that went `host …
unreachable` or came back; a `repo` whose open-PR or approved-issue count
changed; the `audit` log turning unreadable; a `snapshot` that had to be
rebuilt. The first run is a baseline (only blocked agents print) and every
run moves the snapshot on, so a change is reported once and kept in
`changed/latest.json`. The nixos-config module `coordinator-wakeup` runs it
on a user timer on the coordinator host and starts one headless
`claude -p --agent coordinator` session, with a spend cap, only when it
printed; `systemctl --user disable --now coordinator-wakeup.timer` stops that
until the next switch.

The task spaces its own wake-ups so a burst of changes cannot buy a session
per tick: a printing run within `coordinator.wakeMinGapSeconds` (300) of the
last one, or beyond `coordinator.wakeMaxPerHour` (6) in a sliding hour, is
deferred: it prints nothing, records `wake.deferred`, `wake.reason`
(`min_gap` or `per_hour_cap`) and `wake.next_allowed_at` in `latest.json`,
keeps the held lines under `wake.pending` with `changes` empty (so a timer
reading `changes` starts nothing either), and leaves the snapshot untouched,
so the pending changes come out together on the first allowed run. Past wake times live in `changed/wakes.json`
(epoch seconds, pruned to the window); an unreadable file counts as no
history. `peek` neither spends nor checks the budget.

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
- `herdr:message` refusals before sending: `authorization_missing` (the
  `authorized_by` label is not on the issue), `gh_error` (labels unreadable).
- `herdr:message` outcomes: `delivered`; `unknown_delivery` /
  `agent_prompt_stalled` (text may already sit in the input box: inspect, do
  not resend blindly); `agent_blocked`/`agent_busy`/`agent_changed`/
  `agent_not_found` (nothing sent).

## Verifying a change to this repo

```bash
devenv tasks run skills:test            # policy, manifests, contract, hooks, tasks suites, herdr skill drift
```
