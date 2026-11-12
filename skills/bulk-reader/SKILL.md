---
name: bulk-reader
description: "Use when you need to explore, summarise or answer a question about a large non-source file (more than about 8000 tokens: roughly 30 KB of text) or several files and do not need its exact text, or when a shunt hook redirected a large Read, cat, head or tail. Delegates the reading to headless Claude Code on haiku via scripts/bulk-read.sh so the files never enter your context."
allowed-tools: Bash, Read
---

# bulk-reader

`bulk-read.sh` hands the files and one question to a headless, tool-less `claude -p` on haiku and prints a short answer with `path:line` citations. Only the answer enters your context. The delegated tokens are Anthropic usage on the same account (cheaper per token, not free): delegate a large read, not a 40-line file.

## Invoke

When a shunt hook denies a large Read or `cat`/`head`/`tail`, its message carries the exact command with the absolute script path and the file filled in. Copy it and replace the question. Otherwise the script sits next to the skills, outside this skill's directory:

```bash
S="$(dirname "$(readlink -f ~/.claude/skills/bulk-reader/SKILL.md)")/../../scripts/bulk-read.sh"   # Nix install
# plugin install: S="${CLAUDE_PLUGIN_ROOT}/scripts/bulk-read.sh"
"$S" --question "Where is the retry budget for upstream calls set, and what is its default?" --paths src/gateway.rs src/config.rs
```

Each call is independent: for a follow-up, ask again with the same `--paths`. Limits: 12 files and 200 KB per call by default; split larger sets, or use Grep. In an interactive session in `default` permission mode each call asks for permission unless the owner has allowed the script.

## Ask well

Ask one specific question that names what you are looking for (a function, a setting, an error string, a behaviour), not "summarise this file". Good: "Which functions write to the session state file, and under what conditions?" Weak: "What does this do?"

## Treat the answer as a lead

The answer is not ground truth. Before you edit, quote, or rely on a line number or exact value, confirm it with a ranged Read (offset/limit around the cited line). "not found in the provided files" means the model did not see it, not that it does not exist.

## Do not delegate

- You need exact content for an edit: Read the range you will change (the hook message names how many lines fit), or repeat the read; any second read of the same file passes. Source code and instruction files (`CLAUDE.md`, `SKILL.md`, `.claude/`) are never redirected.
- Small files: just Read them.
- Sensitive files (`.env`, keys, tokens, credentials, shell history, kubeconfigs named or located as such (`kubeconfig*`, `kube*config*`, `.kube/`) or holding a client key or token, anything under `secrets/` or `.ssh/`, anything holding a private key, base64 key data, a Kubernetes Secret, a WireGuard key, a GitHub/Anthropic/Nix token or sops data): the script refuses them; Read directly only if you are permitted to. Private-mode (0600) files are refused only under a permissive umask; with umask 077 (the default on these machines) only the name and content checks guard delegation, so do not delegate a file you know is secret.
- Debugging where every line matters (a failing test's exact assertion, a subtle off-by-one).

## On failure

The script exits non-zero with a one-line reason (timeout, budget ceiling, usage limit, auth, model unavailable, empty answer). Do not retry in a loop: Read the file in offset/limit ranges, or repeat the original read (the hook allows any second read of the same file; `allow_large` is not needed).
