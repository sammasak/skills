# Epic #16 — Harness-agnostic agents + Coordinator: goal and implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. This file is the **goal file** for the `/goal` loop driving the epic: the goal condition below must hold, every task box must be ticked with evidence, and the effort log at the bottom is updated after every slice. Durable progress for other sessions lives in [issue #16](https://github.com/sammasak/skills/issues/16) comments; this file is the working plan.

**Goal:** A small Coordinator agent (and one quality agent) defined once as a role contract in `sammasak/skills`, running through Claude Code and Codex, that retrieves bounded structured context on demand through devenv tasks (Herdr, harness session stores, GitHub, git) instead of carrying host-resident context, installed declaratively via an opt-in nixos-config module (lenovo first).

**Architecture:** *Small role, fat tasks, DAG-first (owner requirement 2026-10-26: devenv tasks, not scripts).* Every unit of work is a devenv task whose `exec` holds the logic (shared shell helpers in `task-modules/lib.sh` are sourced, never a standalone CLI). Fan-out is real: `fleet.json` is read at Nix eval time and generates one task per host (`herdr:list:<host>`) and per repo (`gh:work:<repo>`, `git:recent:<repo>`); aggregators (`herdr:inventory`, `gh:work`, `git:recent`, `work:status`, `coord:brief`) depend on them with `after = [ "...@completed" ]`, read `DEVENV_TASKS_OUTPUTS`, and report every expected-but-missing upstream as a failed source. Tests run the real tasks with `devenv tasks run ... --option coordinator.fleetFile:path <fixture>` and fake `ssh`/`herdr` commands injected through options. No `task-modules/bin/` executables. The role contract is `agents/coordinator/ROLE.md` (YAML frontmatter + prose); harness adapters (`agents/coordinator.md` for Claude, `agents/coordinator/AGENTS.md` for Codex) are thin and contract-tested against ROLE.md. The human gate for any remote action is the harness permission prompt plus an audit log; OS-level boundaries come from nixos-config.

**Tech Stack:** bash 5 + jq 1.8 (runtime), devenv 2.4.0 tasks (DAG, `input`/`DEVENV_TASK_INPUT`, `DEVENV_TASK_OUTPUT_FILE`/`DEVENV_TASKS_OUTPUTS`, `@completed`, `status`), herdr 0.9.5 CLI (JSON out), gh CLI, Claude Code 2.1.300 (`--agent`, `--permission-mode`, permission allowlists), codex-cli 0.162.1, Nix/Home Manager in nixos-config.

