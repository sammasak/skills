---
name: nix-flake-development
description: "Use when editing ~/nixos-config, adding a NixOS or Home Manager module, updating a flake input, running its nixos:qa verification gate, or rebuilding/deploying a homelab host."
allowed-tools: Bash, Read, Grep, Glob
---

# Nix Flake Development (homelab)

`~/nixos-config` (branch `main`) is flake-parts with auto-discovery: `flake-modules/` loads in numbered order, `modules/roles/*.nix` and `modules/home/*.nix` become registry modules automatically, hosts are declared in `flake-modules/hosts/<name>.nix` + `hosts/<name>/`. Home Manager is shared by every host via `modules/home/default.nix`. Its `CLAUDE.md` is the detailed reference, including a Comment Policy that `just lint-comments` enforces.

## Hosts

Flake attributes: `acer-swift`, `lenovo` (hostname `lenovo-21CB001PMX`), `msi-ms7758`, `black-pi` (aarch64 Raspberry Pi 4; eval-only on lenovo, builds on the Pi), `naked-pi` (Pi 3 rf-lab, off k3s). The Justfile maps hostname to attribute, so `just switch` with no argument targets the current machine.

## Commands

```bash
devenv tasks run nixos:qa   # the verification gate (= just check; pre-push runs it on the pushed sha)
                            # includes nixos:verify = builds every x86 host: heavy, take the lock below
just verify           # every host builds
just diff [HOST]      # nh build + package diff vs the running system
just switch [HOST]    # nixos-rebuild switch --install-bootloader
just bump [input]     # nix flake update (all or one input)
just deploy-acer      # deploy-rs with magic rollback; acer has no BMC, so prove on deploy-lenovo first
just deploy-pi        # deploy-rs remoteBuild: the Pi builds its own closure (lenovo has no aarch64 builder)
```

Run heavy gates on a host with free capacity (not a full Lenovo root, not next to another session's build) under its shared lock: `flock /tmp/$(hostname)-heavy-work.lock devenv tasks run nixos:qa`. Prefer the narrow task (`nixos:lint-shell`, `nixos:flake-check`, a module's own regression script) when it covers the change.

**Switching and rollback are operator actions.** Do not run `just switch`, a `just deploy-*` or a generation rollback unless the owner asked for that host now; hand over the exact command and keep the previous generation available. Never switch while an agent session depends on the current shell environment.

## Known traps

- Bootloader: `lenovo` and `acer-swift` use **systemd-boot**; `msi-ms7758` is GRUB with a Windows chainload entry (small shared ESP); `black-pi` is U-Boot + extlinux. `just switch` always passes `--install-bootloader`; before a flake update, check whether the bootloader/kernel store paths change.
- A rebuild or HM switch breaks the Bash tool in every running Claude session (stale shell snapshots: exit 1, no output). File tools keep working; restart the session. Park state outside the `/tmp` scratchpad first.
- The build uses the commit pinned in `flake.lock`; pushing a dependency repo changes nothing until `just bump <input>`. Skills reach `~/.claude`, `~/.codex/skills` and `~/.agents/skills` this way: merge to `sammasak/skills`, then `just bump skills` (owner approval) and switch. Never edit those skill dirs directly (HM symlinks into the store).
- `git+` inputs to private repos need ssh URLs (`github:` 404s without a token) and a `?rev=` pin.
- Secrets: sops-nix with rules in `secrets/.sops.yaml`; see `secrets-management`.
- Fish wrappers for `claude`/`codex` (fix pending in PR #95): on devTools hosts native telemetry may only add function-local `set -lx` settings via `lib.mkBefore`; Herdr's function stays the sole dispatcher. Never append another `claude`/`codex` command: Fish function bodies concatenate and the agent runs twice. No-inference regression, also inside `nixos:qa`: `nixpkgs_source=$(nix eval --raw --impure --expr '(builtins.getFlake (toString ./.)).inputs.nixpkgs.outPath')`, then `python3 scripts/test-native-otel-fish.py "$nixpkgs_source"`; every case prints `PASS:` and it exits 0.
- Native telemetry activation or rollback happens only after approval, with agent sessions parked: Lenovo canary first, a fresh shell, one version line per `claude --version` / `codex --version` (no inference; does not prove telemetry receipt). Safe rollback is `nativeOtel = false` plus an approved switch, never a switch back to a pre-fix `nativeOtel = true` generation; do not revoke a credential another approved client shares.
- black-pi: its nix-daemon ignores `--max-jobs`/`--cores` from untrusted `lukas`; the host sets max-jobs 1 / cores 2, realise any big build before that is live as root (`systemd-run … nix-store --realise <drv> --max-jobs 1 --cores 2`) or the 4GB Pi hangs. Runbook: `~/knowledge/homelab/runbooks/aarch64-pi-host.md`.
