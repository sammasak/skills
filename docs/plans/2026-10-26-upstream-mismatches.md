# Upstream documentation mismatches, 2026-10-26

Proposals only. Nothing here was edited or filed upstream; filing needs the owner's explicit OK
(`tooling-feedback`). Visibility: `nixos-config` is public, the others private.

| # | Owner | Mismatch (evidence) | Proposed small change |
|---|---|---|---|
| 1 | `sammasak/factum` (comment on #30; draft below) | README "Two products" omits `review`, `brief`; cost per command (`brief`/`tests-for` compile via `cargo nextest list`, `review`/`impact` never compile) is only in `crates/factum/src/main.rs`; `<cmd> --help` is exit 2 | add a command/cost/exit table to the README or USER-GUIDE; accept `<cmd> --help`. |
| 2 | `sammasak/nixos-config` | `docs/factum-pilot.md` lists `tests-for`/`brief` next to `review` with no cost note | one sentence: "`tests-for` and `brief` compile test binaries (`cargo nextest list`); `review`/`impact` do not" |
| 3 | `sammasak/nixos-config` | `modules/programs/cli/codex/default.nix` `portableSkillNames` omits `sdlc-pipeline`, `pi-ticket`, `verify-service`, so Codex and Pi (`~/.agents/skills`) cannot activate them; Codex `AGENTS.md` has no pointer to installed tools | owner decision: add the three if they are Codex/Pi-compatible (they use only Bash/Read/Agent semantics), or record why not |
| 4 | `sammasak/devenv-platform` | `docs/ADOPTING-SDLC.md` troubleshooting: "invoke the `sdlc-pipeline` walker skill (claude-code-skills)"; the repo is now `sammasak/skills` | rename the reference |
| 5 | `sammasak/nix-audit` | README says `--json-out` FILE is removed on exit 2/3; an arg-parse usage error (exit 2) leaves it (owner-reproduced on `bbd58d5`); pinned `12d640a` lacks `--json-out` while main documents it | owned by the nix-audit agent: guide merged in PR #46 (`65e1444`), pin bump is a proposal awaiting owner approval; listed only so the skills side tracks it |
| 6 | `sammasak/nixos-config` | `pkgs/nix-audit/package.nix` fetches its pinned source over SSH inside a builder without ssh, so a cold-cache build fails (reported in nixos-config PR #95's body; feedback drafted by its owner) | owned by the PR #95 author; listed for tracking |

Draft for #2–#4 (one per repo, same shape):

````markdown
### docs: <one-line mismatch>
- Where: <file:line on main @ rev>
- Says: "<exact quote>"
- Reality: <observed command + exit code, or source reference @ rev>
- Proposed change: <one sentence>
- Found while: auditing sammasak/skills against installed tools (skills PR <link>)
- Not checked: <anything not run>
````

## Draft comment for factum#30 (not posted)

Sanitized: CLI behaviour only, no private workspace details.

````markdown
Dogfood record for #30 (agent, read-only), factum 0.2.0 = nixos-config pin 5bb7fa3,
run from /nix/store/bi7zsbz7…-factum-0.2.0 inside a consumer's `nix develop` shell.

Task: blast radius of a 3-file Rust commit (+74/-2) in a 10-package workspace.
`factum review --diff change.patch` → exit 0 in 0.26 s; correctly found the single
caller, 5 dependent_only packages, and disclosed `unavailable: compiler_semantics,
feature_target_cfg, test_inventory` / `verification: not_run`. Useful; no false claim seen.

Usability findings (each reproducible with any well-formed `git diff`):
1. `factum review --help` → exit 2 `usage error: unknown or repeated flag --help`;
   only `factum help` works. Expected: per-command help, exit 0.
2. Which commands compile is only in `crates/factum/src/main.rs` docs: `brief` and
   `tests-for` compile via `cargo nextest list`; `review`/`impact` never compile.
   Expected: README/USER-GUIDE states cost per command.
3. README "Two products" lists diagnostics/owner/entity/impact/tests-for/packet but not
   `review` or `brief`.
4. `factum review --diff /nonexistent.patch` → `usage error: No such file or directory
   (os error 2)` without the path.
Without cargo on PATH: exit 3 `cannot load the workspace … failed to start cargo metadata`
(clear; fine as is).

Not checked: `diagnostics`, `brief`, `tests-for` on this workspace (compile cost),
factum main (5812b62).
````
