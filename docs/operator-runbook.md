# Operator runbook — roles, tasks and guards (epic #16)

## What runs where

| Piece | Lives in | Installed by |
|---|---|---|
| Role contracts `agents/<role>/ROLE.md`, adapters `agents/<role>.md` (Claude) / `agents/<role>/AGENTS.md` (Codex) | this repo | nixos-config `skills.nix` links every `agents/*.md` into `~/.claude/agents` on devTools hosts, so the roles are ordinary subagents |
| Tasks (`task-modules/*.nix`, `agents/<role>/tasks.nix`) | this repo | run from one writable skills checkout: `$SKILLS_CHECKOUT`, default `~/claude-code-skills` |
| Guard library `task-modules/guard-lib.nix` (tasks `guard:check`, `guard:integrity` in `guard.nix`) behind the dispatcher `hooks/role-guard-dispatch.sh` | this repo | nixos-config registers the dispatcher as a user-scope PreToolUse(Bash) hook and builds the library into a store binary it hands over as `ROLE_GUARD_BIN`; without that, the dispatcher runs `guard:check` in the checkout |
| Worker machines | Herdr's own saved machines (`~/.local/state/herdr/client/endpoints.json`, Herdr-owned) | `herdr machine add <ssh-target> --label <name>` on the coordinator host; nixos-config declares them as `sam.herdr.machines` and runs that idempotently at activation. Workers declare nothing: an empty list means "this host only" |
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
devenv tasks run coord:brief --show-output          # this host + every saved Herdr machine
herdr machine list --json                           # which machines that is (empty on a worker)
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
sandbox cannot write the consumer checkouts, so a real `quality:report` (the
consumer's `devenv shell` writes `.devenv/`) or `quality:gate` needs each
checkout added as a writable root. `quality:gate` is bounded to 540 s; raise
Claude's Bash timeout (`BASH_MAX_TIMEOUT_MS`) if a long gate must report.

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
- `herdr:message` outcomes: `delivered`; `unknown_delivery` /
  `agent_prompt_stalled` (text may already sit in the input box: inspect, do
  not resend blindly); `agent_blocked`/`agent_busy`/`agent_changed`/
  `agent_not_found` (nothing sent).
- A guard refusal shows up in Claude as a blocked Bash call with the guard's
  reason on stderr. "tasks run only from the skills checkout" means the
  subagent used another directory or path form; "has no agents/<role>/ROLE.md
  (missing or stale …)" means `~/claude-code-skills` is absent or behind the
  installed skills revision (clone or `git pull` it, or set `SKILLS_CHECKOUT`);
  the role is refused, never let through. In hardened mode, "checkout integrity check failed"
  means a guarded file in the materialised copy changed: let the activation
  rebuild it rather than editing it back.

## Operating the guard

`guard:check` (`task-modules/guard.nix`) reads `agents/<role>/ROLE.md` in the skills checkout
and allows exactly `[cd <checkout> && ]devenv tasks run <read|run task>
[--input-json '<object>'] [--show-output]`, run from the checkout or `cd`-ed
into exactly its plain absolute path; `act` tasks return `ask`. It is wired at
settings level by `hooks/role-guard-dispatch.sh` (nixos-config installs it
with the other user-scope hooks): the dispatcher reads the hook input's
`agent_type` and runs the guard only for role agents (a role is one whose
`agents/<name>/ROLE.md` ships in the installed copy, or is present in the
checkout); other agents and the main session are untouched. Where the guard
logic runs matters: with nixos-config's install, Claude Code's user-scope hook
runs a store-built binary of `task-modules/guard-lib.nix` (`ROLE_GUARD_BIN`),
so an agent that can write the checkout cannot change the guard *code*. The
policy (`ROLE.md` task lists) and the task bodies still come from the
checkout; they are protected only in hardened mode (`COORDINATOR_REQUIRE_INTEGRITY`
with a pin). Without the install, in a `claude --agent <role>` main session
without the launcher, and under Codex, the dispatcher falls back to
`devenv tasks run guard:check` in the checkout under its own timeout; then the
checkout's guard is trusted as-is, so keep it pulled. The
checkout path must be plain (`[A-Za-z0-9_./-]`, no `..`, spaces or unicode).
A subagent's
frontmatter hooks never run (verified 2026-10-27), so the frontmatter hook in
each adapter only covers the `claude --agent <role>` main-session case. A
host with the adapters linked but no checkout refuses every role Bash call.
Installing this repo as a plugin does not install the dispatcher. Optional
hardened mode: with
`COORDINATOR_REQUIRE_INTEGRITY=1` and a 64-hex pin in
`COORDINATOR_INTEGRITY_SHA256`, the guard also verifies the checkout's
`.integrity` manifest (the `guard:integrity` task) on every call. No installed
module sets these today (the nixos-config launcher module was removed with
the herdr-native rework, #25); any wrapper may.

## Verifying a change to this repo

```bash
devenv tasks run skills:test            # policy, manifests, contract, negative, hooks, tasks suites
devenv tasks run quality:two-harness   # LIVE, costs tokens: same role through Claude and Codex
```
