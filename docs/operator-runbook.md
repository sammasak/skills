# Operator runbook — roles, tasks and guards (epic #16)

## What runs where

| Piece | Lives in | Installed by |
|---|---|---|
| Role contracts `agents/<role>/ROLE.md`, adapters `agents/<role>.md` (Claude) / `agents/<role>/AGENTS.md` (Codex), `agents/<role>/permissions.json` | this repo | nixos-config links the Claude adapter on devTools hosts; the launcher project-scopes it inside the checkout |
| Tasks (`task-modules/*.nix`, `agents/<role>/tasks.nix`) | this repo | run from a writable checkout with `devenv tasks run …` |
| Guard `hooks/validate-role.sh` (+ `validate-<role>.sh` wrappers) | this repo | nixos-config: `~/.claude/hooks/validate-<role>.sh` and the settings-level hook in the launcher's settings file |
| `fleet.json` (hosts, repos) | `~/.config/coordinator/fleet.json` | nixos-config from `sam.coordinator.fleet` |
| State (snapshots, drafts, `audit.jsonl`, `brief/latest.json`) | `~/.local/state/coordinator/` | the tasks |

## Daily use

```bash
coordinator                                   # launcher on the coordinator host (lenovo): Claude as the Coordinator role
devenv tasks run coord:brief --show-output    # the same picture without an LLM, from the checkout
tail -n 5 ~/.local/state/coordinator/audit.jsonl   # every herdr:message attempt and outcome
```

Ask the Coordinator "what are my agents doing / what needs me / is #N done". It
answers from `coord:brief` and must keep `herdr_state` and `work_verdict`
separate. To hand work over: it drafts (`coord:handoff`), you confirm the
`handoff_id` and target in the conversation, it sends (`herdr:message` prompts
for permission every time), awaits (`herdr:await`), and verifies with
`work:status`. "delivered" is not "done"; only a merged PR for the agent's
`#N` in its own repo makes `work_verdict: verified`.

## Reading failures

- `partial: true` + `failed_sources`: a host or repo did not answer; the rest
  of the brief is still valid. `stale: true` records come from the last
  snapshot of an unreachable host.
- `error.kind` on a task: `invalid_input` (wrong id/host, exit 3),
  `timeout`/`unreachable`/`command_failed` (exit 2), `not_implemented` (64).
- `herdr:message` outcomes: `delivered`; `unknown_delivery` /
  `agent_prompt_stalled` (text may already sit in the input box: inspect, do
  not resend blindly); `agent_blocked`/`agent_busy`/`agent_changed`/
  `agent_not_found` (nothing sent).
- A guard refusal shows up in Claude as a blocked Bash call with the guard's
  reason on stderr; in `-p` mode a permission prompt is denied, so make sure
  the settings-level guard is in place (the launcher does this).

## Operating the guard

`hooks/validate-role.sh` reads `agents/$ROLE/ROLE.md` under
`$COORDINATOR_CHECKOUT` and allows exactly
`devenv tasks run <read|run task> [--input-json '<object>'] [--show-output]`
from that directory; `act` tasks return `ask`. Register it at **settings
level** (verified: an agent-frontmatter hook alone is not honoured for allow
decisions when the agent is the main session) and keep the frontmatter hook
as the fail-closed backstop.

## Rotating the checkout

A skills bump creates `~/.local/share/coordinator/skills-<rev>`; `current`
follows the active generation; two older copies are kept. Rollback of the
NixOS generation re-points `current`. State under `~/.local/state/coordinator`
is shared across revisions.

## Verifying a change to this repo

```bash
devenv tasks run skills:test            # policy, manifests, contract, negative, hooks, tasks suites
bash agents/quality/tests/two-harness.sh  # LIVE, costs tokens: same role through Claude and Codex
```
