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
2. **Draft** with `coord:handoff`, copying `host`, `agent_id` **and
   `session_id`** from the inventory record so the send is bound to that
   agent, not just its pane:
   `devenv tasks run coord:handoff --input-json '{"host":"<host>","agent_id":"<id>","session_id":"<session>","task_ref":"#N","scope":"...","expected_evidence":"...","acceptance":"...","owner_input":"..."}'`
   Show the owner the returned `text` and `handoff_id` verbatim. Nothing has
   been sent.
3. **Confirm**: the owner must say, in this conversation, that this
   `handoff_id` may go to this `host/agent_id`. Silence, "looks good", or a
   general "go ahead" from earlier does not count.
4. **Send** with `herdr:message` (prompts for permission every time):
   `devenv tasks run herdr:message --input-json '{"handoff_id":"<id>","confirm":"<host>/<agent_id>"}'`
   It only sends to an `idle`/`done` agent and refuses: `agent_blocked`,
   `agent_busy` (mid-turn: wait, then send), `agent_changed` (session differs
   from the draft), an edited draft, and a second send of the same
   `handoff_id`. Read the record's `outcome`:
   - `delivered` → continue with step 5.
   - `unknown_delivery` or `agent_prompt_stalled` → the text may already sit in
     the agent's input box. Run `herdr:inspect`, report what you see, stop.
     Only the owner can ask for `resend`, and the task refuses one when the
     agent's state advanced in between (`probably_received`).
   - `agent_blocked`, `agent_not_found`, `audit_corrupt`, `busy` → nothing was
     delivered; report the kind and message verbatim and stop.
5. **Await** with `herdr:await`, passing the message's audit id so host,
   agent, session, `since_seq` and the delivery outcome come from the record
   (it refuses an undelivered attempt with `not_delivered`):
   `devenv tasks run herdr:await --input-json '{"audit_id":"<audit_id>","timeout_s":300}'`
   The record separates `herdr_state`, `turn_observed`, `reached`,
   `worker_done`, `needs_owner`; `accepted` is always false here. On
   `no_turn_observed`, `agent_restarted`, `agent_changed` or `agent_not_found`,
   inspect the pane and report; do not resend.
6. **Verify** with `work:status`: only `work_verdict: verified` with its
   `evidence_ref` closes the loop. Report that, or report what is missing.
