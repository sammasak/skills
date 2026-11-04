# Coordinator continuity: event-driven wake-ups, zero LLM idle polling (#36)

24/7 availability, not 24/7 inference. The Coordinator is woken by a cheap
deterministic check that starts a session only when something changed; when
nothing did, no Claude Code or Codex process is started. Everything below is
already on `main` (skills #39 to #54) and in nixos-config
(`modules/programs/cli/coordinator-wakeup.nix`); this page records why it is
built this way and where each acceptance criterion of #36 is proven.

## Herdr capabilities (checked on herdr 0.9.5, 2026-11-04)

| Primitive | Command or API | What it gives |
|---|---|---|
| Wait for one agent | `herdr agent wait <pane> [--until idle\|done\|blocked\|working] [--timeout MS]` | blocks until that pane reaches a state |
| Event stream | socket API `events.subscribe` / `events.wait` (`herdr api schema --json`), event `pane.agent_status_changed` (pane, workspace, `agent_status`) | push notification of every pane's state change |
| Live state | `herdr api snapshot`, `herdr agent list/get` | the current state of every pane, read on demand |
| Toast | `herdr notification show` | an owner-visible notification, no LLM |

Herdr can push pane state changes, but only to a process that stays
connected: `agent wait` and `events.subscribe` both need a long-lived
subscriber, which #36 rules out (no daemon, no event bus). They also see only
Herdr: a label the owner applies, a merged PR or a new approved issue is a
GitHub event no Herdr subscription reports. So the wake path is the smallest
fallback #36 allows: a systemd user timer on lenovo that runs one
deterministic check and exits.

## The wake path

1. `coordinator-wakeup.timer` (nixos-config, lenovo only,
   `sam.herdr.coordinatorWakeup.enable`) fires the oneshot service every
   `interval` (default 2 min, `OnUnitInactiveSec`, so never while a session
   runs).
2. The service runs `coord:changed {"consume": true}` from the skills
   checkout: about 0.6 s and 80 MB, no model call. It diffs Herdr's inventory
   (every saved machine), the audit log and `gh:repos` against the last
   snapshot and prints one line per actionable change: an agent blocked or
   newly done on a delivered handoff, a new agent, a new approved issue or PR,
   and the idle line (every worker idle or done while work is left, once per
   fleet+work fingerprint).
3. Empty stdout ends the run: no session. A non-empty stdout starts one
   headless, spend-capped Coordinator session with those lines as its prompt;
   it reads the brief, acts through the audited act tasks and exits.

## Acceptance criteria and their evidence

| #36 criterion | Where it is met |
|---|---|
| Herdr native capabilities verified, missing glue justified, no duplicated lifecycle management | The table above. Herdr owns panes, agents and their state; the skills tasks only read it (`herdr:inventory`) and send through `herdr agent prompt` (`herdr:message`). No second lifecycle. |
| Continue from a worker result without the owner re-pasting a prompt | `coord:changed` reports a delivered handoff's agent turning done or blocked, and the idle line; the wake session's prompt is those lines, and `coord:brief` plus `work:status` rebuild the rest (skills #39, #46, #51, #54). |
| Nothing actionable: no Claude/Codex invoked, no idle tokens | coord-changed suite: "unchanged fleet prints nothing", "stdout is empty when nothing is actionable"; nixos-config `coordinator-wiring` test: "the script exits before any model call when nothing is actionable or pending", "an empty change set ends before any session". Zero-invocation proxy: the journal logs every quiet tick's reason once, and no session line. |
| Duplicate or missed events never assign an issue twice or bypass a gate | A reported change is consumed into the snapshot ("a reported change is consumed"), so it never prints twice; a plain read never consumes (#42). The idle wake fires once per fingerprint (#46, #48). Sends still pass the label gate and the audit (`herdr:message`), one implementation handoff per item (ROLE.md autonomy block, #52), never to a Coordinator pane (#54). A missed tick is caught by the next one, since the check is a diff against state, not an event queue. |
| Restart recovery from existing GitHub/Herdr/audit evidence, no database | The snapshot is derived data under the state directory; an absent or unreadable snapshot is a baseline rebuild that tells the owner ("audit unreadable", baseline tests). Handoffs are rebuilt from `audit.jsonl`, verdicts from GitHub (`work:status`, #43, #47). |
| Scoped tests, review, low-risk pilot; the Home Manager change minimal, reversible, deploy-gated | Each PR above carries its suite and its review on the PR; the coordinator pilot report is #34. The host wiring is one option, `sam.herdr.coordinatorWakeup.enable`, lenovo only, and turning it on is a switch the owner approves. |
| Budget and loop stop conditions explicit | Below. |

## Stop conditions

- **Wake budget:** at most `coordinator.wakeMaxPerHour` sessions an hour,
  `coordinator.wakeMinGapSeconds` apart (#40); a deferred wake keeps its lines
  under `wake.pending` and says why on stderr (#54).
- **Spend cap:** each session runs with `maxBudgetUsd` (default 1.00 USD).
- **Failure back-off:** a session that exits non-zero keeps its lines
  pending; after two failed sessions they are parked in `pending.failed` and
  no further session starts until the owner clears it.
- **No endless retry of a refused act:** a refusal changes nothing the
  fingerprint or the snapshot sees, so the same work never wakes a second
  session; the act itself is audited once.
- **One campaign at a time:** `session.lock`; a run that cannot take it
  within 20 s exits 75 and toasts the owner.
- **Outages:** a GitHub failure skips the idle check for that run and says
  so (`idle_wake.skipped`); no Herdr host answering ends the run with
  nothing checked.

## Pilot and rollback

Pilot on lenovo: enable `sam.herdr.coordinatorWakeup.enable`, switch, and
watch `journalctl --user -u coordinator-wakeup` for a day. Quiet ticks log
their reason once; a session line appears only with an actionable change.
Rollback is one option: `sam.herdr.coordinatorWakeup.enable = false` and a
switch, or `systemctl --user stop coordinator-wakeup.timer` until then. Both
are owner actions.