**Spec:** [issue #16](https://github.com/sammasak/skills/issues/16) (acceptance criteria + working protocol) and the goal condition below.

## Goal condition (verbatim, what the loop must satisfy)

Epic sammasak/skills#16 is deployment-ready: every milestone checkbox is ticked with linked commit/PR evidence and recorded devenv task exit codes; a Coordinator role and one quality role share ROLE.md contracts, portable skills and devenv task DAGs in sammasak/skills, each proven through Claude Code and Codex adapters on identical fixtures; unit, contract, negative-permission, unreachable-host/timeout, duplicate-message and stale-state tests pass on pinned revisions; a reviewed nixos-config PR adds an opt-in coordinator module (lenovo first, no new dev profile) with an activation+rollback procedure; and either the owner has activated it and a fresh-SSH end-to-end canary passed, OR the owner has explicitly deferred activation in this transcript or on the issue and the epic is labeled "deployment-ready pending owner activation".

## Global Constraints

- **Host is not the point.** Target lenovo (daily driver, has devTools/herdr/claude, reaches acer + black-pi). black-pi is an optional stretch gated on measured footprint and explicit owner wish. Where #16 says black-pi, read "the coordinator host" and say so on the issue.
- **Approval boundaries override `global-context.md` "The Owner Is Never the Blocker"** for this epic: no AI stand-in for merges, host switches, release tags, secret/permission changes, new privileged remote actions, destructive ops. AI review = evidence, not authority. Record each open owner gate on the issue and continue with unblocked work.
- Coordinator never codes, builds, merges, deploys, deletes, runs arbitrary SSH, or grants approvals. `herdr_state` ≠ `work_verdict`; done/idle is never completion.
- Repo ownership: contracts/tasks/evals/adapters → `skills`; host wiring → `nixos-config`; platform mechanisms → `devenv-platform` only if truly missing. No new broker/queue/DB.
- Host/repo/checkout allowlists live in one config file installed by nixos-config (`$XDG_CONFIG_HOME/coordinator/fleet.json`; tests override with `--option coordinator.fleetFile:path`), never in skills source.
- Fresh checkouts: `~/skills-epic16` (`~/skills` belongs to another live session), `~/devenv-platform-epic16`, `~/nixos-config-epic16`. Branch + PR per slice; merges need owner approval. Heavy work under `flock /tmp/$(hostname)-heavy-work.lock`, never parallel.
- Verified tool facts (2026-10-26): herdr 0.9.5 protocol 22; `agent list/get` JSON by default; states `idle|working|blocked|done|unknown`; `agent_session.value` = harness session id; no timestamps anywhere (compute `state_age` from local snapshots via `revision`/`state_change_seq`); `agent read --lines N --source visible|recent`; `agent wait/prompt --until --timeout <ms>`; prompt timeout ≠ non-delivery; `--remote` launch-only → cross-host = `ssh <host> herdr agent list`; zero saved machines; config.toml read-only HM symlink. Claude session store: `~/.claude/projects/<cwd-slug>/<sessionId>.jsonl` (lines with `type`, `timestamp`, `sessionId`, `cwd`). Pi: `~/.pi/agent/sessions/<cwd-slug>/`. Codex: `~/.codex/` (no sessions dir yet on acer).
- From acer-swift there is no SSH to black-pi/lenovo/msi (publickey denied). Cross-host slices use sanitized fixtures + local Herdr until the owner authorizes access or runs from lenovo. Record the exact access change as an owner gate.
- Commits: subject ≤72, body carries `Why: <one line>` (repo `.githooks/commit-msg`), trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Three bounded failed attempts on one item → document blocker on #16, move on. Near context exhaustion → post precise state (SHAs, evidence, next action) to #16 first.

## Review Focus

1. An agent id or host name containing shell metacharacters (`; rm -rf`, `$(...)`, spaces) must be rejected before any `ssh`/`herdr` invocation, never interpolated. (Task 2.1 tests.)
2. A host that hangs (SSH connect but no output) must yield a record with `error.kind = "timeout"` within the configured bound and the rest of the inventory must still be returned. (Task 2.1 tests.)
3. A Herdr `done` agent whose linked task has no merged PR / passing evidence must report `work_verdict: "unverified"`, never "complete". (Task 2.5 tests.)
4. Re-running `herdr:message` with the same payload after a timeout must be refused unless `--resend` with the prior audit id is given, and a `blocked` target must be refused up front. (Task 3.2 tests.)
5. A stale snapshot (older than `max_age_s`) must be labeled `stale: true` with the age, never presented as current. (Task 2.1 tests.)

---

## Slice 0 — Kickoff on the issue

**Files:** none in repo except this plan.

- [x] **Step 1:** Post a kickoff comment on #16: verified tool versions, Herdr CLI realities, lenovo-first reinterpretation, acer SSH gap as owner gate, stale skill commands found (agent-orchestration has no herdr subcommands; pi-ticket uses `ssh acer-swift herdr pane read` which is the right cross-host pattern), link to this plan once pushed.
- [x] **Step 2:** Record in the effort log.

## Slice 1 — M0: contract and authority boundaries

### Task 1.1: Correct owner stand-in language

**Files:**
- Modify: `global-context.md:14-18`
- Test: `tests/test-policy.sh` (new)

- [x] Write `tests/test-policy.sh`: greps `global-context.md` and `docs/agentic-lifecycle.md`; FAIL if any line matches `stand in|to stand in|merge and keep going`; PASS requires a line matching `may not approve|cannot approve|AI review is evidence`.
- [x] Run it → expect FAIL.
- [x] Rewrite the section as "Keep Moving Without Impersonating the Owner": agents draft, review, and continue with unblocked work; owner-only decisions (merge, deploy/switch, tag, secrets/permissions, new privileged remote actions, destructive ops) are recorded as open gates with the exact proposed action; a subagent may review but may not approve. Keep the hardware-blocker terminal-state paragraph.
- [x] Run test → PASS. Commit.

### Task 1.2: Root devenv graph for the skills repo

**Files:**
- Create: `devenv.yaml` (nixpkgs input only), `devenv.nix` (imports `./task-modules/*.nix`, `./agents/coordinator/tasks.nix`; defines `skills:test:hooks`, `skills:test:policy`, `skills:test:manifests`, `skills:test:tasks`, `skills:test:contract`, umbrella `skills:test` with `after` on all), `.gitignore` entry `.devenv/`
- Test: `devenv tasks run skills:test` green; existing `tests/test-hooks.sh` and `tests/test-plugin-manifests.sh` unchanged.

- [x] Write `devenv.yaml`/`devenv.nix` with `skills:test:hooks` and `skills:test:policy` wired to the existing scripts.
- [x] `devenv tasks run skills:test` → PASS; `tests/test-plugin-manifests.sh` still passes (no plugin manifest references devenv files). Commit.

### Task 1.3: ROLE.md schema + Coordinator contract + Claude adapter + contract test

**Files:**
- Create: `agents/coordinator/ROLE.md`, `agents/coordinator.md` (Claude adapter), `docs/rfc/2026-10-26-agent-roles.md` (≤120 lines: role/skill/task/DAG/adapter definitions, record schema v1, read vs act vs privileged classes)
- Create: `tests/test-role-contract.sh`
- Modify: `devenv.nix` (`skills:test:contract`)

**Interfaces (produced):**
- ROLE.md frontmatter: `name`, `version: 1`, `mission`, `skills: [..]`, `tasks: {read: [..], act: [..]}`, `forbidden: [..]`, `evidence: {completion_requires: [..]}`, `adapters: [claude, codex]`.
- Record schema v1 (every task output): `{schema_version:1, task, observed_at, host, server, agent_id, harness, observed_state, state_age_s, stale, task_ref, evidence_ref, approval_required, error:{kind,message}|null}`.
- Claude adapter frontmatter: `name: coordinator`, `description`, `model`, `tools: [Bash, Read]`, `permissions` expressed as a documented allowlist `Bash(devenv tasks run coord:*)`, `Bash(devenv tasks run herdr:inventory*)`, `Bash(devenv tasks run herdr:inspect*)`, `Bash(devenv tasks run work:status*)` and body = "read ROLE.md; invoke only listed tasks".

- [x] Write `tests/test-role-contract.sh`: parses ROLE.md frontmatter with `yq`/awk; asserts every skill listed exists under `skills/<name>/SKILL.md`; every `tasks.read`/`tasks.act` name exists in `devenv tasks list`; adapter `agents/coordinator.md` mentions each `tasks.read` entry and no `tasks.act` entry in its allowlist; adapter `tools` ⊆ `[Bash, Read]`.
- [x] Run → FAIL (files missing).
- [x] Write ROLE.md, RFC, Claude adapter; placeholder tasks exist from Task 1.4 so names resolve.
- [x] Run → PASS. Commit.

### Task 1.4: Negative tests for the coordinator surface

**Files:**
- Create: `tests/test-coordinator-negative.sh`, `tests/lib/claude-permission-match.sh` (reimplements Claude Code `Bash(prefix:*)` prefix semantics for allowlist strings)
- Modify: `devenv.nix` (`skills:test:negative`)

- [x] Write tests: for each forbidden command in `ssh lenovo rm -rf /`, `git push`, `gh pr merge 1`, `nixos-rebuild switch`, `kubectl delete ns x`, `devenv tasks run herdr:message ...`, `cargo build`, assert the adapter allowlist does NOT match; for `devenv tasks run coord:brief` assert it DOES match. Also assert `agents/coordinator.md` contains no `Edit`/`Write` tool.
- [x] Run → FAIL until allowlist file exists; implement; PASS. Commit.
- [x] Open PR "epic-16 M0: contracts, policy fix, root devenv graph"; request independent subagent review; fix findings; record owner merge gate on #16. *(PR #17, 4 review rounds 5→6→7→9/10, HEAD acdb376; owner gate: merge)*

## Slice 2 — M1: read-only coordinator, working locally

### Task 2.1: `herdr:inventory` executable + fixtures

**Files:**
- Create: `task-modules/lib.sh` (`emit_record`, `now_iso`, `valid_id`, `run_bounded <timeout_s> <cmd...>`), `task-modules/bin/herdr-inventory`, `task-modules/herdr.nix` (`herdr:inventory` task: `input = {fleet=null; timeout_s=8; max_age_s=120}`, writes merged JSON to `DEVENV_TASK_OUTPUT_FILE`)
- Fixtures: `task-modules/fixtures/herdr/*.json` + fake `ssh`/`herdr` in `task-modules/fixtures/bin/`, injected with `--option coordinator.sshCommand:string` / `coordinator.herdrCommand:string`
- Test: `task-modules/tests/test-herdr-inventory.sh`

**Interfaces (produced):** module `task-modules/fleet.nix` (options `coordinator.fleetFile` (path, default `$XDG_CONFIG_HOME/coordinator/fleet.json`), `coordinator.sshCommand`, `coordinator.herdrCommand`, `coordinator.stateDir`, `coordinator.timeoutSeconds`; eval-time validation of names/targets). Per host: `herdr:list:<host>` → output `{host, ssh, observed_at, raw}` or exits non-zero with `{host, error:{kind: timeout|unreachable|malformed|command_failed}}` on stdout. Aggregate `herdr:inventory` (after every `herdr:list:<host>@completed`) → `{schema_version:1, task, observed_at, partial, hosts:[{host, reachable, error, agents:[record]}]}`, exit 0 if ≥1 host answered, 2 if none. Snapshots in `$stateDir/herdr/<host>.json` give `state_age_s`; unreachable hosts fall back to their snapshot with `stale:true`, dropped when older than `max_age_s`.

- [x] Tests: local list parsed to records; remote host via `ssh <host> herdr agent list` (fake ssh) parsed; timeout host → `error.kind=timeout`, others present, exit 0; all unreachable → exit 2; host not in fleet → exit 3; id with `;` → exit 3 and no fake-ssh invocation recorded; `state_age_s` grows between two runs with unchanged `state_change_seq`; `stale:true` when snapshot older than `max_age_s`.
- [x] Run → FAIL; implement; PASS; `devenv tasks run herdr:inventory --show-output` against the real local Herdr → records for live panes. Commit.

### Task 2.2: `herdr:inspect` (bounded read)

**Files:** `task-modules/bin/herdr-inspect`, `herdr.nix` task (`input={host, agent_id, lines=40, source="visible"}`), fixtures, `task-modules/tests/test-herdr-inspect.sh`

- [x] Tests: `lines` capped at 200 (request 1000 → 200), invalid id rejected (exit 3), unknown host rejected, output record has `excerpt` (text), `lines_returned`, never exceeds cap; remote path runs `herdr agent read <id> --lines N --source S --format text` through the base64 ssh transport (target first; herdr 0.9.5 rejects options before it).
- [x] Implement; PASS; live run against own pane. Commit.

### Task 2.3: `harness:session-summary`

**Files:** `task-modules/bin/harness-session-summary`, `task-modules/harness.nix`, fixtures (Claude JSONL with user/assistant/system lines incl. a final assistant question; Pi session dir), `task-modules/tests/test-harness-session-summary.sh`

**Interfaces:** input `{harness, session_id, cwd, tail=50}` → record with `last_event_at`, `last_role`, `last_user_prompt_excerpt` (≤200 chars), `last_assistant_excerpt` (≤400 chars), `awaiting_input` (bool: last line is assistant text ending in `?` or a permission/`AskUserQuestion` tool use), `event_count`. Remote via `ssh <host> tail -n`.

- [x] Tests: Claude fixture → correct fields; missing session → `error.kind=not_found`, exit 2; unsupported harness → exit 3; excerpt lengths bounded; Pi fixture parsed; Codex → `error.kind=unsupported` recorded honestly until a real store exists.
- [x] Implement; PASS; live run with this session id from `herdr agent list`. Commit.

### Task 2.4: `gh:work` and `git:recent`

**Files:** `task-modules/bin/gh-work`, `task-modules/bin/git-recent`, `task-modules/evidence.nix`, fixtures (canned `gh` JSON via fake `gh` on PATH; a throwaway git repo), tests

**Interfaces:** `gh-work --repo OWNER/REPO [--ref N]` → `{issues:[{number,title,state,updated_at,labels}], prs:[{number,title,state,review_decision,checks,merged_at}]}` bounded to 20 each. `git-recent --checkout PATH [--since 24h]` → `{head, branch, dirty, ahead, behind, unpushed:[sha subj], commits:[sha,at,subject]}`; checkout must be in fleet.json `repos[].checkout`.

- [x] Tests: fake gh output parsed; gh failure → `error.kind=gh_error`; checkout outside allowlist → exit 3; dirty/unpushed detection on a fixture repo.
- [x] Implement; PASS; live run on `~/skills-epic16` and `sammasak/skills`. Commit.

### Task 2.5: `work:status` and `coord:brief` DAG

**Files:** `task-modules/bin/work-status`, `agents/coordinator/tasks.nix` (`work:status` after `herdr:inventory@completed harness:session-summary@completed gh:work@completed git:recent@completed`; `coord:brief` after `work:status`), `agents/coordinator/tests/test-coord-brief.sh`

**Interfaces:** `work-status` reads `DEVENV_TASKS_OUTPUTS`, joins agents to `task_ref` (from terminal title `#N` or session cwd→repo), emits per-item `{agent, herdr_state, work_verdict: verified|unverified|blocked|unknown, needs_owner: bool, reasons:[..], sources:[{task, observed_at}]}` plus `partial: true` + `failed_sources` when any upstream errored. `coord:brief` renders a ≤40-line Markdown summary from it and also writes the JSON.

- [x] Tests: done agent + no merged PR → `unverified`; blocked agent → `needs_owner:true`; upstream failure → `partial:true` with `failed_sources` and exit 0; all upstream failed → exit 2; `herdr_state` and `work_verdict` are distinct keys.
- [x] Implement; `devenv tasks run coord:brief --show-output` live. Commit.

### Task 2.6: Skill `herdr-operations` + eval + live read-only run

**Files:** `skills/herdr-operations/SKILL.md` (≤80 lines: when to run which task, how to read records, never infer completion), `evals/herdr-operations/trigger.yaml` (positives/hard_negatives/true_negatives), update `agents/coordinator/ROLE.md` skills list, `tests/test-plugin-manifests.sh` passes.

- [x] Write skill + trigger eval; run `uv run python -m runner.trigger --skill herdr-operations` (token from `/run/secrets/claude_oauth_token`); record result. *(herdr-operations 5/5 positives, hard negatives routed to agent-handoff/agent-orchestration/pi-offload; one true negative about a Rust lifetime error routed to rust-engineering, not a herdr-operations fault)*
- [x] Start Claude as `claude --agent coordinator --permission-mode default` in a pane; ask "what are my agents doing"; capture that it ran only allowlisted tasks (check session JSONL tool_use names). Record evidence on #16. *(2026-10-26 `claude -p --agent coordinator` session 62135646: 5 turns, 18s, $0.11; tool calls = Read ROLE.md, `devenv tasks run coord:brief --show-output`, one `grep` blocked by the guard (1 permission denial), Read of the tool-result file; answer kept herdr=working separate from work=unverified, cited PR #17, declined to merge. Dev-host setup: symlinks for adapter/guard/skill + COORDINATOR_CHECKOUT; the M3 launcher replaces that)*
- [x] Open PR "epic-16 M1: read-only coordinator"; subagent review; fix; owner merge gate. *(PR #18, 3 review rounds → 9/10; HEAD 2c32169 adds `-i <key> -o IdentitiesOnly=yes` on the ssh command line; owner gate: merge)*

## Slice 3 — M2: explicit handoffs and idempotent communication

### Task 3.1: `coord:handoff` (draft only)
- Files: task in `agents/coordinator/tasks.nix`, `skills/agent-handoff/SKILL.md`, `agents/coordinator/tests/test-coord-handoff.sh`.
- [x] Input `{host, agent_id, task_ref, scope, expected_evidence, acceptance}` → brief Markdown + JSON with `handoff_id = sha256(host|agent_id|task_ref|text)[:12]`, saved to `$state_dir/handoffs/<id>.json`, `approval_required:true`. Tests: missing fields exit 3; id stable; nothing sent (fake ssh log empty).

### Task 3.2: `herdr:message` + audit + duplicate detection
- Files: `task-modules/bin/herdr-message`, `herdr.nix`, tests with fake herdr that can simulate `agent_blocked`, `timeout`, success.
- [x] Requires `handoff_id` of an existing draft and `confirm: "<host>/<agent_id>"` literal; refuses if target state is `blocked`; refuses if an audit entry for the same handoff exists unless `--resend <audit_id>`; appends `$state_dir/audit.jsonl` `{audit_id, handoff_id, host, agent_id, at, outcome}` before and after sending; timeout outcome recorded as `unknown_delivery`. Not in any adapter allowlist (permission prompt is the gate). Negative test from Task 1.4 keeps asserting it is not allowlisted.

### Task 3.3: `herdr:await`
- [x] Wraps `herdr agent wait <id> --until idle --until done --until blocked --timeout <ms>` (two-phase: observes the turn start first, `since_seq` from the message record); record distinguishes `herdr_state`, `receipt` (prompt accepted), `worker_done` (state), `accepted` (always false here; comes only from `work:status` evidence). Tests: timeout → `error.kind=timeout`, exit 2.

### Task 3.4: Supervised two-agent scenario
- [x] Local first: two Claude panes on this host (one plain worker given a trivial doc-only task in a scratch repo), coordinator inspects → handoff → owner confirms → message → await → work:status shows `unverified` until a commit lands, then `verified`. Capture JSON + transcript excerpts to #16. Cross-host (lenovo↔acer) repeat recorded as owner gate if SSH still unavailable. *(2026-10-26 on acer-swift, worker = `claude --model claude-haiku-5-5 --permission-mode acceptEdits` in Herdr pane wF:p2, task operator = this session (not an owner approval). Run 1: worker stuck at Claude's trust-folder dialog → inventory `blocked`, `herdr:message` refused `agent_blocked`, `work:status` `needs_owner`. Run 2 after unblocking: handoff 6892efec9044 → message `delivered` (audit 3d0eefff9732 attempt+outcome) → await idle/worker_done → inspect shows the worker's reply → NOTES.md contains the line, tree dirty → work:status herdr=idle, work=`unknown` (no #N on the pane) + "1 uncommitted file" → duplicate send refused naming the audit id. Bug found: `herdr:await` returned immediately on an idle agent before the turn started (fixed in M2: observe the turn start first).)*
- [x] Tests for authorization refusal, malformed JSON, duplicate, agent restart (pane id change → `error.kind=agent_missing`), wrong-host identity. *(`task-modules/tests/test-herdr-message-await.sh` 75 checks: wrong confirm, missing draft, malformed `--input-json` refused by the guard, duplicate → `resend` required, `agent_changed`/`agent_restarted` on session or seq change, wrong host refused at eval)*
- [x] PR "epic-16 M2"; review; owner merge gate. *(PR #19, 5 review rounds → 9/10 (207940f), now 63a30c1 with M1 merged forward; owner gate: merge)*

## Slice 4 — M3: nixos-config opt-in coordinator module (lenovo first)

- [x] In `~/nixos-config-epic16`: `modules/programs/cli/coordinator/default.nix` exposing `sam.profile.coordinator` + `sam.coordinator.fleet` *(PR sammasak/nixos-config#103, branch epic-16/coordinator-role @ 1196acd; launcher + rendered settings + guard link + per-rev writable checkout; needs skills input bump after #17/#18 merge)* — originally planned as `sam.coordinator.enable`, `sam.coordinator.fleet` (hosts/repos → renders `~/.config/coordinator/fleet.json`), installs `jq`, the `task-modules/bin/*` from the `skills` input as a package, symlinks `agents/coordinator.md` (already via skills.nix), adds the Claude permission allowlist for the coordinator agent only, `herdr` user service already present on devTools hosts. No `devTools` flag changes.
- [x] `nix eval`/`nh os build -H lenovo` under the heavy-work lock (or `nixos:qa` devenv task); `just diff` output recorded; module doc with activation (`just switch` on lenovo by owner) + rollback (`nixos-rebuild --rollback` / previous generation) + verification (`claude --agent coordinator`, `devenv tasks run coord:brief`). *(acer as builder under the lock: `nix eval` of lenovo with the role enabled → no failing assertions, ssh block, launcher export and self-healing activation asserted by eval; launcher `nix build` ok; toplevel dry-run recorded in the effort log. `just diff` is only meaningful on lenovo itself → owner step. docs/coordinator.md carries activation, rollback (by generation; pin revert alone fails eval) and verification)*
- [x] Measure on acer (proxy) and record: cold/warm `coord:brief` wall time, RSS of claude + tasks, CPU; k3s health before/after via `kubectl top`/node conditions if reachable. *(2026-10-26 19:03 UTC on acer-swift (16 GB, load 0.54): `coord:brief` cold (eval cache refreshed) 4.56 s wall / 418 MB peak RSS / 2.6 s CPU; warm 2.43 s / 75 MB / 0.64 s CPU; one `claude -p --agent coordinator` fleet question (Sonnet 5.5) 27.6 s wall / 278 MB peak RSS / 4.2 s CPU, 5 turns, $0.11, 1 guard denial (a stray `tail`), `coord:brief` the only task; herdr daemon RSS 42 MB. k3s health not measurable from acer (no kubeconfig); 10.7 GB RAM stayed available)*
- [x] PR in nixos-config; independent review; **owner gates:** merge + `just switch` on lenovo. If granted: fresh SSH → `claude --agent coordinator` → fleet status → inspect one blocker → authorize a message → retrieve answer; record latency/RAM; else label "deployment-ready pending owner activation". *(PR #103 open, 7 review rounds (6/10 CRITICAL fixed → 8.5/10 "nothing should block owner merge"), HEAD 17638e1; activation and canary wait on the owner → labelled at close-out)* *(the line's else-branch holds: PR #103 open and reviewed (9.5/10 confirmation), owner has not merged or switched, epic labelled "deployment-ready pending owner activation" on #16; the canary itself stays in M3 on #16 as an owner step)*
- [x] Optional black-pi stretch only if the owner asks: check `nix path-info --store https://cache.nixos.org` substitutability for aarch64 claude-code/nodejs/herdr first. *(not asked; the owner redirected to lenovo on 2026-10-26 ("Lets not overfit on it being hosted on black-pi"), so no aarch64 substitutability check was run)*

## Slice 5 — M4: second role proves reusability

- [x] `agents/quality/ROLE.md` composing skills `rust-engineering`, `sdlc-pipeline`, `orchestrated-review` and tasks `sdlc:*` from devenv-platform (via a fixture consumer repo under `agents/quality/fixtures/rust-consumer` importing `~/devenv-platform-epic16` by path) plus `quality:report` (reads `$DEVENV_STATE/sdlc/*` stamps/red records → record schema v1). *(PR #20: role + `quality:report`/`quality:gate` wrapping the consumer's own `sdlc:*` tasks; deviation from plan: no fixture consumer under `agents/quality/fixtures`, the live check ran against devenv-platform `examples/rust-service` and the suite uses a fake devenv)*
- [x] Claude adapter `agents/quality.md` and Codex adapter `agents/quality/AGENTS.md` (+ `.agents/plugins` entry if needed); contract test extended to both roles; same fixture run through `claude -p --agent quality` and `codex exec` with identical instruction; outputs compared field-by-field; differences recorded as adapter limitations, not hidden. *(adapters + contract test over both roles done; the Codex half of the identical-input run is blocked on OpenAI credentials (owner gate) → stays open; limitations recorded in `agents/quality/AGENTS.md`)* *(BLOCKED on owner: OpenAI credentials = spending money; everything else on the line is done)* *(OWNER WAIVED 2026-10-26 21:50 UTC, verbatim "Drop the Codex requirement"; Claude half proven, Codex half not run, no parity claimed)*
- [x] Evals: trigger evals for new skills; negative permission tests for quality role (no `git push`, no merge); upgrade/rollback check: pin bump of skills input in nixos-config evaluates (`nix eval`) and `git revert` of the bump evaluates. *(no new skills in M4 (reuses sdlc-pipeline/rust-engineering/orchestrated-review, evals unchanged); negative tests: `agents/quality/tests/test-quality.sh` 26 + per-role cases in `tests/test-coordinator-negative.sh`; upgrade/rollback: lenovo eval with the skills pin bumped to epic-16/m4-quality → ok; pin reverted to main's 2730201 with the profile still enabled → eval fails (`agents/coordinator.md` missing), with the profile disabled → ok; recorded in nixos docs as "roll back by generation")*
- [x] `docs/operator-runbook.md` + `docs/adding-a-role.md` (third role by composition, no bespoke scripts). PR; review; owner merge gate. *(PR #20, 6 review rounds (9/10 at fe3162f base; sixth pass 8/10 on the Codex-half hardening, fixes in e73bc0c); owner gate: merge)*

### M4 progress log
- [x] `agents/quality/ROLE.md`, `agents/quality.md` (Claude), `agents/quality/AGENTS.md` (Codex), `agents/quality/permissions.json`; shared `hooks/validate-role.sh` reads any role's `tasks.{read,run,act}` from ROLE.md (coordinator/quality are 1-line wrappers); `quality:report` (sdlc-status is the authority) and `quality:gate` (runs one `sdlc:<stage>`), fake devenv + SDLC fixtures, 19 assertions; contract test asserts the awk parser equals the yq parser; negative suite drives the quality guard (95 assertions). Branch `epic-16/m4-quality` @ 8697fd5.
- [x] Two-harness proof script (`agents/quality/tests/two-harness.sh`) and the **Claude half**: `claude -p --agent quality` in a throwaway copy with `devenv.local.nix` → one task call (`quality:report --input-json`), no gates, all 8 fields (6 stages, HEAD, ALL_GREEN) correct, 0 denials, $0.02. Guard honoured only at settings level (recorded in the RFC). The parity run found the errexit glob bug in `quality:report` (fixed f97cc06).
- [x] **Codex half blocked: no OpenAI credentials on acer-swift** (`codex login status` → Not logged in; nixos seeds from `/run/secrets/openai_api_key`, absent here) — owner gate; the script skips Codex and says so. *(OWNER WAIVED 2026-10-26 21:50 UTC, verbatim "Drop the Codex requirement"; Claude half proven, Codex half not run, no parity claimed)*
- [x] `docs/operator-runbook.md` + `docs/adding-a-role.md`.

## Slice 6 — Close-out

- [x] Tick #16 checkboxes only for verified items; link all PRs/SHAs/task exit codes; label activation state honestly; update this file's effort log; final comment with "what the owner must do next" list. *(2026-10-26 19:58 UTC: #16 body ticked for verified items only (M3 canary, M4 two-harness, cross-host and activation stay open with the owner step named), label "deployment-ready pending owner activation" applied, close-out comment with the PR table, grades, late changes and the six owner steps)*

---


## Slice 7 — Owner redirect (2026-10-27 08:23 UTC): lean subagent model, no wrapper

Owner, verbatim: *"I think we have OVERENGINEERED the coordinator - what I asked for was agents in the skills repo with devenv tasks - meaning that I just open claude code/codex and we can chat with this coordinator subagent. This is its own wrapper that we did not ask for."*

Consequence: the launcher / materialised-checkout / integrity-pin / dedicated-key mode built in nixos-config #103–#105 is not the deliverable. The deliverable is the subagent: `agents/coordinator.md` and `agents/quality.md` linked like every other agent, running the devenv task DAGs from one writable skills checkout on the host. Phase B (two-host over a restricted key) is superseded: a subagent runs inside the owner's session and uses the owner's own ssh. Defaults taken (owner may override): nixos coordinator module kept dormant, not deleted; task checkout `$SKILLS_CHECKOUT`, default `~/claude-code-skills`.

- [x] skills: adapters work as subagents from any cwd: hook resolves the guard from the checkout, command form `cd <checkout> && devenv tasks run <task> …` accepted by the grammar, no launcher/pin assumptions; role text, runbook, RFC and tests updated; `skills:test` green; PR reviewed. *(skills #21 merged → main 2fc151d; 4 review rounds (6→7→8.5→9) + confirmation; dispatcher at settings level, textual cd check, fail-closed on stale checkout; skills:test 0)*
- [x] nixos-config: `skills.nix` links role adapters again; lenovo `coordinator = false` (module dormant, documented as optional hardened mode); #105 closed unmerged; PR reviewed; owner merges + `just switch` on lenovo. *(nixos #106 merged → main 4cb9422 (pin 2fc151d, dispatcher registered, eval assertion); #105 closed unmerged; owner `just switch` on lenovo + acer pending)*
- [x] Live: from a normal Claude Code session on a dev host, delegate to the coordinator subagent → it runs `coord:brief` from the checkout and answers; same with the quality subagent (`quality:report`). Codex: `codex exec --cd <checkout>` with `agents/quality/AGENTS.md` as context (credentials still owner-waived). *(2026-10-27 08:44 UTC on acer: plain `claude -p` from a scratch dir with the dispatcher in project settings; probe role's `echo` BLOCKED with the guard reason, coordinator ran only `cd <checkout> && devenv tasks run coord:brief --show-output` + `work:status`, 38 s, $0.21, 1 denial; quality subagent not separately exercised (same guard path, `quality:report` proven live earlier); Codex waived)*
- [x] #16: record the redirect verbatim; re-state which checklist items the subagent model satisfies and which are superseded; final comment. *(2026-10-27 09:05 UTC: redirect quoted, two-host item marked superseded, final comment with the three owner steps; 30/30 items ticked)*


## Slice 8 — Owner rule (2026-10-27 11:34 UTC): no .sh files, devenv tasks only

Owner, verbatim: *"I dont want us to have a .sh files I want them to be devenv tasks!!!"* Boundary chosen with the owner: everything except the single hook entry Claude Code's hook contract requires.

- [x] `task-modules/lib.sh` → Nix prelude; fake ssh/herdr/gh/devenv → Nix packages (`coordinator.fakes`); every suite → a devenv task (`skills:test:*`); guard → `task-modules/guard.nix` (`guard:check`, `guard:integrity`, shared `coordinator.guardLib`); parity → `quality:two-harness`; one shell file left: `hooks/role-guard-dispatch.sh`. skills PR #23 (eca2e26), `skills:test` 0 on 15 tasks. *(lessons: the task runner enables errexit so suites set `+e`; a quote before an interpolation needs `${"'"}''${` in Nix indented strings; `command -v` returns alias names, use `type -P`)*
- [ ] Independent review of #23 → fixes → owner merge; nixos-config follow-up (dormant launcher → dispatcher + `guard:integrity`, pin bump) merged; `just switch` on both hosts; live subagent check with the task-based guard.

## Effort log

| When (UTC) | Slice / task | Commit / PR | Tasks run (exit) | Outcome / limitation |
|---|---|---|---|---|
| 2026-10-27 11:48 | #23 review 1 (6/10, two CRITICALs) → store-built guard | skills #23 @ 694c593; nixos branch epic-16/guard-as-tasks @ c58d375 (local) | skills:test (0); negative 218; binary smoke allow/ask/block; live smoke 8 (env-prefixed hook command as nixos registers it): probe blocked, coordinator ran tasks, 3 denials, 44 s | guard library = `task-modules/guard-lib.nix`; nixos builds it into a store binary and hands `ROLE_GUARD_BIN` to the dispatcher (60 ms warm); devenv `guard:check` is the fallback under an inner timeout (cold 3.5 s, hook 15 s); timeouts and crashes exit 2; checkout vouching for itself fixed; pre-existing hook-framework scripts recorded as an owner scope decision |
| 2026-10-27 11:34 | Slice 8: no .sh files (owner rule) | skills #23 @ eca2e26; nixos branch epic-16/guard-as-tasks (local) | skills:test (0) ×5 rounds; guard:check + dispatcher live allow/block; lenovo (dormant mode) + acer eval (0) with the branch | 40 files, −1711/+1855; suites as tasks, guard as tasks, fakes in Nix; review running |
| 2026-10-27 09:28 | lenovo activated | lenovo system 6c7srvrd… (main 4cb9422) | owner paste: HM active (exited) after moving the stale settings.json.backup; just switch finished | both hosts on the subagent model; lenovo checkout reset + subagent check pending; owner declined an overwriteBackup PR (not created) |
| 2026-10-27 09:23 | Host activation | acer switched (vhylgr4s…); lenovo system switched, HM failed on a stale settings.json.backup | acer production check: coordinator subagent ran coord:brief only, stray grep BLOCKED by the installed dispatcher, 47.5 s, $0.36, 1 denial | acer prep: skipped 2 never-activated weekly lock commits; ~/claude-code-skills reset to origin/main (old history on branch local-pre-squash-2026-10-27); fleet.json repo path updated. lenovo fix: move the stale backup, restart home-manager-lukas.service, pull ~/claude-code-skills, run the same check |
| 2026-10-27 09:05 | Slice 7 merged | skills #21 → main 2fc151d; nixos #106 → main 4cb9422 | skills:test (0); lenovo+acer eval (0) with the new pin | subagent model live on main; owner steps: `just switch` both hosts, `git pull` ~/claude-code-skills, try "ask the coordinator …" |
| 2026-10-27 08:53 | #21 review 2 (7/10) → dispatcher fail-closed rework; final live smoke | skills #21 ee54cf6; nixos #106 a30cc74 | skills:test (0), negative 209; live smoke 6: probe blocked, coordinator ran coord:brief + work:status only | role set and guard logic now come from the shipped (store) copy; stale/missing checkout refuses instead of un-guarding; any guard crash → block; third review running; then merge #21 → pin bump in #106 → merge #106 → `just switch` lenovo + acer |
| 2026-10-27 08:44 | Slice 7: two harness findings + fixes | skills #21 second commit; nixos #106 second commit | skills:test (0), negative 171; live subagent smoke (probe blocked, coordinator ran tasks) | FINDINGS: (1) a subagent's frontmatter hooks never run → guard moved to a settings-level dispatcher keyed on `agent_type`; (2) a hook command that cannot run (exit 127) is non-blocking → install from the store; review 1 of #21 was 6/10 (cd target resolved physically vs bash logical) → textual absolute-path check; my probe smoke first used `git archive HEAD` without the uncommitted dispatcher (same mistake class as reviewed before) |
| 2026-10-27 08:31 | Slice 7: subagent mode PRs | skills #21 (24dc334); nixos #106 (781d705); #105 closed unmerged | skills:test (0) incl. 13 new guard cases (negative 148/148); lenovo+acer eval (0) | guard resolves the checkout itself and accepts `cd <checkout> && devenv tasks run …` from any cwd; adapters/runbook/RFC rewritten for subagent use; lenovo launcher off, adapters linked again; reviews running; live subagent smoke on acer next |
| 2026-10-27 08:23 | Owner redirect → Slice 7 | — | — | wrapper (launcher, pin, shim, phases) was not asked for; re-planned to the subagent model; #105 left unmerged; two-host item superseded (subagent uses the owner's ssh) |
| 2026-10-27 08:15 | Phase B PR (owner key + acer target) | nixos #105 @ 594fbcd | lenovo+acer eval (0); lint (0) | owner topology decision quoted ("Acer will always be worker; only one host will ever act as the coordinator"); key generated by the owner on lenovo; `acer-swift` unresolvable under -F none → LAN 192.168.10.110; boot sanity on lenovo confirmed (vfat ESP, systemd-boot 261.3); review pending, then deploy order acer → lenovo → shim probe → cross-host canary |
| 2026-10-27 08:06 | Lenovo canary (owner-run) | nixos main 8c0284a live on lenovo | `coordinator -p` fleet question: 6 turns, 19.3 s, $0.16, 1 denial; coord:brief 13 s cold | phase A DEPLOYED; label removed from #16; M3 canary + black-pi-as-lenovo proof ticked with caveats (k3s impact, resume/reconnect not re-measured); open: phase B two-host verification (needs key + acer target from the owner); boot sanity output still requested |
| 2026-10-26 21:50 | Owner ran `just switch` on lenovo (phase A active); Codex requirement waived | nixos main 8c0284a (#104 merged) | owner paste: switch finished, home-manager-lukas.service restarted, no error | canary pending (owner to run `coordinator`); /boot "Created directory" lines flagged for a bootctl sanity check; waiver quoted on #16 |
| 2026-10-26 21:34 | Phase A deploy PR nixos-config#104 reviewed (8.5 → fixes → confirmation 8.5 → fixes), ready | nixos #104 @ 6a3af23 | lenovo+acer eval (0); lint (0); lenovo dry-run 23 glue drvs; skills bump diff: 6 user-scope hooks identical, global-context.md = M0 policy rewrite, 8 SKILL.md refreshed | role adapters no longer linked into user scope (inert + delegation noise); deploy signal given to the owner: merge #104 → `just switch` on lenovo → `coordinator` canary |
| 2026-10-26 21:26 | Owner: "Merge all prs" → merges; phase A deploy PR | skills main 22b61f7 (#17–#20 merged); nixos main 8a5674a (#103); nixos #104 (560ebd2) | skills:test (0) on main; lenovo+acer eval (0); lenovo dry-run 23 glue drvs | owner decision quoted on #16; phase A = local-only fleet on lenovo (no key yet); deploy = merge #104 + `just switch` on lenovo + canary; phase B needs the dedicated key |
| 2026-10-26 20:00 | Stop-hook check | f55c904 | — | Goal condition unmet and not reachable by an agent: remaining items are owner merges, lenovo switch, dedicated key, SSH authorization and OpenAI credentials (money). No explicit owner deferral exists in the transcript, so the label is a status, not an acceptance. Decision requested from the owner: activate now, or explicitly defer |
| 2026-10-26 19:58 | Slice 6 close-out | m4 781893e (code), #16 comment + label | skills:test (0) final | buildable scope complete; terminal state = deployment-ready pending owner activation; owner steps listed on #16 |
| 2026-10-26 19:53 | #20 review 9 + confirmation, #103 confirmations ×2 | m4 dd1b62e, aa4c884; nixos 5bee015 | skills:test (0); nixos:lint-comments (0); nix eval lenovo (0; `%` rejected) | #103 9.5/10 confirmed; #20 9/10 then 9/10 on the fix commit: probe keeps the role denies, manifest held in memory, `listed()` without a pipe (SIGPIPE under pipefail found by review), control-char refusals pinned by reason; both PRs "nothing blocks owner merge" |
| 2026-10-26 19:41 | #103 reviews 9 + 2 confirmations, #20 review 8 → fixes | nixos a4185a4, f5dc766; m1 4a04445; m2 43ee494; m4 96cff12+36d78e4 | skills:test (0) on m1, m2, m4; nixos:lint-comments (0); nix eval lenovo (0; type rejects `~/`, `$HOME`, spaces) | #103 at 9/10 (nothing blocking): strict 64-hex pin in the activation, rebuild reason echoed, launcher checks the key is readable; my `[ -r '~/…' ]` regression caught by a confirmation review → identityFile is absolute-only. #20: probe made attributable (window counting, probe-only Claude settings, reversed-flags form), newline-only workdir and empty-pin fail-open closed, manifest snapshot against swap; exit codes 0/1/3 |
| 2026-10-26 19:25 | #18 delta review, #103 review 8, #20 review 7 → fixes; M1→M2→M4 merge-forward | m1 857ae18; m2 701829e; m4 4168f04+705bd67; nixos f33573f | skills:test (0) on m1, m2, m4; nixos:lint-comments (0); nix eval lenovo (0); predicate smoke (intact 0 / planted 1 / edited 1) | `-i`+IdentitiesOnly only ordered keys (a user `Host *` IdentityFile stayed a fallback) → `-F none` makes the dedicated key exclusive; one shared `hooks/lib/integrity-check.sh` for guard and activation; guard checks every workdir field (8 new negatives); parity script gained an enforcement probe (ENFORCED needs rc=2 in the guard log + no consumer call) and states the Codex sandbox cannot write fleet checkouts; reviews: #103 8.5 → 8.5 (not blocking), #20 8 → 8.5 (not blocking), #18 delta 9 |
| 2026-10-26 19:03 | #103 reviews 6–7 (CRITICAL fixed), #20 reviews 5–6, M3 measurements, upgrade/rollback eval, M1→M2→M4 merge-forward | nixos 12bc23f, 17638e1; m1 2c32169; m2 63a30c1; m4 fe3162f, e73bc0c + merge | skills:test (0) on m1, m2, m4; nixos:lint-comments (0); nix eval lenovo (0) | HM `programs.ssh` was never enabled so the match blocks reached no file → system ssh_config + `-i`/IdentitiesOnly on the command line; activation now self-heals a refused copy; Codex half: `$OUT` outside /tmp, sandbox scratch root, per-call `workdir` guard (vector found by review), hooks confirmed stable in codex-cli 0.162.1; reverting the skills pin alone with the profile enabled fails eval (rollback = previous generation); lenovo toplevel dry-run with the role on: 24 glue derivations to build (HM generation, user-environment, fish completions, man cache), no package builds, rest fetched |
| 2026-10-27 02:00 | Transport + shim + integrity pin; M4 round 2 | m1 4099cd9 (NUL-argv ssh transport); m2 a6435e2, m4 9ae2471 (merged); nixos f7118a4 (shim without eval, worker acceptKeys, pin + chmod a-w, Bash timeouts) | skills:test (0) on m1/m2/m4; shim marker checks (no escape); nixos lint + launcher build (pin exported) | **Own mistake logged:** a shim unit check used a real `rm -rf /` as a refused input and the loose template let it run; coreutils preserve-root refused it, nothing deleted; shim rewritten without eval, tests use harmless markers only. M4 re-review 2: 7/10 → integrity required+pinned, devenv.local covered, env allowlist, table window; third review running |
| 2026-10-27 00:30 | M2 reviews 3–5 (→9/10, 207940f); M4 review 1 (5/10) → hardening (f8a2fe8): real sdlc-status format verified live on rust-service, strict awk parser + fixtures, .integrity manifest, env scrub, bounds; M3 review 3 (8/10) fixes | m2 207940f; m4 f8a2fe8; nixos c00cbec | skills:test (0) on m2/m4 (negative 111, contract 77, message/await 75, quality 24); live quality:report on rust-service | Codex half owner-gated |
| 2026-10-26 15:00 | Survey (pre-plan) | — | manual probes | Versions, herdr CLI facts, devenv 2.4.0 task IO verified; acer→lenovo/black-pi SSH denied; `~/skills` in use by another session → `~/skills-epic16` |
| 2026-10-26 16:00 | Slice 0 kickoff | #16 comment | — | lenovo-first reinterpretation recorded; stale skill commands listed |
| 2026-10-26 17:30 | Slice 1 M0 (PR #17) | 8475e31, a35f049, 67e278a, f61a592 | skills:test (0): policy, manifests, contract, negative, hooks | Review 1: 5/10 (prefix-glob allows, pi-ticket stand-in, ssh fallback) → fixed with agent-scoped grammar hook + exact rules; re-review pending; owner gate: merge |
| 2026-10-26 18:30 | Slice 2 Task 2.1 first pass | bac4c5c (reworked) | task test 42/42, live inventory on acer-swift | **Owner redirect:** no standalone scripts; tasks + DAG only. Probe confirmed eval-time fleet → per-host tasks, `@completed` aggregation, `--option :path` override, cache invalidation |
| 2026-10-26 19:30 | M0 reviews 2–4 | f61a592, 22aa856, 8be175f, acdb376 | skills:test (0) each round | 6/10 → 7/10 → **9/10**; guard fails closed, exact-only rules, Read scoped; PR #17 comment carries the trail; #16 M0 boxes ticked (4/5; "minimum runtime permissions" waits for M3 measurements) |
| 2026-10-26 22:30 | M1 reviews 1–3 (PR #18), M2 scenario, M3 PR | m1 6bc564f, d59ac7b, 2c4caa3 (+ read-order fix); m2 fdc46b7; nixos-config PR #103 (1196acd) | skills:test (0) on m1 and m2; nixos lint-comments/lint-shell (0); nix build of the launcher against the m1 branch (0) | Review 1: 6/10 (cross-repo/branch verdict, unvalidated gh, aggregates losing records) → fixed; review 2: 7/10 (its `--` suggestion was WRONG: live herdr accepts only `agent read <id> --lines …`; title-only merged PR now needs the issue closed; base64 remote transport survives a fish login shell) → fixed; review 3 pending. Scenario against a Haiku worker in its own pane: delivered → awaited → verified file edit; found and fixed `herdr:await` returning before the turn started (two-phase). Owner rules recorded: cheap models for test workers; workers get their own Herdr workspace |
| 2026-10-26 21:00 | Slice 2 Task 2.6 + Slice 3 Task 3.1 | e039500 + next | trigger evals (herdr-operations 5/5; agent-handoff recall 50%→ description sharpened, rerun pending); live `claude -p --agent coordinator` smoke; handoff 16/16, brief 21/21 | Guard blocked the agent's `grep` live; brief now prints Markdown and saves JSON to `$stateDir/brief/latest.json` so the agent reads instead of grepping |
| 2026-10-26 20:30 | Slice 2 Tasks 2.2–2.5 | a241253, e039500 | tasks suite: inspect 24/24, session-summary 18/18, evidence 24/24, coord:brief 20/20; live inspect + session summary on acer-swift | Full DAG runs 4 leaf tasks in parallel → aggregates → work:status → coord:brief; a `done` agent with only an open PR stays `unverified`; gh outage → `partial` + `unknown` verdicts |
| 2026-10-26 20:00 | Slice 2 Task 2.1 DAG-first | c64d896 | skills:test incl. tasks suite (0): inventory 41/41 | `herdr:list:<host>` per fleet host → `herdr:inventory@completed`; devenv drops failed tasks' outputs, so list tasks always complete and carry `error` as data |
