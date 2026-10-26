# Compatibility audit, 2026-10-26

Skills at `2730201` (= the revision nixos-config main pins, so installed == main). Audited on
`acer-swift` (NixOS fe13242, devenv 2.4.0, Claude Code 2.1.300, Codex 0.162.1, Pi 1.2.0).

## Installed tools and pins

| Tool | Installed where | Pin / version | Evidence |
|---|---|---|---|
| `nix-audit` | Lenovo HM only (`nix-audit-lenovo.nix`); not on acer PATH | 0.1.0 @ `12d640a` (main is `bbd58d5`, 16 commits ahead) | `nix eval …#nixosConfigurations.lenovo.pkgs.nixAudit.outPath` = `/nix/store/3awxmh53…-nix-audit-0.1.0` |
| `factum` | Lenovo HM only (`factum-lenovo.nix`); not on acer PATH | 0.2.0 @ `5bb7fa3` (main `5812b62`, 17 ahead); `--version` prints no revision | same eval = `/nix/store/bi7zsbz7…-factum-0.2.0`, present in acer's store and run from there |
| `sdlc-status`, `sdlc-fingerprint` | only inside an sdlc-enabled `devenv shell` | devenv-platform `e23f544` (= main) | `devenv shell -q -- sdlc-status --context` in `examples/consumer` |
| `pi-offload`, `pi-ticket`, `pi-view`, `pi` | acer HM PATH | Pi 1.2.0; tools from devenv-platform `e23f544` | `command -v`, `--help` |
| `flux`, cluster `kubectl` | k3s server (Lenovo) only; acer has `kubectl` but no kubeconfig and no `flux` | — | `kubectl get nodes` on acer: `localhost:8080 refused` |

Skill discovery per harness (nixos-config `modules/programs/cli/codex/default.nix`):
Claude Code links **all** skills into `~/.claude/skills`; Codex (`~/.codex/skills`) and
`~/.agents/skills` (read by Pi and other agents) get only 9 `portableSkillNames`. `sdlc-pipeline`, `pi-ticket` and
`verify-service` are not portable; Codex/Pi sessions cannot activate them.

## Discrepancies

| # | Skill | Skill says | Reality | Action |
|---|---|---|---|---|
| 1 | nix-audit-operator | snapshots via `scan --no-scan --json > before.json` | main documents `--json-out FILE` (removed on exit 2/3, so no stale snapshot gates); pinned `12d640a` has **no** `--json-out` (arrived `7dcbdec`). Arg-parse usage errors leave an existing FILE untouched (nix-audit agent, reproduced on `bbd58d5`) | branch on `scan --help`; `rm -f` snapshots before every run |
| 2 | nix-audit-operator | `--gate` waits for #32 to be accepted | #32 closed COMPLETED 2026-10-26; owner policy: advisory pilot, automatic enforcement stays **off**; manual `diff --policy … --gate` allowed, exit recorded | rewrite |
| 3 | nix-audit-operator | no exit codes, no `policy.complete` | scan 0/1/2/3 (3 outranks 1; `complete:false` possible at 0/1); diff `--gate` 0 pass / 1 fail / 3 not evaluated; `gate: pass` ≠ strict pass | add, link README |
| 4 | nix-audit-operator | assumes `nix-audit` on PATH | Lenovo-only | say so |
| 5 | rust-engineering, pi-offload | Factum `brief`/`tests-for` as cheap evidence | `tests-for` and `brief` compile via `cargo nextest list`; `impact`, `review` never compile; `diagnostics` runs cargo once (factum `main.rs` @ `5bb7fa3`) | state cost |
| 6 | rust-engineering | omits `review`, `impact`; no exit codes | `review --format json` = `facts-review/v3` with `unavailable` + `verification: not_run`; exit 0/1/2/3 (2 = malformed/stale patch, 3 = tool fault e.g. no `cargo`) | add |
| 7 | rust-engineering | "pinned Factum CLI" with no location | Lenovo-only; needs `cargo` from the repo dev shell (bare PATH → exit 3 `cannot load the workspace`) | add discovery line |
| 8 | sdlc-pipeline | description hardcodes rust-preset stages | stages are per-repo (`examples/consumer`: `database → integration`) | description: say preset is an example |
| 9 | sdlc-pipeline | silent on `sdlc-status` exit | exit 0 even with every stage `unverified`; 1 no machine; 2 bad mode. Only `sdlc:done`'s exit is a verdict; `sdlc:done` itself is a local advisory, not re-checked at merge | add |
| 10 | sdlc-pipeline | silent on missing executables / guard faults | ADOPTING-SDLC troubleshooting table; stale pre-push hook after re-pin (`devenv shell -q -- true`) | link |
| 11 | pi-offload | `invalid` unexplained; `moved_refs` missing from field list | `invalid` = check passed but diff empty; `moved_refs` is a field | fix |
| 12 | pi-offload | quotas "Gemini Flash 20 requests/day, Cloudflare 10k neurons/day, flash-lite 15 RPM" | now 4 Gemini Flash models × 5 RPM/20 RPD, Groq 1K RPD, CF 10k neurons; volatile | link `nixos-config/docs/pi.md` instead of numbers |
| 13 | pi-offload | privacy: "prompts leave the machine" | also: free-tier Gemini prompts may be used by Google; `--keep` retains logs that may echo secrets | add |
| 14 | tooling-feedback | no visibility note | `nixos-config` and `skills` are **public**; tool repos private | add |
| 15 | tooling-feedback | generic template only | nix-audit (PR #46 `docs/FEEDBACK.md`) and devenv-platform (`docs/FEEDBACK.md`) own templates; Factum #30 tracks one | link owners' templates |
| 16 | kubernetes-gitops, verify-service | commands with no host | `flux`/kubeconfig only on Lenovo (k3s server); acer fails with a misleading `localhost:8080 refused` | one line |
| 17 | pi-ticket | — | `--help` exit codes match (0/1/64/70/75) | none |

No discrepancy found in: verify-service levels, kubernetes-gitops topology (matches homelab-gitops `ec23984` CLAUDE.md), sdlc `machine-reference.md` (schemaVersion 1, `order`, matches `examples/consumer`), pi-offload exit codes and JSON fields otherwise.

Upstream doc mismatches → [2026-10-26-upstream-mismatches.md](2026-10-26-upstream-mismatches.md).
