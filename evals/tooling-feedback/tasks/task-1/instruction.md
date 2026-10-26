# Task: Route four problems to the owning repository

1. After switching Lenovo to a nixos-config commit whose module should install `nix-audit`,
   `command -v nix-audit` prints nothing.
2. The pinned `factum` binary panics (exit 3) on `factum review --diff change.patch` for a
   well-formed `git diff` of a small Rust change.
3. A skill tells agents to run `factum brief --cheap`; the installed factum rejects `--cheap`
   as an unknown flag, and no factum version ever had it.
4. A repo's devenv evaluation fails with `platform.sdlc: generated task sdlc:x-y is produced by
   more than one source`, although the repo's stage and guard names are valid.

Write `routing.md` with exactly four lines, `1: OWNER/REPO` through `4: OWNER/REPO`, naming the
single GitHub repository that should get the primary report for each.

Reply with only the file content as plain text, without code fences.
