# Upstream documentation mismatches, 2026-10-26

Proposals only. Nothing here was edited or filed upstream; filing needs the owner's explicit OK
(`tooling-feedback`). Visibility: `nixos-config` is public, the others private.

| # | Owner | Mismatch (evidence) | Proposed small change |
|---|---|---|---|
| 1 | `sammasak/factum` (comment on #30) | README "Two products" omits `review`, `brief`; cost per command (`brief`/`tests-for` compile via `cargo nextest list`, `review`/`impact` never compile) is only in `crates/factum/src/main.rs`; `<cmd> --help` is exit 2 | add a command/cost/exit table to the README or USER-GUIDE; accept `<cmd> --help`. Full draft in [dogfood-evidence](2026-10-26-dogfood-evidence.md#run-1-factum-on-a-real-rust-change-primary) |
| 2 | `sammasak/nixos-config` | `docs/factum-pilot.md` lists `tests-for`/`brief` next to `review` with no cost note | one sentence: "`tests-for` and `brief` compile test binaries (`cargo nextest list`); `review`/`impact` do not" |
| 3 | `sammasak/nixos-config` | `modules/programs/cli/codex/default.nix` `portableSkillNames` omits `sdlc-pipeline`, `pi-ticket`, `verify-service`, so Codex and Pi (`~/.agents/skills`) cannot activate them; Codex `AGENTS.md` has no pointer to installed tools | owner decision: add the three if they are Codex/Pi-compatible (they use only Bash/Read/Agent semantics), or record why not |
| 4 | `sammasak/devenv-platform` | `docs/ADOPTING-SDLC.md` troubleshooting: "invoke the `sdlc-pipeline` walker skill (claude-code-skills)"; the repo is now `sammasak/skills` | rename the reference |
| 5 | `sammasak/nix-audit` | README says `--json-out` FILE is removed on exit 2/3; an arg-parse usage error (exit 2) leaves it (owner-reproduced on `bbd58d5`); pinned `12d640a` lacks `--json-out` while main documents it | owned and in progress by the nix-audit agent (PR #46 guide, pin-bump proposal); listed only so the skills side tracks it |

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
