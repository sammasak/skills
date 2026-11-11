# Coordinator process: working the authorized queue

How the coordinator discovers, prioritizes, delegates and follows up on work
the owner has already authorized on GitHub, using only the tasks its contract
lists (`coord:brief`, `gh:work`, `coord:handoff`, `herdr:message`,
`herdr:await`, `work:status`, `gh:comment`, `gh:label`). This is a procedure
the agent follows, not a program: there is no scheduler, daemon, queue or
database. One pass is a *tick*; within an active session the coordinator runs
ticks back to back until the stop conditions below hold (ROLE.md, Autonomy),
and nothing runs after the session ends. Every tick starts from files, never
from memory.

## Rule 0

The coordinator never idles in chat and never asks the owner a question in
chat that can be a GitHub question. A real blocker becomes a labelled issue
comment (`gh:label needs-decision` or `blocked`, `gh:comment` with the exact
question or blocker) and the tick moves to the next item.

## What counts as authorized

An issue or PR is authorized when it carries a label the owner applied and the
coordinator cannot write. The send gate (`herdr:message`, see ROLE.md steps
7–8) is the authority: it reads the label through `gh`, refuses
`needs-decision`, `blocked` and `needs-live` as authorizing labels, refuses
any label its own audit log shows it added, and records who applied the
label and when.

