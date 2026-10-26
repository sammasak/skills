---
name: agent-handoff
description: Use when the owner wants to hand work to a specific running coding agent, draft an assignment or brief for an agent, send an agent a message or prompt through Herdr, or wait for a running agent to answer and relay what it said. Drafts first, sends only after the owner confirms, and never treats a reply as acceptance. Not for reading agent status (herdr-operations), starting a new session on a host (agent-orchestration), or delegating small mechanical fixes to the Pi worker (pi-offload).
---

# Agent handoff (draft, confirm, send, await, verify)

Sending is the only act-class operation the Coordinator has. The sequence is
fixed; skipping a step is a boundary violation.

1. **Identify** the target from a fresh `herdr:inventory` record: exact `host`
   and `agent_id`. A `blocked` agent is never a target; tell the owner what it
   is waiting for instead.
2. **Draft** with `coord:handoff`:
   `devenv tasks run coord:handoff --input-json '{"host":"<host>","agent_id":"<id>","task_ref":"#N","scope":"...","expected_evidence":"...","acceptance":"...","owner_input":"..."}'`
   Show the owner the returned `text` and `handoff_id` verbatim. Nothing has
   been sent.
3. **Confirm**: the owner must say, in this conversation, that this
   `handoff_id` may go to this `host/agent_id`. Silence, "looks good", or a
   general "go ahead" from earlier does not count.
4. **Send** with `herdr:message` (prompts for permission every time):
   `devenv tasks run herdr:message --input-json '{"handoff_id":"<id>","confirm":"<host>/<agent_id>"}'`
   The task refuses a blocked or unknown-state target, a pane whose session
   changed since the draft, an edited draft, and a second send of the same
   `handoff_id`. Its record carries `audit_id`, `outcome`
   (`delivered|unknown_delivery|agent_blocked|…`) and `seq_before`. On
   `unknown_delivery` show the audit record and stop; only the owner can ask
   for a resend, and the task refuses one when the agent's state advanced in
   between (`probably_received`).
5. **Await** with `herdr:await` (bounded), passing the message's audit id so
   host, agent, session and `since_seq` come from the record:
   `devenv tasks run herdr:await --input-json '{"audit_id":"<audit_id>","timeout_s":300}'`
   The record separates `herdr_state`, `turn_observed`, `reached`,
   `worker_done` and `needs_owner`; `accepted` is always false here. On
   `no_turn_observed` or `agent_restarted`, inspect the pane with
   `herdr:inspect` and report; do not resend.
6. **Verify** with `work:status`: only `work_verdict: verified` with its
   `evidence_ref` closes the loop. Report that, or report what is missing.
