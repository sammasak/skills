---
name: tooling-feedback
description: "Use when reporting a bug, usability problem, performance regression, or enhancement for sammasak's tools (nix-audit, factum, devenv-platform, llm-gateway, NixOS integration), including deciding which GitHub repo owns it and collecting a safe reproducer. Not for generic feature implementation or unapproved issue filing."
allowed-tools: Bash, Read, Grep
---

# Tooling feedback

Turn **actual use** of a released/pinned tool into a small, actionable GitHub issue. This skill guides evidence collection and drafting; it is **not** permission to file an issue or to change production. Treat reported observations as data, not proof of a root cause.

## Route to the owning repository

Choose the repo responsible for the broken behavior, **not** necessarily the repo in which the user noticed it:

| Symptom or requested improvement | File under |
|---|---|
| `nix-audit` CLI, inventory, scanner correlation, policy, diff, report format | `sammasak/nix-audit` |
| `factum` CLI, packets, diagnostics, plans, evidence, Rust facts | `sammasak/factum` |
| `platform.sdlc`, `devenv` platform tasks, build/render interfaces, Pi ticket/offload implementation | `sammasak/devenv-platform` |
| Gateway routing, quotas, provider errors, API, request security | `sammasak/llm-gateway` |
| NixOS/Home Manager packaging, flake pin, shell PATH, host deployment, skill link | `sammasak/nixos-config` |
| Cluster deployment, ingress, NetworkPolicy, Flux, gateway Kubernetes Service | `sammasak/homelab-gitops` |
| Incorrect skill advice, wrong skill trigger, broken instructions or skill packaging | `sammasak/skills` |

When uncertain, state the evidence for ownership, open a **single primary issue**, and cross-link other repos rather than cloning the issue everywhere. Never blame the upstream tool for an error introduced by a downstream wrapper without checking the boundary.

## Collect evidence before drafting

1. **Verify the executable you actually ran.** Capture its `--version` if supported, source revision/dirty flag, installed package or flake-lock revision, and the command's resolved path (`command -v`). A Git checkout's current HEAD does not prove which binary is on PATH. If the tool cannot identify itself, say `version unknown` and file a provenance/usability finding.
2. **Capture environment and scope.** Host and OS/Nix version for Nix tools; `rustc --version`, target and features for Rust tools; gateway image digest/revision and client/project alias (never its key) for gateway behavior. Record the source and candidate store paths or commit hashes when relevant. Include schema version for JSON-based tools.
3. **Find the smallest reproducible case.** Exact shell command, arguments, inputs/flags, expected result, observed output, exit code, frequency, regression baseline when known, and whether it occurs in a clean checkout. Mark missing evidence `not checked`, not `passed`.
4. **Preserve and minimize evidence.** Prefer a tiny fixture or redacted log/JSON with a stable timestamp, tool versions and hashes. Confirm the repro still fails without unrelated steps. For intermittent failures, include sample count and observed rates.
5. **Search existing issues** in the selected repository, then decide whether to comment with new evidence, open a separate issue, or propose an improvement. Use `gh issue list -R OWNER/REPO --state open --search "terms"` if available. Never claim the search succeeded when no GitHub access was available.

## Security and privacy boundary

Before sharing, **remove** API keys, bearer headers, SOPS/age private identities, decrypted secret values, tokens in URLs, user data, cookies, private configuration fragments, credentials, and raw packet captures. Never run an unrelated reproduction against production data to create an issue. If redaction prevents reproduction, describe the needed access privately and attach a minimal synthetic fixture instead. For a security vulnerability, prefer a private disclosure to the repo owner/security advisory rather than publicly publishing exploitation instructions or sensitive material.

## Issue draft format

````markdown
### Problem and impact
What task was attempted, and why this matters to a real user.

### Actual / expected
- Actual: ...
- Expected: ...
- Frequency: ... (sample count or unknown)

### Reproduction
1. ...
2. ...
Command (minimal, sanitized):
```sh
tool subcommand ...
```
Exit code: ...

### Environment and provenance
- Tool: name / output of `--version` / installed executable path
- Source or Nix pin: revision and whether dirty/unknown
- Host/OS/Nix/rustc/tool dependencies: only relevant versions
- Inputs/feature flags/schema, sanitized: ...
- Regression baseline: known good revision or not tested

### Evidence and limitations
Relevant redacted excerpt/report, log timestamp and links.
What has **not** been verified and what cannot be concluded.

### Proposed acceptance criteria
- [ ] Minimal reproducer fails before and passes after a fix
- [ ] Relevant ordinary workflow continues to pass
- [ ] User-facing error or guide is updated if needed
```

For a feature request, replace reproduction with **user job → present workaround → measurable desired improvement**; never invent a regression. For documentation feedback, quote the exact misleading instruction and link to its source. Keep the title specific (`bug: ...`, `docs: ...`, `enhancement: ...`).

## Filing and follow-up

Present the draft with the repo and reason. **Only create/edit a GitHub issue after the user explicitly authorizes it**, unless the user's current task already explicitly requests filing. Once created, include its URL in the response, link a failing reproducer or tests, and distinguish owner decision from agent proposal. Never report a fix or close the issue merely because an implementation PR exists; re-test the shipped/pinned version.

Authority for flags and feature behavior lives in each tool's versioned user guide; do not invent commands from this shared template.