Holds on the authorizing item are scoped (skills#28):
- `blocked` and `needs-decision` hold every handoff;
- `needs-live` holds only a handoff whose `allowed_actions` carry a live scope
  (`deploy:<host or cluster>`; `deploy:none` is not one). A routine handoff
  (comment, merge, close, review) under it goes out, and its attempt line
  records the hold and that decision (`authorized_by.hold`).

A PR may be authorized on its own: the owner's label on that PR (its label
event's actor is the owner, and no `gh:label` act added it) authorizes
routine actions on exactly that PR, at the head the handoff names
(`review: OWNER/REPO#N@<sha>`, checked against the PR's current head), and
never a `deploy:*`, which needs the issue-level authorization.

`gh:label` may lift only a hold it added: the audit holds that add's attempt
and done outcome, and the call cites `evidence`, the resolving PR or commit
URL. An owner-applied hold is the owner's to lift. Every refusal names the
missing authorization: which label, on which item, by whom. Nothing in
this procedure weakens that gate. A quoted or remembered approval is not
authorization. The owner may delegate approval in config
(`coordinator.mayApprove`, with `coordinator.approvalDecision` naming the
owner's quoted decision): then `gh:label approved` may add the label to an
issue of the owner's repos (never a PR, never over `needs-live`, `blocked`
or `needs-decision`, only the owner's own open issues), both audit lines cite
the decision, and the send gate accepts that label only because of those
lines (`applied_by: coordinator-delegated`, with the `gh:label` `audit_id`),
only while the delegation is still in force, and only with no hold on the
issue.

## One tick

1. **Discover.** `coord:brief` (agents, `handoffs` rebuilt from
   `audit.jsonl`, verdicts, and the `portfolio`: `gh:repos` lists the
   owner's repositories by recent push with open PR, open issue and
   authorizing-label issue counts in one call, and the brief runs `gh:work`
   only for the active ones, an open PR or an issue with an authorizing label,
   newest first, up to the cap). Nobody has to name repositories. Discovery
   uses the configured `coordinator.authorizingLabels` (default `approved`);
   the send gate accepts any owner-applied label the coordinator cannot
   write, so work authorized under another label is found through a named
   repo or an existing handoff, never missed by the gate itself. A
   `portfolio.error` (GitHub down) leaves the agent brief whole. Then `gh:work` for any other
   repository an outstanding handoff names. When `gh:repos` or `gh:work` says
   `truncated: true`, say so in the report and work the visible items;
   raising `coordinator.ghLimit` is the owner's call.
   Gates on a worker host run in two lock lanes (skills#28), always with
   `flock -o` (`--close`), so the lock fd is closed before the command runs and a
   child it spawns (a `cargo-mutants` mutant, a lane test child, a `devenv processes`
   daemon) can never inherit the fd and keep the lane held after its parent exits
   (skills#85): `flock -o /tmp/$(hostname)-heavy-work.lock` for anything that builds
   or compiles (`nixos:qa`, `platform:verify`, `sdlc:done`, `rust:ci`, `cargo`,
   `nix build`) and `flock -o -w 900 /tmp/$(hostname)-light-work.lock` for eval-only
   and script gates (`skills:test*`, `nix eval`, `nix flake check` without builds,
   jq/bash suites), so a short gate never queues behind a long one. `coord:capacity`
   shows each lane (`lock_queue`) and refuses a heavy spawn while the heavy lane
   holds `heavy_jobs` or more jobs. A green gate on a clean head is recorded once
   (`gate:record:<gate>`, devenv-platform); a reviewer or merger runs
   `gate:verify --input gate=<gate>` for the exact head and reruns targeted
   probes, never the whole gate a second time.
2. **Prioritize**, highest first:
   - P0: a delivered handoff whose agent is `blocked` or `needs_owner`
     (report it first, with the exact decision).
   - P1: authorized issues/PRs with no handoff yet (not in `handoffs`).
   - P2: delivered handoffs not yet `verified` (follow up).
   - P3: everything else is reported, not assigned. Items labelled
     `needs-decision` or `blocked` are never assigned, and one labelled
     `needs-live` gets routine handoffs only (no `deploy:*`); `blocked`
     items get their blocker re-checked, nothing more.
   When the owner has delegated approval (`coordinator.mayApprove`), turn P3
   issues into P1 yourself: pick the ones a worker can finish (no live
   hardware, no owner hold, not `needs-triage`), approve them in priority
   order with `gh:label approved`, one issue per call, and in the report
   list what you approved and what still needs the owner (`needs-live`,
   `blocked`, `needs-triage`).
3. **Delegate** P1 items, one open handoff per item, while a free worker remains. Each handoff has a `hold`: `open`
   while its agent works on it or a PR of it is open and unmerged, `closed` when the evidence says nobody is
   (`closed_reason`: stale, superseded, settled without an open PR, merged without an independent review, verified), and
   `unknown` when that evidence is missing (`unknown_reason`: a host that did not answer, an agent state Herdr cannot
   classify, GitHub evidence unavailable, a send whose delivery is unknown: no outcome line or a stalled prompt, which
   `herdr:message` refuses to resend). An approved item is `reassignable` only when all its handoffs are closed and
   no open PR names it: hand it out again, naming the earlier handoff in the scope (a merged one without a review needs
   that review, not a new implementation); an unknown hold keeps it until the evidence returns. Then pick an agent that is `idle` or `done` (never
   `blocked`, never `working`, never one of your own panes: `coord:handoff` refuses a Coordinator pane) on a host with capacity (lenovo: one heavy job,
   control plane only; acer-swift: two, one while a full gate runs; msi-ms7758:
   one, no spawn, reachable Mon-Fri 09:00-21:00 only, so unreachable outside it
   is expected: route elsewhere). Draft
   with `coord:handoff`, `allowed_actions` limited to what the label grants
   (reading, committing, opening a PR and `comment` for ordinary work; `merge`,
   `close`, `deploy:<host>` only when the owner's label or comment says so).
   Send with `herdr:message` and `authorized_by = {issue_url, label}`. A
   refusal (`authorization_missing`, `duplicate`, ...) ends that item for this
   tick, not the tick; report the `error.kind` verbatim and go to the next item.
   `agent_busy` is parked, not lost: the audit log keeps the refused send, so
   first draft the item for another free worker; with none free, move on, and
   `coord:changed` prints a `retry` line once a worker is free.
4. **Follow up** every P2 item once: `herdr:await` by `audit_id` with a finite
   timeout, then `work:status`. `unknown_delivery` or
   `agent_prompt_stalled`: `herdr:inspect`, report, never resend.
   `no_turn_observed`: the agent is idle and has not started; report, do not
   resend. `verified` with an `evidence_ref`: record it on the issue with
   `gh:comment` when `comment` is allowed, and report.
5. **Record.** Nothing to do: every send, label and comment is already in
   `audit.jsonl`, and `coord:brief` renders the handoffs from it. The report
   to the owner lists P0 first, then what was delegated, followed up and
   skipped, each with its `handoff_id`/`audit_id` and the task output it came
   from.

## Tick checklist

Before stopping, every tick answers four questions from the brief and
`coord:changed`, and acts on each answer in the same turn:

1. **Trigger vs reality.** Workers idle or done while authorized work is
   left must mean `idle_wake.fleet_idle: true` and a wake. When the record
   disagrees (`fleet_idle: false` with idle workers, a Coordinator pane among
   the workers, a wake deferred by the budget), that is a defect: open a fix
   handoff for it, do not wait for the owner to notice.
2. **Circular waits.** An author waiting for its reviewer while the
   reviewer waits for a fix is a deadlock; break it with one direct
   instruction to the next actor, naming what they do and what they may do
   (`allowed_actions`).
3. **Idle workers with authorized work.** Any `idle` or `done` worker plus an
   eligible P1 item is a handoff not yet sent; send it.
4. **Empty approved queue.** No authorized item left is a reason to triage,
   not to stop: classify open issues (fits a worker, needs-live, blocked,
   needs-triage, owner decision) and, under the owner's delegation, approve
   the ones a worker can finish.

A refused task or a tool defect found on the way gets a `tooling-feedback`
draft in the same turn: the task, its `error.kind` and message, the input,
and what was expected.

## Status format

A status to the owner is five lines at most and carries only what changed
since the last status: delegated, merged, blocked, needing the owner, next.
Never re-list merged work or the history; link the issue comment that holds
the detail.

## Stop conditions

A blocked agent or an item that needs the owner ends that item only: record
it (`gh:label` `blocked` or `needs-decision`, one `gh:comment` with the exact
question) and continue with the rest. Stop the session and report when no
eligible P1 item is left or no worker is free, and every delivered handoff has
been followed up once (never poll while waiting; when no worker is free, the
report names the eligible items left), or when a task refuses with `gh_error`, `audit_corrupt` or
`busy` (fix the environment before the next tick).

## Definition of done for an item

A merged PR with green repository gates on the exact head and an independent
review recorded on the PR (`work:status` verdict `verified` with its
`evidence_ref`). An issue closes only with that evidence and only when
`close` was allowed.

## Not in this increment

No `coord:loop` task, scheduler or LLM polling loop: a tick starts only when
the lenovo wake-up timer's `coord:changed` check finds an actionable change
(docs/coordinator-continuity.md), and a quiet check starts nothing. No model
tiers, no label creation, no GitHub pagination; those are later increments of
#28, added only when a tick shows the need.
