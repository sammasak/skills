# Measurement (coord:report, M0a + M0b)

`coord:report` is a **read-only** aggregation over evidence the coordinator already keeps: its audit log
(`coordinator.stateDir/audit.jsonl`) and the GitHub pull-request record (the same `gh pr list` path
`work:status` uses). It adds no dashboard, scheduler, broker or database and runs on demand. M0a (skills #85)
delivered the delivery, review and blocked-time metrics. **M0b** adds: minimal instrumentation at the existing
entrypoints (refusal and state-timeline rows), the `refusals` metric, the per-day/per-week persistence tasks
`coord:report:daily` and `coord:report:weekly`, and the `coord:feedback` taxonomy. Token, skill-invocation and
runtime-resource metrics stay `unavailable` with a reason; they arrive in later slices.

## M0b at a glance

- **Instrumentation (smallest possible, at existing entrypoints).** `herdr:message` writes one
  `phase:"refused"` row for a bounded set of refusals (`owner_hold`, `authorization_missing`, `agent_blocked`,
  `agent_changed`, `duplicate`); `agent_busy` already leaves a `parked` row. `gh:label` writes one
  `phase:"refused"` row for a failed lift (`invalid_input`, `owner_hold`). `coord:brief` appends each observed
  per-pane state (`{host, pane, state, at}` only) to `stateDir/herdr/states.jsonl` so idle and blocked spans
  gain a timeline. Every one of these carries **evidence refs only** — never scope text, bodies, prompts or
  commands.
- **`coord:report:daily`** writes `stateDir/report/daily/YYYY-MM-DD.json` for one UTC day, recomputed from the
  sources and overwritten each run (idempotent: `observed_at` is pinned to the day, not the wall clock, so a
  re-run over unchanged sources is byte-identical). A `sources.audit` block records the matching audit line
  range (`line_first`, `line_last`, `lines_total`) and a `sha256` of exactly those lines, so a partial or
  changed input is visible.
- **`coord:report:weekly`** renders `stateDir/report/weekly/<ISO-week>.md` from the dailies of the ISO week:
  delivered/verified, review stats, waste (parks, blocked spans, refusals), the recurring-failure taxonomy,
  the feedback records, three ranked improvements with their evidence, and one experiment with a measurable
  success criterion.
- **`coord:feedback`** records one `phase:"feedback"` row with a bounded taxonomy and evidence refs only.

## What exists today (the evidence sources)

| Source | Where | What it records | Trust / nature |
|---|---|---|---|
| Coordinator audit log | `stateDir/audit.jsonl` (`phase ∈ {attempt,outcome,gh,parked,spawn,refused,feedback}`; `gh` rows carry `task, stage, action, label, repo, number`; attempts carry `authorized_by ∈ {issue_url, label, labeled_at}`; `refused` rows carry `task, kind` + refs; `feedback` rows carry `taxonomy, evidence_refs`) | every handoff send + outcome, every GitHub write the coordinator made, every `agent_busy` park, and (M0b) every bounded refusal and feedback item | observation; append-only |
| State timeline | `stateDir/herdr/states.jsonl` (`{host, pane, state, at}`; appended by `coord:brief`) | the fleet's per-pane `herdr_state` at each brief snapshot | observation, sparse (only when the coordinator looks) |
| GitHub | `gh pr list --state all` (number, state, mergedAt, createdAt, headRefOid, closingIssuesReferences, comments, reviews) | merges, review rounds, grades | observation; grade/exit tables in comments are worker-asserted |
| Gateway tokens | llm-gateway #69 (blocked) | none today | `unavailable`, never estimated |
| Prometheus/Loki | homelab-gitops #119/#120 | none for agents today | out of M0 |

## Metric definitions

Every metric is `{value, coverage_pct, observed_from, unknown_reason}`. `value` is `null` (never `0`) when the
source could not be read; `0` means the source was read and observed none. A metric over the GitHub record is
`null` when no repository the window names could be fetched.

- **verified_deliveries** — distinct issues with a PR merged inside the window whose **merged head** carries a
  signed, independent grade ≥9 (evidence.jq `passes`, minus any grade signed by the issue's own implementer, read
  from the audit). First merge per issue counts. Bucketed `per_day` and `per_week` (ISO week) by `merged_at`.
- **authorization_to_merge** — for each verified delivery, `merged_at` minus its authorization time: the earliest
  `gh:label add approved` row for the issue, else the earliest handoff's `authorized_by.labeled_at`. Reported as
  `{n, median_seconds, min_seconds, max_seconds}` over the deliveries that had an authorization row.
- **review** — over PRs graded in the window: `prs_reviewed`, `passes` (an independent ≥9 on the current head),
  `rework_rounds` (a head that received a grade <9), `repeated_reviews` (a head graded by ≥2 notes). Heads are
  split by the short sha each grade note stamps.
- **blocked_time** — `by_reason` for the bounded enum `agent_busy | needs-decision | blocked | needs-live`.
  `agent_busy` is a park **count** (not a measured wait) in M0a; the label reasons are measured spans from a
  `gh:label add` to its matching `remove`, with spans still open at window end counted separately.
- **refusals** (M0b) — counts of the `phase:"refused"` rows by bounded `kind`
  (`owner_hold | authorization_missing | agent_blocked | agent_changed | duplicate | invalid_input`) and by
  writing task (`herdr:message | gh:label`). A refusal is a point event (work the coordinator declined to start,
  or a lift it declined to make), not a span: counts only. A window before the M0b instrumentation was deployed
  reads `0`, which the `unknown_reason` names.
- **tokens / skill_invocations / runtime_resources** — `unavailable` in M0a/M0b (reason names the later slice / #69).

### Feedback taxonomy (M0b, Deliverable B)

`coord:feedback` records one effectiveness-feedback item as a `phase:"feedback"` audit row. Its `taxonomy` is a
closed set — `auth_contradiction, wrong_assignment, review_deadlock, repeated_build, stale_lock_or_orphan,
false_success, misleading_skill, missing_tool` — and its `evidence_refs` are GitHub issue/PR URLs or 12-hex
audit ids **only** (the task rejects anything else, so no free scope text can enter). `coord:report:weekly`
ranks the week's taxonomy by frequency and renders the records as its recurring-failures and improvements
sections, citing each item's evidence refs.

## Coverage rules

`coverage_pct` for the GitHub metrics is the share of repositories the window names that GitHub answered for and
did not truncate at the fetch limit; `unknown_reason` names the missing or truncated repositories. A failed
`gh pr list` is recorded per repo, never hidden, and never read as "no deliveries".

## Privacy rules

The report emits **aggregates and source refs only**: audit ids, handoff ids, PR URLs and issue numbers. It never
emits scope text, PR/issue bodies, prompts, commands or any free-text assignment field. No per-session or
per-issue metric keys; M0a/M0b export no Prometheus series at all. The same rule binds the M0b writers: a
`refused` row carries the refs already on the handoff (the authorizing issue+label, the target pane) or the
gh act (repo, number, label, action) and its `kind`, nothing else; a `feedback` row carries only its taxonomy
and evidence refs; the state timeline carries only `{host, pane, state, at}`. The privacy assertions in the test
suites check both the daily JSON and the rendered weekly markdown.

## How to run

```sh
devenv tasks run coord:report --input-json '{"since":"2026-11-03T00:00:00Z"}'   # window start (ISO-8601 Z)
devenv tasks run coord:report --input-json '{"days":7}'                          # default: last 7 days
devenv tasks run coord:report --input-json '{"since":"…","until":"…","limit":100}'
```

The task wrapper prints `{}` to devenv's stdout; the report JSON is the `{"task":"coord:report",…}` line (and the
task's `DEVENV_TASK_OUTPUT_FILE`). It makes one `gh pr list` call per repository the window names.

### M0b tasks

```sh
devenv tasks run coord:report:daily  --input-json '{"date":"2026-11-09"}'   # default: yesterday (UTC)
devenv tasks run coord:report:weekly --input-json '{"anchor":"2026-11-09"}' # default: today; renders the anchor's ISO week
devenv tasks run coord:feedback --input-json '{"taxonomy":"stale_lock_or_orphan","evidence":["https://github.com/sammasak/factum/issues/8"]}'
```

`coord:report:weekly` reads the dailies already written for the week; run `coord:report:daily` for each day first
(or let the daily wake timer produce them). The weekly markdown is at `stateDir/report/weekly/<ISO-week>.md`.

## How to replay / test

- `devenv tasks run skills:test:tasks:report` (M0a) runs the suite over `task-modules/fixtures/report/` (a
  synthetic 7-day audit + fake PRs): an independent review+merge, an owner-hold block, a repeated review on one
  head, a partial record that must not count, review independence, missing-source → unknown, and the privacy
  assertion.
- `devenv tasks run skills:test:tasks:report-m0b` (M0b) runs the suite over `task-modules/fixtures/report/m0b/`:
  `coord:report:daily` idempotency (byte-identical re-run) and audit line/hash provenance, the refusals metric
  from `phase:"refused"` rows, a partial record that must not count, missing-source → unknown (never 0), the
  `gh:label` failed-lift refused row (refs only), `coord:feedback` taxonomy and refs-only privacy, and
  `coord:report:weekly` render with the aggregates, the feedback taxonomy, three ranked improvements, an
  experiment, and privacy assertions on the rendered markdown. The `herdr:message` refused-send row is covered
  in `skills:test:tasks:herdr-message-await`.
