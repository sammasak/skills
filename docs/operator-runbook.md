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
cd ~/claude-code-skills && devenv tasks run coord:brief >/dev/null; cat ~/.local/state/coordinator/brief/latest.md
```

and answers from the brief, keeping `herdr_state` and `work_verdict`
separate. The same tasks work without an LLM from the checkout:

```bash
cd ~/claude-code-skills
devenv tasks run coord:brief >/dev/null; cat ~/.local/state/coordinator/brief/latest.md   # this host + every saved Herdr machine
herdr machine list --json                           # which machines that is (empty on a worker)
tail -n 5 ~/.local/state/coordinator/audit.jsonl    # every herdr:message, coord:spawn and gh act attempt and outcome
```

To hand work over: the coordinator drafts (`coord:handoff`) with the
`allowed_actions` the agent may take on that handoff (`merge`, `close`,
`label`, `comment`, `cleanup:tmp`, `deploy:none`, `deploy:<host>`; the brief
shows them as its `Allowed actions:` line, which also says that reading,
committing and opening a PR are implied and everything else, deleting
included, stays forbidden — except that `cleanup:tmp` allows deleting only
the temporary review worktrees/clones, their cargo targets and `/tmp/devenv-*`
dirs the scope lists, skills#28), it sends, authorized by the label you applied on the GitHub
item (the coordinator takes the issue URL and label from `gh:work`, never
invents one, and does not ask you to confirm each draft; ROLE.md, Autonomy), (`herdr:message` with
`authorized_by`, which Claude Code prompts for; it reads that issue's labels
through `gh` first and refuses with `authorization_missing` when the label is
not there), awaits (`herdr:await`), and verifies with `work:status`. Every
attempt in `audit.jsonl` records `allowed_actions` and `authorized_by`
(`verified: true`, `verified_at`). "delivered" is not "done"; only merged
PRs for the handoff's `task_ref` in the authorizing issue's repo, opened or
committed to after the send, each with an independent signed 9/10 on its
head, make `work_verdict: verified`. Only the newest 50 handoffs are
evaluated (`handoffs_omitted` counts the rest); an agent whose handoff is
older reports `correlation.by: omitted`, not a verdict from its title. The
brief's Markdown is `brief/latest.md` beside `latest.json`; devenv's own
stdout is every task's JSON, which the command above discards. The `;` is
deliberate: when no host answers the brief exits 2 and `latest.md` explains
why; a run that failed before rendering leaves no `latest.md` at all. The pane title is not consulted for
an agent that holds a handoff, an open epic does not hold back its merged
children, and the brief prints verified handoffs as one line per `repo#ref`
and each open one with its `implemented`, `reviewed`, `merged`, `live` stages.

