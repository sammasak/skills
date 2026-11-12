# Work reference telemetry

Claude Code usage telemetry (tokens, skills, hooks) reaches Loki keyed by `session.id` and repository, not
by branch. `hooks/emit-work-ref.sh` adds the missing link: one small log record saying which repository,
branch and commit a session is on, so a later report can join session -> branch -> PR -> issue with `gh`.

Registered (from nixos-config) on `SessionStart` and `Stop`. It is deterministic: it never calls a model,
`gh` or the GitHub API, and never blocks the session (always exit 0, no output, git calls bounded by
`timeout 2`, the POST runs detached with `curl --max-time 2`).

## What it emits

One OTLP/HTTP JSON log record, POSTed to `$HARNESS_OTLP_ENDPOINT/v1/logs`, only when the session's `cwd` is
in a git repository whose `origin` is a github.com `owner/repo`, and only when that repository or branch
changed since the last record for the session (a new commit on the same branch is not resent).

- Resource attributes: `service.name=claude-code`, plus each pair in `HARNESS_RESOURCE_ATTRIBUTES`.
- Body `work_ref`; attributes (all strings): `event.name=work_ref`, `session.id`, `vcs.owner.name`,
  `vcs.repository.name`, `vcs.ref.head.name` (absent when detached), `vcs.ref.head.revision` (12-char sha),
  `work.ref.hint` (issue or PR number when the branch name states one: `issue-76`, `issue/76`, `gh-76`,
  `pr-76`, `#76`, a leading `76-`, or `fix/76-` and similar), `agent_type` (for subagents).

Credentials embedded in a remote URL never leave the hook: only the owner and repository names are kept.

## Configuration

| Variable | Effect |
| --- | --- |
| `HARNESS_OTLP_ENDPOINT` | Base URL of the OTLP/HTTP receiver, e.g. `http://127.0.0.1:4319`. Unset: the hook does nothing. |
| `HARNESS_RESOURCE_ATTRIBUTES` | Extra resource attributes, `OTEL_RESOURCE_ATTRIBUTES` syntax: `host.name=lenovo-21cb001pmx,worker.name=push`. |
| `HARNESS_WORK_REF_DISABLE=1` | Turns the hook off. |

Dedupe state: `${XDG_STATE_HOME:-~/.local/state}/claude-hooks/work-ref/<session_id>`, cleaned after 7 days.
Each run logs `work-ref` with result `emitted`, `unchanged`, `no-endpoint`, `no-repo`, `disabled` or
`unparsed` to the shared hook log. Tests: `tests/test-work-ref.sh` (`skills:test:work-ref`, also in pre-push).
