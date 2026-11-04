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
`needs-decision`, `blocked` and `needs-live`, refuses any label its own audit
log shows it added, and records who applied the label and when. Nothing in
this procedure weakens that gate. A quoted or remembered approval is not
authorization. The owner may delegate approval in config
(`coordinator.mayApprove`, with `coordinator.approvalDecision` naming the
owner's quoted decision): then `gh:label approved` may add the label to an
issue of the owner's repos (never a PR, never over `needs-live`, `blocked`
or `needs-decision`), both audit lines cite the decision, and the send gate
accepts that label only because of those lines (`applied_by:
coordinator-delegated`, with the `gh:label` `audit_id`).

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
2. **Prioritize**, highest first:
   - P0: a delivered handoff whose agent is `blocked` or `needs_owner`
     (report it first, with the exact decision).
   - P1: authorized issues/PRs with no handoff yet (not in `handoffs`).
   - P2: delivered handoffs not yet `verified` (follow up).
   - P3: everything else is reported, not assigned. Items labelled
     `needs-decision`, `blocked` or `needs-live` are never assigned; `blocked`
     items get their blocker re-checked, nothing more.
   When the owner has delegated approval (`coordinator.mayApprove`), turn P3
   issues into P1 yourself: pick the ones a worker can finish (no live
   hardware, no owner hold, not `needs-triage`), approve them in priority
   order with `gh:label approved`, one issue per call, and in the report
   list what you approved and what still needs the owner (`needs-live`,
   `blocked`, `needs-triage`).
3. **Delegate** P1 items, one handoff per item, while a free worker remains: pick an agent that is `idle` or `done` (never
   `blocked`, never `working`) on a host with capacity (lenovo: one heavy job,
   control plane only; acer-swift: two, one while a full gate runs). Draft
   with `coord:handoff`, `allowed_actions` limited to what the label grants
   (reading, committing, opening a PR and `comment` for ordinary work; `merge`,
   `close`, `deploy:<host>` only when the owner's label or comment says so).
   Send with `herdr:message` and `authorized_by = {issue_url, label}`. A
   refusal (`authorization_missing`, `duplicate`, `agent_busy`, ...) ends that
   item for this tick, not the tick; report the `error.kind` verbatim and go to
   the next item.
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

No `coord:loop` task, scheduler, cron re-arm or background poll; no
`coord:spawn`; no model tiers; no label creation; no GitHub pagination. Those
are later increments of #28, added only when a tick run by hand shows the
need.
