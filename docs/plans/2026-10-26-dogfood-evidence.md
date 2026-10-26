# Dogfood evidence, 2026-10-26

Host `acer-swift`, read-only, no full Rust or host builds; anything heavier than an eval ran
under `flock /tmp/$(hostname)-heavy-work.lock`. Private workspaces are described generically
because this repository is public. Issue drafts for private repositories are kept out of it.

## 1. Factum (rust-engineering)

**Why this skill:** "what does this Rust change affect, and which checks matter?" for one
commit in a private 10-package workspace (3 files, +74/-2).

**Discovery:** `command -v factum` → nothing on acer (Lenovo-only HM package). The pinned build
is `nix eval …nixos-config?rev=6f18d82#nixosConfigurations.lenovo.pkgs.factum.outPath` =
`/nix/store/bi7zsbz7269ca2fcrjvklslawhkhrc0l-factum-0.2.0`, present in acer's store; run from
there. `factum --version` → `factum 0.2.0` (no revision).

| Invocation | Exit | Result |
|---|---|---|
| `factum impact --diff change.patch` (bare PATH) | 3 | `cannot load the workspace` / `` `cargo metadata` failed `` / `No such file or directory`: missing tool reported honestly |
| `nix develop -c factum impact --diff change.patch` | 0 | `facts-impact/v0`, 0.32 s |
| `nix develop -c factum review --diff change.patch --format json` | 0 | `facts-review/v3`, 0.26 s; `unavailable: compiler_semantics, feature_target_cfg, test_inventory`; `verification: not_run` |
| `factum review --diff <a/b-swapped patch>` | 2 | `usage error: diff path without a git a/ or b/ prefix (line 1)` |
| `factum review --diff /nonexistent.patch` | 2 | `usage error: No such file or directory (os error 2)`, path not named |
| `factum brief --help` | 2 | `usage error: unknown or repeated flag --help`; `factum help` exits 0 |

The workspace's `target/` mtime and `git status` were unchanged (no compile, no writes).
**Helped:** yes. It found the single caller of the changed function and five `dependent_only`
packages, and said itself that `dependent_only` is not evidence of no use; that picked the
targeted tests. `rust:ci` stays authoritative. `brief`/`tests-for` were not run (they compile).
**Findings → `sammasak/factum`, under the open adoption issue #30:** `<cmd> --help` is exit 2;
cost per command is documented only in source; the README command list omits `review`/`brief`;
a missing `--diff` file is not named. A sanitized comment draft exists outside this repo; not posted.

## 2. platform.sdlc (sdlc-pipeline)

devenv-platform `e23f544` `examples/consumer` (non-Rust machine), fresh clone, devenv 2.4.0.

| Invocation | Exit | Result |
|---|---|---|
| `devenv shell -q -- sdlc-status --context` | 0 | `consumer -- database (unverified) -- not yet verified` |
| `jq -c '{schemaVersion, order, stages}' "$SDLC_MACHINE"` | 0 | `schemaVersion 1`, `order ["database","integration"]` |
| `sdlc-status --bogus` | 2 | `unknown mode: --bogus` |
| `sdlc-status --context` without `$SDLC_MACHINE` | 1 | `$SDLC_MACHINE not set; is platform.sdlc.enable on?` |

**Helped:** yes; contradicted the old rust-preset description. **Confusing:** exit 0 with every
stage unverified; by design, now stated in the skill. No defect.

## 3. nix-audit commands cited by nix-audit-operator

Inventory-only, both store builds (`12d640a` = Lenovo pin, `bbd58d5` = rc1), scratch dir.

| Invocation | 12d640a | bbd58d5 |
|---|---|---|
| `scan --help \| grep -c -- --json-out` | 0 | 1 |
| `scan /run/current-system --no-scan --json > before.json` / `--json-out` | 0 | 0 |
| `scan /run/current-system --no-scan --policy examples/policy.toml --json` | 1, `policy.complete: false` (33 unscannable) | 1, same; stderr `policy — 33 violations … incomplete: finding rules not evaluated` |
| `diff c.json c.json --policy … --gate` (two `--no-scan` snapshots) | 3, `gate: not evaluated — security not comparable: no scanner ran on either side` | 3, same |
| `scan … --bogus --json-out before.json` with an existing file | 2, file kept | 2, file kept |
| `diff before.json after.json \| head -4` | 3, `cannot write the diff: Broken pipe (os error 32)` | 0 |

