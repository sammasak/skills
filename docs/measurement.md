# Measurement (coord:report, M0a)

`coord:report` is a **read-only** aggregation over evidence the coordinator already keeps: its audit log
(`coordinator.stateDir/audit.jsonl`) and the GitHub pull-request record (the same `gh pr list` path
`work:status` uses). It adds no dashboard, scheduler, broker or database and runs on demand. This is M0a
(skills #85): the delivery, review and blocked-time metrics. Token, skill-invocation and runtime-resource
metrics are reported as `unavailable` with a reason; they arrive in later slices.

## What exists today (the evidence sources)

| Source | Where | What it records | Trust / nature |
|---|---|---|---|
| Coordinator audit log | `stateDir/audit.jsonl` (`phase ∈ {attempt,outcome,gh,parked,spawn}`; `gh` rows carry `task, stage, action, label, repo, number`; attempts carry `authorized_by ∈ {issue_url, label, labeled_at}`) | every handoff send + outcome, every GitHub write the coordinator made, every `agent_busy` park | observation; append-only. Gap: refusals are not yet written (a later slice) |
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
- **tokens / skill_invocations / runtime_resources** — `unavailable` in M0a (reason names the later slice / #69).

## Coverage rules

`coverage_pct` for the GitHub metrics is the share of repositories the window names that GitHub answered for and
did not truncate at the fetch limit; `unknown_reason` names the missing or truncated repositories. A failed
`gh pr list` is recorded per repo, never hidden, and never read as "no deliveries".

## Privacy rules

The report emits **aggregates and source refs only**: audit ids, handoff ids, PR URLs and issue numbers. It never
emits scope text, PR/issue bodies, prompts, commands or any free-text assignment field. No per-session or
per-issue metric keys; M0a exports no Prometheus series at all.

## How to run

```sh
devenv tasks run coord:report --input-json '{"since":"2026-11-03T00:00:00Z"}'   # window start (ISO-8601 Z)
devenv tasks run coord:report --input-json '{"days":7}'                          # default: last 7 days
devenv tasks run coord:report --input-json '{"since":"…","until":"…","limit":100}'
```

The task wrapper prints `{}` to devenv's stdout; the report JSON is the `{"task":"coord:report",…}` line (and the
task's `DEVENV_TASK_OUTPUT_FILE`). It makes one `gh pr list` call per repository the window names.

## How to replay / test

`devenv tasks run skills:test:tasks:report` runs the suite over `task-modules/fixtures/report/` (a synthetic
7-day audit + fake PRs): an independent review+merge, an owner-hold block, a repeated review on one head, a
partial record that must not count, review independence, missing-source → unknown, and the privacy assertion.
