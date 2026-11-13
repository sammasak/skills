# Skill use telemetry

Claude Code's own `skill_activated` event reports a user skill as `custom_skill` (seen live for a skill
from `~/.claude/skills`) unless `OTEL_LOG_TOOL_DETAILS=1`, which also exports tool input.
`hooks/emit-skill-use.sh` fills the gap with one small log record per skill use that carries the skill's
name and nothing else, so skill usage can be reviewed by name with the content flags off.

Registered (from nixos-config) on `PreToolUse` with matcher `Skill` and on `UserPromptSubmit`. It is
deterministic: it never calls a model and never blocks the session (always exit 0, no output, the POST runs
detached with `curl --max-time 2`).

## What it emits

One OTLP/HTTP JSON log record, POSTed to `$HARNESS_OTLP_ENDPOINT/v1/logs`:

- Resource attributes: `service.name=claude-code`, plus each pair in `HARNESS_RESOURCE_ATTRIBUTES`.
- Body `skill_use`; attributes (all strings): `event.name=skill_use`, `session.id`, `skill.name`,
  `invocation_trigger` (`model` for the Skill tool, `user-slash` for a typed `/name`), `agent_type` (for
  subagents).

The Skill tool's `args` are never read. Of a prompt only a leading `/name` token is read, and it counts
only when a skill is installed under that name (`$CLAUDE_CONFIG_DIR/skills/<name>/SKILL.md`, the project's
`.claude/skills/<name>/SKILL.md`, or a namespaced `plugin:skill`); built-in commands such as `/clear` are
skipped. Names must match `[A-Za-z0-9_.:-]{1,80}`.

## Configuration

| Variable | Effect |
| --- | --- |
| `HARNESS_OTLP_ENDPOINT` | Base URL of the OTLP/HTTP receiver, e.g. `http://127.0.0.1:4319`. Unset: the hook does nothing. |
| `HARNESS_RESOURCE_ATTRIBUTES` | Extra resource attributes, `OTEL_RESOURCE_ATTRIBUTES` syntax. |
| `HARNESS_SKILL_USE_DISABLE=1` | Turns the hook off. |

Each run logs `skill-use` with result `emitted`, `no-skill`, `no-endpoint`, `disabled` or `unparsed` to the
shared hook log. Tests: `tests/test-skill-use.sh` (`skills:test:skill-use`, also in pre-push).
