# Adoption checklist: skills PR #15

Every step that changes shared state needs the owner's explicit approval; nothing here has been
done. Installed skills today: `2730201` (nixos-config `flake.lock` input `skills`).

1. **Review and merge** PR #15 (owner). Note the merge commit `M`.
2. **Preview the pin bump** in `~/nixos-config` on a fresh branch:
   `just bump skills`, then `nix build --dry-run` of the host. Expected: only `home-manager-files`
   and the Claude settings derivations rebuild (measured: 3 derivations with the branch as an
   `--override-input`).
3. **Switch** (owner/operator, one host first): park running agent sessions first (a switch breaks
   their Bash tool), `just switch`, keep the previous generation for rollback.
4. **Verify discovery on the switched host**, in a fresh shell:
   - `readlink -f ~/.claude/skills/nix-audit-operator/SKILL.md` is a store path; `diff` it against
     `git show M:skills/nix-audit-operator/SKILL.md`. Same for `~/.claude/CLAUDE.md` vs
     `global-context.md`.
   - Claude Code: a headless `claude -p --output-format stream-json --verbose` init event lists
     the skills; the nix-audit prompt from the dogfood evidence §6 invokes `nix-audit-operator`.
   - Codex: `codex debug prompt-input x | grep -c "Factum review/impact evidence"` returns 1.
5. **Rollback:** switch back to the previous generation, or revert the `flake.lock` bump and switch.
   Skills are read-only text; nothing else to undo.

Owner decisions outside this PR:

- Add `sdlc-pipeline`, `pi-ticket`, `verify-service` to nixos-config `portableSkillNames` (Codex
  and Pi cannot see them today).
- Log Codex in on acer if Codex sessions should run there (`codex doctor`: no credentials).
- File or drop the drafted upstream items in [upstream-mismatches](2026-10-26-upstream-mismatches.md).

When nixos-config PR #95 and homelab-gitops PR #138 merge, drop the "pending in PR #…" wording in
`nix-flake-development` and `kubernetes-gitops` and re-run their commands once against main.
