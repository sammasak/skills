# Operator runbook — roles, tasks and guards (epic #16)

## What runs where

| Piece | Lives in | Installed by |
|---|---|---|
| Role contracts `agents/<role>/ROLE.md`, adapters `agents/<role>.md` (Claude) / `agents/<role>/AGENTS.md` (Codex) | this repo | nixos-config `skills.nix` links every `agents/*.md` into `~/.claude/agents` on devTools hosts, so the roles are ordinary subagents |
| Tasks (`task-modules/*.nix`, `agents/<role>/tasks.nix`) | this repo | run from one writable skills checkout: `$SKILLS_CHECKOUT`, default `~/claude-code-skills` |
| Guard `hooks/validate-role.sh` (+ `validate-<role>.sh` wrappers) | this repo | the adapter's frontmatter hook runs it from the checkout; nothing to install |
| `fleet.json` (hosts, repos) | `~/.config/coordinator/fleet.json` | you (schema in the RFC); an absent file is an empty fleet |
| State (snapshots, drafts, `audit.jsonl`, `brief/latest.json`) | `~/.local/state/coordinator/` | the tasks |

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
devenv tasks run coord:brief --show-output          # the fleet picture
tail -n 5 ~/.local/state/coordinator/audit.jsonl    # every herdr:message attempt and outcome
```

To hand work over: the coordinator drafts (`coord:handoff`), you confirm the
`handoff_id` and target in the conversation, it sends (`herdr:message`
prompts for permission every time), awaits (`herdr:await`), and verifies with
`work:status`. "delivered" is not "done"; only a merged PR for the agent's
`#N` in its own repo makes `work_verdict: verified`.

Keep the checkout current (`git -C ~/claude-code-skills pull`): the tasks and
contracts the subagent uses are the ones in that working tree. Point
`SKILLS_CHECKOUT` elsewhere if yours lives elsewhere.

## Running the quality role

Claude: "ask the quality agent whether devenv-platform's gates pass"; it runs
`quality:report` (and `quality:gate` only when asked) from the checkout against
the consumer's own `platform.sdlc` machine. Codex: `codex exec --cd
"${SKILLS_CHECKOUT:-$HOME/claude-code-skills}" "$(cat
agents/quality/AGENTS.md)"$'\n\n'"<request>"` with the guard in a dedicated
`CODEX_HOME/hooks.json` and `--sandbox workspace-write`; see
`agents/quality/AGENTS.md` for what Codex cannot enforce, and note that its
sandbox cannot write fleet checkouts, so a real `quality:report` (the
consumer's `devenv shell` writes `.devenv/`) or `quality:gate` needs each
checkout added as a writable root. `quality:gate` is bounded to 540 s; raise
Claude's Bash timeout (`BASH_MAX_TIMEOUT_MS`) if a long gate must report.

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
  the settings-level guard is in place (the launcher does this). A refusal
  "checkout integrity check failed" means a guarded file in the copy changed:
  rebuild the copy (re-run the activation) rather than editing it back.

## Operating the guard

`hooks/validate-role.sh` reads `agents/$ROLE/ROLE.md` in the skills checkout
and allows exactly `[cd <checkout> && ]devenv tasks run <read|run task>
[--input-json '<object>'] [--show-output]`, run from the checkout or `cd`-ed
into exactly it; `act` tasks return `ask`. The adapter's frontmatter hook
resolves it from the checkout, so a host with the adapter linked but no
checkout refuses every Bash call. Optional hardened mode: with
`COORDINATOR_REQUIRE_INTEGRITY=1` and a 64-hex pin in
`COORDINATOR_INTEGRITY_SHA256`, the guard also verifies the checkout's
`.integrity` manifest (`hooks/lib/integrity-check.sh`) on every call; the
nixos-config `coordinator` launcher module does this with a materialised copy,
and is disabled by default.

## Verifying a change to this repo

```bash
devenv tasks run skills:test            # policy, manifests, contract, negative, hooks, tasks suites
bash agents/quality/tests/two-harness.sh  # LIVE, costs tokens: same role through Claude and Codex
```