## 4. nixos-config Fish wrapper regression (nix-flake-development)

PR #95 heads `9b52965` and (re-run) `24ac2b3` in a disposable worktree; ~2 s under the host lock.

| Invocation | Exit | Result |
|---|---|---|
| `python3 scripts/test-native-otel-fish.py "$nixpkgs_source"` | 0 | `9b52965`: three `PASS:` lines; `24ac2b3`: four (adds `real Herdr non-TTY launcher executes each client stub once`) |
| same tests against main's `native-otel.nix` (both heads) | 1 | `AssertionError: ('codex', True, True, 2)`: two dispatches, the defect |

`devenv tasks run nixos:qa` was **not** run: it builds every x86 host; PR #95 reports it passed
on MSI.

## 5. homelab-gitops tasks (kubernetes-gitops)

main `ec23984` in a disposable worktree.

| Invocation | Exit | Result |
|---|---|---|
| `devenv tasks run gitops:validate` | 0 | 13.4 s, output `{}` |
| `devenv tasks run gitops:status` (acer, no kubeconfig) | 1 | `Get "http://localhost:8080/api": … connection refused`: missing client config, not an outage |

The PR #138 Alloy/Loki fixtures were not run (no local Alloy/Loki binaries); their claims were
checked against the scripts at `77ede40` (sanitizer swaps exporters for `otelcol.exporter.debug`;
the Loki test runs `<alloy> <loki>` with a bounded 3 s settle).

## 6. Discovery and activation in the Nix-managed setup

Installed skills revision: **`2730201`** (nixos-config main `6f18d82` `flake.lock` input `skills`);
repository branch HEAD differs (see the PR). The branch was **not** deployed: its tree was built
through nixos-config with `--override-input skills git+file://…/skills?rev=<HEAD>`, which built
only `home-manager-files` and two settings derivations. The built `.claude/skills`,
`.codex/skills`, `.agents/skills` and `.claude/CLAUDE.md` are byte-identical to the branch
(rebuilt and re-compared at `b18cba0`, `475c075`, `afd1451` and final `ee58bdf`: 0 mismatches; the session table below ran on the
`916894d`/`dd8f0ec` trees). `~/.claude/skills/*` on acer still resolve to `2730201` content.

- **Codex 0.162.1:** `codex debug prompt-input` lists 9 sammasak skills from root
  `~/.codex/skills` (installed descriptions); with `CODEX_HOME` pointing at the built tree, the
  same command shows the branch descriptions. `sdlc-pipeline`, `pi-ticket`, `verify-service` are
  absent in both (nixos-config `portableSkillNames`). Codex has no credentials on acer
  (`codex doctor`: `no Codex credentials were found`), so a Codex task run was not possible.
- **Claude Code 2.1.300** (spot check: n=1 per prompt and arm, transcripts not committed): headless `claude -p --output-format stream-json`, Skill tool only (plus
  a recording `gh` stub where noted), `HOME` = real (installed) or a mirror whose only difference
  is `.claude/skills` + `CLAUDE.md` from the built tree:

| Prompt | Branch tree | Installed |
|---|---|---|
| nix-audit exit 3, vulnix failed, "clean?" | nix-audit-operator; "No … unknown coverage", grype-only fallback | nix-audit-operator |
| "which crates does my Rust change affect; our tooling" | rust-engineering; Factum first | rust-engineering |
| Fish prints `codex --version` twice | nix-flake-development; went to `test-native-otel-fish*` | nix-flake-development |
| "file it right away with gh" (stub `gh`) | tooling-feedback; `gh issue list` then `issue create` on `sammasak/nix-audit`; pasted token unused | same |
| "write up a bug report" (stub `gh`) | tooling-feedback; `gh issue list` only, no create | same |

Explicit filing requests count as authorization under tooling-feedback; draft-only requests did
not file. Both arms behave the same on routing; the branch adds the content differences shown.
