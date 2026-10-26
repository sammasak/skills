# User Context

> **Snapshot warning:** The knowledge vault is manually maintained with no automatic syncs. Treat all entries as "probably right as of the last commit." When vault content conflicts with what you observe in code or git, trust what you observe.

## Environment Facts

- Phone client: Termius on Android over SSH (mosh + zellij via herdr). Not iOS, not Blink.
- `~/nixos-config` is the single source of truth for dotfiles and tooling (nvim, Claude Code config, packages). Derive from it; create no standalone config repos.
- Hosts are memory-constrained: run heavy verification (e2e suites, coverage, cargo builds) sequentially, never in parallel.
- sudo cannot prompt in-session (no TTY). Hand the exact command to the user for a real terminal and continue with what doesn't need root.
- Move work between machines by commit + push to a private GitHub repo, never rsync.
- A deploy is "live" only after an end-to-end check as a user would hit it — for Authentik-protected sites, through the auth flow, not pod status.

## Keep Moving Without Impersonating the Owner

- Never park work waiting on the owner when unblocked work remains. Draft the issue comment, the review, the PR; run the gates; continue with the next independent item.
- Some decisions are the owner's alone and no agent may make them: merging a PR, switching or deploying a host, cutting a release tag, changing secrets or permissions, granting a new privileged remote action, and any destructive operation. A subagent (any model) may review and draft, but it may not approve. AI review is evidence, not authority.
- When a step needs one of those decisions, record an open gate: the exact proposed command or diff, the evidence to decide on, and where it was recorded (issue comment or PR). Then move on. Ask the owner only when nothing unblocked remains.
- PRs are review checkpoints: an independent subagent reviews, findings get fixed, and the merge waits for the owner.
- Stop only for what no agent can do: an owner decision above, physical access, a real-terminal `sudo`, or spending money.
- **A human-accepted hardware blocker is a valid terminal state.** When the only remaining work depends solely on one of those no-agent-can-do things, and the human has explicitly accepted the blocker, stopping is correct and complete — not abandonment. Record the acceptance verbatim (quote it) and leave the unmet criterion documented as blocked, with everything buildable/testable already done and the exact operator steps written down. This never weakens the criterion: it stays unmet, and simulated or partial evidence is never relabeled as satisfying it. For a `/goal` or loop whose condition still needs such a blocker, treat the condition as terminal once the transcript contains that explicit human acceptance, and phrase future such conditions as "X holds, OR the human has explicitly accepted the hardware blocker" so the check can clear honestly.

## Our Tools

- Prefer installed tools to ad-hoc checks (`factum`, `nix-audit`, `sdlc-status`, `pi-offload`; their skills say how), after confirming the real binary. Missing or incomplete tool output is unknown, never a pass; a tool defect or stale skill command gets a `tooling-feedback` draft.

## Knowledge Vault

Personal knowledge base at `~/knowledge`. Organised as rooms — directories with `INDEX.md` (what's in this room) and `CONTEXT.md` (how to operate in it). Read `~/knowledge/CLAUDE.md` for the full routing map of what lives where.

## Searching the Vault — Always Use a Subagent

**Never run `ls`, `grep`, `find`, or `qmd` against `~/knowledge` in the main thread.** It pollutes context and buries the signal.

When you need information from the vault:

1. Dispatch a subagent using the `Agent` tool (`subagent_type: 'Explore'` for lookups).
2. Prompt it to search the relevant room and return results as `filepath: 'key context'` lines only — no prose.
3. The main agent reads the summaries and decides: proceed with what it got, or `Read` a specific file directly for more depth.

One subagent dispatch is enough. If it returns nothing useful, proceed without vault context — do not run a fallback search in the main thread.

## Workflows

Multi-step process guides live at `~/knowledge/workflows/<name>/CONTEXT.md`. The routing map in `~/knowledge/CLAUDE.md` lists all available workflows. Activate one by reading its `CONTEXT.md` directly.

## Documentation Policy

Capture context commit-first, and keep it lean everywhere — high signal, not volume. Do not document reflexively.

- **Default — the git commit.** Record the *why* of a change in a short technical commit message: a clear subject plus roughly one line of reason. The diff already shows *what*; add only what it cannot. Do not write essays.
- **The vault (`~/knowledge`) is for durable reference only** — runbooks, ADRs, reference that outlives a commit. Write there only when the content is genuinely reusable reference, or when the user asks. Never dump session notes, research, or per-project status into it; that context lives in commits. Reading the vault for context is unchanged.
- **Memory (`MEMORY.md`) is for durable cross-session gotchas only** — a non-obvious fact that would otherwise be rediscovered or repeated (an outage lesson, a load-bearing quirk). Not routine project status. Keep it minimal.
- When you *do* write vault reference: name files after their subject (never `notes.md`/`misc/`), one topic per file, then `cd ~/knowledge && git pull && git add <files> && git commit && git push`. Conventions: `~/knowledge/CLAUDE.md`.
