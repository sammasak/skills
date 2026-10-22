---
name: rust-engineering
description: "Use when writing Rust code in a homelab repo, adding crates, changing Cargo workspace lints or profiles, running Rust gates, applying the type pillar (illegal states unrepresentable, newtypes, typed errors), or building a container image from a Rust binary."
allowed-tools: Bash, Read, Grep, Glob
---

# Rust Engineering (homelab conventions)

Standard is ADR-026 + ADR-027 (`~/knowledge/homelab/decisions/`). Reference repo: `~/rust-devenv-template` — copy from it, not from a sibling repo (per-repo specifics like herman's are not portable).

## Dev environment and gates

devenv is the full dev environment (packages, tasks, git hooks); central policy comes from `~/devenv-platform`. Run gates as devenv tasks, never a repo-local `dev` script or a second flake hook owner:

| When | Task |
|---|---|
| pre-commit hook | `devenv tasks run rust:fmt-check` |
| pre-push hook | `devenv tasks run rust:ci` (strict clippy, cargo-deny, rustdoc, nextest + doctests) |
| release/merge | `devenv tasks run rust:verify` (ci + coverage floor) |
| on demand | `rust:bench`, `rust:audit`, `rust:deps`, `rust:mutants` |

Repos with `platform.sdlc` are driven by the `sdlc-pipeline` skill. Toolchain is pinned stable via `rust-toolchain.toml`; no nightly.

## Factum evidence (optional)

When the project's pinned Factum CLI is available, use its read-only evidence before asking Pi or another model to interpret a long Rust failure log:

- `factum diagnostics --tool check` or `--tool clippy` summarizes workspace diagnostics.
- For a change, generate a standard Git patch and use `factum brief --diff /tmp/change.patch` for a compact change packet; use `factum tests-for --diff /tmp/change.patch` to inspect candidate tests.
- Pass the schema-tagged findings, relevant skipped/ambiguous fields, and only the necessary log tail to the model. Do not send the whole build log by default.

Factum is advisory: an empty report or test selection is not a correctness claim. Read skipped and `list_failed` fields, and still run the required project checks (`rust:ci`, tests, security checks and review). If Factum is not installed or its evidence is incomplete, continue with the normal deterministic workflow rather than installing an unpinned tool or treating missing evidence as success.

## Lints

`[workspace.lints.clippy]` denies `all` + `pedantic` + `nursery` plus the panic-prevention pack (`unwrap_used`, `expect_used`, `indexing_slicing`, `arithmetic_side_effects`, `panic`, `exit`, `as_conversions`, `string_slice`, ...) and `allow_attributes_without_reason`. `clippy.toml` allows unwrap/expect/panic/indexing in tests. Suppress with `#[expect(lint, reason = "...")]`. A `[profile.clippy]` is required (separate artifact dir, avoids the cold-clippy rebuild cliff).

## Anti-bloat (debloat/deslop)

The platform `clippy.toml` sets the thresholds that make the deny bite: `excessive-nesting-threshold = 5` (this lint is inert at clippy's default 0, so the threshold is what turns it on) and `too-many-arguments-threshold = 5`. `too_many_lines` is left at pedantic's default 100 on purpose — at 80 it fired on ordinary snapshot/table `#[test]` bodies and manufactured `#[expect]` ceremony, the noise the gate exists to remove. These are the mechanical backstop for the `lean-code` and `deep-modules` skills — nesting depth, argument count, and (loosely) function length are the bloat signals clippy *can* measure.

Unused dependencies are owned by `rust:shear` (cargo-shear) in strict CI — a superset of cargo-machete; `rust:deps` only checks staleness. Dead in-crate code is rustc's `dead_code`/`unused` (warn-by-default).

What clippy cannot measure stays review-owned: whether a comment restates the code, whether an abstraction has one user — that is `lean-code`/`deep-modules` at review time (no reliable Rust tool mechanizes "useless comment", and a doc-comment density cap would fight `missing_docs`). For a project-specific structural anti-pattern that recurs (2+ real hits, never pre-emptively), `ast-grep` is the lightweight escape hatch — a YAML structural rule, no nightly/dylint toolchain tax.

## Preferred crates (ADR-027 type + test pillars)

- Types: private fields + `bon` fallible builder, `secrecy::SecretString` for secrets, `strum` for enum `ALL`/`COUNT`, tagged serde enums, sqlx `query!`.
- Tests: `proptest`, `insta`, `rstest`, `cargo-mutants` (in verify), per-component `*-test-support` fixture crates.
- Services: `axum` + `tower`, `kube-rs` for cluster clients, `thiserror` in libraries.

## Container images

Static musl binary on `FROM scratch` (copy CA certs from the builder). Build with `nix run nixpkgs#buildah -- build`, push with `--authfile` to `registry.sammasak.dev`; re-scan pinned base digests before reuse (trivy wants docker-archive, not oci).
