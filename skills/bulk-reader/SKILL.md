---
name: bulk-reader
description: "Use when you need to explore, summarise or answer a question about a file over ~350 lines (or several files) and do not need its exact text, or when a shunt hook redirected a large Read, cat, head or tail. Delegates the reading to headless Claude Code on haiku via scripts/bulk-read.sh so the files never enter your context."
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

Each call is independent: for a follow-up, ask again with the same `--paths`. Limits: 12 files and 400 KB per call by default; split larger sets.

## Ask well

Ask one specific question that names what you are looking for (a function, a setting, an error string, a behaviour), not "summarise this file". Good: "Which functions write to the session state file, and under what conditions?" Weak: "What does this do?"

## Treat the answer as a lead

The answer is not ground truth. Before you edit, quote, or rely on a line number or exact value, confirm it with a ranged Read (offset/limit around the cited line). "not found in the provided files" means the model did not see it, not that it does not exist.

## Do not delegate

- You need exact content for an edit: Read the range (at most ~350 lines) instead.
- Small files: just Read them.
- Sensitive files (`.env`, keys, tokens, credentials, shell history, kubeconfigs, anything under `secrets/` or `.ssh/`, anything holding a private key, base64 key data, a Kubernetes Secret or sops data): the script refuses them; Read directly only if you are permitted to. Private-mode (0600) files are refused only under a permissive umask; with umask 077 (the default on these machines) only the name and content checks guard delegation, so do not delegate a file you know is secret.
- Debugging where every line matters (a failing test's exact assertion, a subtle off-by-one).

## On failure

The script exits non-zero with a one-line reason (timeout, budget ceiling, usage limit, auth, model unavailable, empty answer). Do not retry in a loop: Read the file in offset/limit ranges, or repeat the original full Read (an identical repeat is allowed by the hook).