Workers: `coord:capacity` reports each host's workers, the worker and
heavy-job slots left and which assignment kinds fit (planning and review on
opus, implementation on sonnet, mechanical checks on haiku; review and
implementation take a heavy-job slot). The limits are `coordinator.capacity`
in `agents/coordinator/spawn.nix`. Each host has a `worker` kind: acer-swift
and msi-ms7758 are `nspawn`: they are no workers themselves, their workers
are the ephemeral containers listed as `slots` (acer `["worker-1"]`, msi
`["worker-1" "worker-2"]`, nixos-config `docs/nspawn-workers.md`), one heavy
job each; a slot is in use while `container@<slot>` is active (`ssh <host>
systemctl is-active`). `max_workers` on an nspawn host, `slots` on a host
host, or more heavy jobs than slots, fails evaluation. msi is up only Mon-Fri 09:00-21:00 local, so
"unreachable" outside that window is expected: route to another host, and
hand no heavy work to msi shortly before its 21:00 shutdown. lenovo is
`host`, one heavy job and no spawning (the control plane; see
nixos-config#109). `coord:spawn` (`machine`, `kind`, `task_ref`,
`authorized_by`, and an absolute `cwd` on a `host` host only) starts one
Claude Code worker in its own Herdr workspace only for an item
carrying a label you applied on that same item and only when that host's
capacity allows. The decision is taken under the audit lock on a fresh agent
list of the target host, and a spawn in flight holds its slots, so two
concurrent spawns never share one slot; the lock is released before the
herdr calls. Every request that passes input validation and reaches the lock
writes a `phase: spawn` attempt and an outcome line to `audit.jsonl`; the
outcome is one of `started`, `refused` (with its reason), `agent_not_ready`,
`failed` (herdr's code under `error_code`), or `interrupted` when the task
died before writing one. A request refused earlier (`invalid_input`, a
missing inventory, `busy`, `audit_corrupt`) is not audited. A started worker
has no assignment until the coordinator hands it one (`coord:handoff`,
`herdr:message`). On an `nspawn` host (`machine` = the host, no `cwd`) the
task runs `ssh <host> systemctl start container@<slot>` for the first free
slot; the host's hook opens a Herdr workspace labelled `<slot>` with claude
running inside the container, and started means that claude is idle within
`workerBootSeconds` (120). A failed unit start (`unit_start_failed`), no
claude in that workspace (`worker_not_found`) or one that never turns idle
(`agent_not_ready`) stops the unit again (`cleanup` in the outcome). There
is no fallback to a host claude. The kind's model reaches the hook as
`WORKER_MODEL` in `~/.config/workers/<slot>.env` on the host, written before
the start and removed at every stop; its transcript is inside the container so
`coord:capacity` reports `context_tokens` null, and its home is empty: the
handoff tells it to `git clone` the repo, and its work leaves only by `git
push`. `coord:reap` (`machine` + `slot`, or the spawn's `audit_id`;
`force: true` for a working or blocked worker) runs `systemctl stop
container@<slot>`, which closes the workspace and wipes the worker, and
writes a `phase: reap` audit line; `coord:capacity` lists idle workers
whose handoff was delivered since their start under `reapable`. Manually:
`ssh acer-swift systemctl stop container@worker-1`. On a `host` host it isOn a `host` host it is `herdr agent start <kind>-<N> --kind
claude -- --dangerously-skip-permissions --model <the kind's model>`, and
`--dangerously-skip-permissions` starts unattended only where
user settings carry `skipDangerousModePermissionPrompt: true` (Claude Code
2.1.300 no longer reads `~/.claude.json`'s `bypassPermissionsModeAccepted`)
and `cwd`'s trust dialog was accepted: Home Manager pre-trusts `$HOME` on
every host and, on a worker host, that host's `sam.herdr.worker.trustedDirs`
as well (acer-swift: `~/claude-code-skills` and `~/nixos-config`; nixos-config
`mcp.nix`, `acceptClaudeStartupDialogs`, since nixos-config#146). So on a worker
host spawn in `$HOME` or either checkout; the coordinator host (lenovo, which
does not spawn) pre-trusts `$HOME` only. Name the checkout in the handoff. Elsewhere `agent start` returns
`agent_not_ready` and the workspace stays for you to inspect. A host
configured with spawning off is refused as `capacity` whether or not it is
in the inventory. The task never
closes a pane or workspace. Each host also carries `lock_queue`: the heavy-work and light-work lanes with their holder, waiters and ages (`host:locks`, over the saved machine's ssh target); a heavy spawn is refused while the heavy lane already holds `heavy_jobs` jobs.

The coordinator's GitHub writes are `gh:label` (add or remove one of
`needs-decision`, `blocked`, `needs-live` on one issue or PR) and
`gh:comment` (one comment, at most 4000 characters, signed `Coordinator`;
it never speaks as you). Both need the `handoff_id` they serve or a `reason`,
and append two `phase: gh` lines (attempt, outcome) to the same
`audit.jsonl`. The label that authorizes a send is yours to apply and must
be one the coordinator cannot write, unless you delegate it:
`coordinator.mayApprove = true` with `coordinator.approvalDecision` (the URL
of your decision comment) lets `gh:label approved` label an issue of your
repos (never a PR, never over `needs-live`, `blocked` or `needs-decision`),
cited in its audit lines as `owner_delegation`. With it on, `gh:repos` also
counts a repo with open issues as active and `coord:brief` lists, per active
repo, the `approvable` issues (open, written by you, no authorizing label,
no `needs-live`/`blocked`/`needs-decision`/`needs-triage`), expanding repos
with authorized work before delegation-only ones, so a wake session sees
what it may approve; the send gate accepts such a
label only while the delegation is in force (same flag, same decision URL),
on an issue you wrote that carries no hold, and records `applied_by:
coordinator-delegated` with that `audit_id`. Switching the flag off or
changing the decision withdraws every earlier delegated approval; adding
`blocked`, `needs-live` or `needs-decision` stops it; an issue someone else
opened in a public repo is never approved. Both options are yours because
the headless wrapper refuses `--option` and the role's task list has no
other door; a shell with `devenv` can set them, as the test suite does.
Otherwise `herdr:message` refuses the three
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
`audit.jsonl` and whose `portfolio` section comes from `gh:repos`, the owner's
repositories by recent push with open PR/issue and authorizing-label issue
counts, plus one `gh search issues` per authorizing label so a repo pushed
earlier than that page still shows up when it holds an authorized issue
(`found_by: search`; when that search fails the brief says `issue search
unavailable`, since repos outside the page are then unchecked), plus `gh:work` for
the active ones only; `truncated: true` means a list reached `coordinator.ghLimit`
and may have been cut), prioritize, delegate every
eligible authorized item through the unchanged send gate, follow up delivered
handoffs, report; a blocked item is recorded and skipped, not a stop. A new session continues from `brief/latest.json` and
`audit.jsonl`; nothing is kept in memory. Codex runs the same contract through
`agents/coordinator/codex.toml`, a custom-agent file in Codex's `agents_dir`
format whose instructions point at the same ROLE.md; nixos-config installs it
as `~/.codex/agents/coordinator.toml` on the coordinator host, so Codex lists
a `coordinator` agent there. No shell command is involved in loading it.

## Waking up without tokens

`coord:changed` is the check a timer runs between sessions. It costs no model
call: `herdr:inventory` and `gh:repos` (both run upstream in the same DAG)
plus a jq read of `audit.jsonl`, diffed against
`~/.local/state/coordinator/changed/snapshot.json`. It prints nothing and
exits 0 when nothing is actionable; otherwise one line per change: an agent
newly `blocked`; an agent holding a delivered handoff that `settled` (its
`state_change_seq` moved and it is idle or done), is `gone` or was `replaced`
by another session; a `new` agent; a saved machine that went `host …
unreachable` or came back; a `repo` whose open-PR or approved-issue count
changed; the `audit` log turning unreadable; a `snapshot` that had to be
rebuilt; and `idle`, the fleet having nothing to do while work is left. The
first run is a baseline (only blocked agents print). A plain
`coord:changed` reads without consuming; the timer's form,
`--input-json '{"consume":true}'`, moves the snapshot on, so a change is
reported once there and kept in `changed/latest.json`. The nixos-config
module `coordinator-wakeup` runs the consuming form on a user timer on the
coordinator host and starts one headless
`claude -p --agent coordinator` session, with a spend cap, only when it
printed; `systemctl --user disable --now coordinator-wakeup.timer` stops that
until the next switch.

The task spaces its own wake-ups so a burst of changes cannot buy a session
per tick (the brief shows both numbers as `Wake budget:`): a printing run within `coordinator.wakeMinGapSeconds` (300) of the
last one, or beyond `coordinator.wakeMaxPerHour` (6) in a sliding hour, is
deferred: it prints nothing, records `wake.deferred`, `wake.reason`
(`min_gap` or `per_hour_cap`) and `wake.next_allowed_at` in `latest.json`,
keeps the held lines under `wake.pending` with `changes` empty (so a timer
reading `changes` starts nothing either), and leaves the snapshot untouched,
so the pending changes come out together on the first allowed run. Past wake times live in `changed/wakes.json`
(epoch seconds, pruned to the window); an unreadable file counts as no
history. Only the timer's form, `--input-json '{"consume":true}'`, moves
the snapshot and spends the budget; the plain `coord:changed` (an owner
session's read) neither consumes nor spends, so it never takes a change away
from the timer.
A deferred run says why on stderr (`coord:changed: wake deferred (<reason>)
until <time>; N change(s) pending`); stdout stays empty by contract, and an
idle-fleet wake held back this way waits under `wake.pending` like any other
line. `latest.json` is always the timer's
consuming record (`consume: true`); a plain read prints its own record and
writes nothing.


The `idle` line is the one change that needs no transition: when every
worker on every answering host is idle or done (none working, blocked or
unknown; an unreachable host or a fleet without a known worker is not idle)
and work is left, the Coordinator is woken with no human. The workers are
the panes a handoff was sent to (`audit.jsonl` attempt lines, as
`host/agent_id`) plus `coordinator.workers`, minus the Coordinator's own panes:
`coordinator.panes` (comma-separated `host/agent_id`), the pane a task runs in
(`HERDR_PANE_ID`), and every pane an attempt line names as its sender (`from`).
Those are never workers and never handoff targets (`coord:handoff` and
`herdr:message` refuse them), and a handoff that reached one earlier is ignored,
so an interactive Coordinator that is always working cannot keep the fleet busy
(the record's `coordinator_panes` lists them; `idle_wake.non_workers` counts
every listed pane that is not a worker). Work is any of: an open PR in an
active repo (`gh:repos`, newest push first, at most `portfolioActive` repos)
or in an open-handoff repo without a signed 9/10 or more on its current head
by someone other than the agent whose handoff it answers; an issue carrying
an authorizing label with no open delivered handoff naming it; a delivered
handoff of the last `openHandoffDays` with no merged PR for its issue opened
after the send. The fleet test is free; GitHub lists (open PRs with comments,
open issues, and merged PRs for handoff repos) are fetched only once the
fleet is idle. The line prints once per distinct fleet+work fingerprint
(the workers by pane plus the work items; a new session in the same pane is the same worker) and not again until that
fingerprint differs from the last one printed: a worker flapping between
working and idle, or the same work seen again, never repeats it, while new
work, a review landing, or the fleet changing does. It counts against the
wake budget like any other line. A gh failure while idle skips the check
for that run and says so under `idle_wake.skipped` in `latest.json`; the
whole evaluation (`fleet_idle`, `work`, `fingerprint`, `fired`) is there on
every run.

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
