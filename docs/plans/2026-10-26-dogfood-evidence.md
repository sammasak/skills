# Dogfood evidence, 2026-10-26

Host `acer-swift`, read-only, no full Rust builds. Raw outputs were kept in the session
scratchpad; excerpts below are verbatim.

## Run 1: Factum on a real Rust change (primary)

**Skill and why.** `rust-engineering` (Factum section): the task was "what does this Rust
commit affect, and which checks matter?" for one commit in a private 10-package Rust
workspace (3 files, +74/-2; names withheld because this repo is public). It touches a
shared logic crate, so the blast radius is not obvious.

**Discovery.** `command -v factum` → nothing on acer (Lenovo-only HM package). The pinned
build exists in the store: `nix eval …nixos-config?rev=6f18d82#nixosConfigurations.lenovo.pkgs.factum.outPath`
= `/nix/store/bi7zsbz7269ca2fcrjvklslawhkhrc0l-factum-0.2.0`, the same path present locally.
`factum --version` → `factum 0.2.0` (no source revision; tracked by factum#30 AC1).

**Invocations and results.**

| Invocation | Exit | Time | Result |
|---|---|---|---|
| `factum impact --diff change.patch` (bare PATH, no cargo) | 3 | 0.01 s | `factum: error: cannot load the workspace` / `` `cargo metadata` failed `` / `failed to start …: No such file or directory`. Clear, honest. |
| `nix develop -c factum impact --diff change.patch` | 0 | 0.32 s | `facts-impact/v0`, 9 roots, 30 KB JSON |
| `nix develop -c factum review --diff change.patch --format json` | 0 | 0.26 s | `facts-review/v3`, 5 KB |
| `factum review --diff change.patch` (human) | 0 | <1 s | excerpt below |
| `factum review --diff <a/b-swapped patch>` | 2 | — | `usage error: diff path without a git a/ or b/ prefix (line 1)` |
| `factum review --diff <plain text>` | 2 | — | `usage error: the diff is empty` |
| `factum review --diff /nonexistent.patch` | 2 | — | `usage error: No such file or directory (os error 2)` (path not named) |
| `factum brief --help` | 2 | — | `usage error: unknown or repeated flag --help` + full usage; `factum help` exits 0 |

`target/` mtime and `git status` of the workspace were unchanged after every run (no compile, no writes).

```
Changed: 1 entity in <app>, 3 entities in <logic> (+4 cfg(test)).
Referenced by: <app> (1 site; also changed).
5 more packages compile against <app>, <logic> without directly referencing the changed items (dependent_only).
Note: 2 changed items are a type, trait, impl, module or crate; D9 does not model type users, so dependent_only is not evidence of no use.
…
unavailable: compiler_semantics, feature_target_cfg, test_inventory
verification: not_run (factum review composes existing impact facts; it never compiles, lists or runs tests)
```

**Did it help?** Yes, within its stated scope. In 0.3 s it showed that the new
function has exactly one caller (wasm-only, also changed), so the targeted checks are the
logic crate's unit tests plus the app's wasm build. It also named five `dependent_only`
packages and said plainly that this is not evidence of no use.
It does not replace `rust:ci`; it says so itself (`verification: not_run`).

**Confusing or broken.**
1. `factum <cmd> --help` is a usage error (exit 2); only `factum help` works. Every agent
   tries `<cmd> --help` first.
2. Cost is undocumented outside source: `brief` and `tests-for` compile through
   `cargo nextest list`, while `review`/`impact` never compile (`crates/factum/src/main.rs`
   module doc). Neither the README nor nixos-config `docs/factum-pilot.md` says so; on
   memory-constrained hosts that decides whether an agent may run it. I did not run
   `brief`/`tests-for` for this reason.
3. The README's command list ("Two products") omits `review`, `brief` and `tests-for`,
   the commands the pilot guide leads with.
4. A missing `--diff` file is reported without its path.

**Owner and draft.** `sammasak/factum`; all four belong under the open factum#30 (CLI adoption
tracking issue), which asks for a recorded dogfood result. Draft comment (not posted):

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

## Run 2: platform.sdlc on a non-Rust machine (secondary)

**Skill and why.** `sdlc-pipeline`: the skill's description hardcoded the rust preset; the
question was whether an agent discovers a repo's real stage machine.
Target: devenv-platform `e23f544` (= nixos-config pin) `examples/consumer`, a fresh clone in
the scratchpad, devenv 2.4.0.

| Invocation | Exit | Result |
|---|---|---|
| `devenv shell -q -- sdlc-status --context` | 0 | `SDLC machine: consumer -- database (unverified) -- not yet verified` + brief (15 s, first eval) |
| `jq -c '{schemaVersion, order, stages}' "$SDLC_MACHINE"` (in shell) | 0 | `schemaVersion 1`, `order ["database","integration"]`, guards `postgres:verify`, `consumer:integration` |
| `sdlc-status` (digest) | 0 | table, both stages `unverified` |
| `sdlc-status --bogus` | 2 | `sdlc-status: unknown mode: --bogus` |
| `sdlc-status --context` without `$SDLC_MACHINE` | 1 | `$SDLC_MACHINE not set; is platform.sdlc.enable on?` |
| `devenv tasks list \| grep sdlc:` | 0 | 5 tasks: `sdlc:done → integration → … → database-postgres-verify` |

**Did it help?** Yes: the machine is discoverable in two commands and contradicts the old
description (no sketch/model/test). **Confusing:** `sdlc-status` exits 0 with every stage
unverified; correct by design (read-only, `sdlc:done` decides) but easy to misread as a pass,
so the skill now says so. Benign notice: `devenv 2.4.0 is newer than devenv input (2.2.2)`.
No product defect found; no issue draft.

## Supporting verification: nix-audit commands in the skill

Not a dogfood of nix-audit (owned by the nix-audit agent); only the commands cited in
`nix-audit-operator` were executed, inventory-only, against the pinned `12d640a` and rc1
`bbd58d5` store builds. Results are in the skill commit messages and the coordination thread:
`scan --no-scan --policy` exit 1 / `complete:false`; `diff --gate` on two `--no-scan`
snapshots exit 3; a bogus flag leaves an existing `--json-out` file; `diff | head` exit 3 on
`12d640a` only (already fixed on main).
