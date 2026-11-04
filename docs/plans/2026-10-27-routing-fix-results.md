# Routing fix results, 2026-10-27 (#11 criterion 2)

Harness as in `2026-10-26-eval-results.md`; trigger only, full set, `--repeat 3`, 0 errors.
Main arm = `2406511`; branch arm = this change (descriptions of tooling-feedback,
nix-audit-operator, pi-offload). Raw per-case reports: `evals/results/routing-11-20261027/`.

| | main | branch |
|---|---|---|
| Total | 759/825 | 765/825 |
| nix-audit two findings, "file a reproducible bug" → tooling-feedback | 0/3 | 3/3 |
| "Add a new subcommand to the factum CLI" → rust-engineering | 0/3 | 3/3 |
| cluster SOPS not decrypted (nix-flake hard negative) | 0/3 | 3/3 |
| "Where is the API token for this deploy stored?" → credentials | 2/3 | 0/3 |
| container image too large (kubernetes-gitops hard negative) | 1/3 | 0/3 |

Touched suites: tooling-feedback 42/42, nix-audit-operator 36/36, pi-offload 24/24,
sdlc-pipeline 42/42, rust-engineering 57/60 (same as main). Descriptions route as a set:
variants that changed rust-engineering, or listed pi-offload in tooling-feedback, moved
neighbouring pi-ticket, sdlc-pipeline, pi-offload or Axum cases.

Open: the credentials positive above is now 0/3 (secrets-management wins). The likely fix is
splitting credentials ("read or use an existing secret") from secrets-management ("create,
edit, rotate"), measured the same way.
