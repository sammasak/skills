# Shunt: redirect large exploratory reads to an inexpensive model

## What it does

Two PreToolUse hooks notice when Claude Code is about to pull a large file into context (a whole-file `Read`, or `cat`/`head`/`tail`/`less`/`more`/`bat`/`nl` through Bash) and deny that first attempt with a message carrying the exact `scripts/bulk-read.sh` command. The script hands the files and one question to headless Claude Code (`claude -p`, haiku by default, no tools) and prints a short, cited answer, so only the answer enters context. Delegated tokens are Anthropic usage on the same account: cheaper per token than the main model, not free. The `bulk-reader` skill tells Claude when to use it and when not to. Repeating the identical read is allowed, so the redirect is a nudge, never a wall.

Files: `hooks/shunt-check-read.sh`, `hooks/shunt-check-bash-read.sh`, `hooks/lib/shunt.sh` (shared policy), `hooks/lib/state.sh` (`seen_before`), `scripts/bulk-read.sh`, `skills/bulk-reader/SKILL.md`, `tests/test-shunt.sh` (`devenv tasks run skills:test:shunt`, also in pre-push).

## Upstream and what changed

Adapted from Spotify's Shunt plugin (`plugins/shunt`, Apache-2.0). Upstream blocks Read on files over 350 lines unless `offset` or `limit` is set, blocks `cat`/`head`/`tail`/`less`/`more` on the first non-flag argument, and points at a skill that runs `bulk-read` through Spotify's internal portal CLI.

Reused: the 350-line threshold, the hook to skill to script flow, and the eval case shapes (boundary at 350/351, empty file, offset/limit, pipes and redirects) now in `tests/test-shunt.sh`.

Changed:

- Headless Claude Code on haiku instead of portal-cli: no gateway or extra credential, the transport is one function (`run_claude`), and tests swap the binary via a fake `claude` on PATH.
- Sensitive paths are never delegated, checked on the given and the symlink-resolved path; the script refuses them.
- Payload lines carry real line numbers inside a per-call random delimiter; the system prompt treats file content as untrusted data.
- Output, payload, file-count and time bounds.
- Repeat-bypass instead of indefinite blocking: the identical repeat in a session is allowed and logged.
- Ranged-read arithmetic: `offset: 0`, `limit: 0` and a huge `limit` are not "targeted"; the lines a read would actually return decide. `head -n 5000` is large, `head -5` is not, `tail -f` is ignored, and every file argument is checked.
- The repo's exit-2-on-stderr convention instead of upstream's JSON `decision` output.

## Decision table

Both hooks, in order (first match wins). Every row except "redirect" exits 0 silently.

| Condition | Result (log) |
|---|---|
| `SHUNT_DISABLE=1` | allow (not logged) |
| jq missing, unparseable input, no path/command, internal error | allow |
| Bash: not a simple `cat/head/tail/less/more/bat/nl` invocation | allow (not logged) |
| Bash: any of `\| > < ; & $ \` { } ( ) \ ~ * ? [ ]`, newline, partial quoting | allow (`compound`) |
| Bash: `tail -f/-F`, unknown option, unparseable count (`-n 1K`) | allow (`follow`, `unparsed`) |
| Read: offset that is not a whole non-negative number or too large to compute, or a non-numeric limit | allow (`unparsed`) |
| Path missing, not a regular file, or no file arguments | allow |
| Sensitive or `SHUNT_EXCLUDE` path (given or resolved) | allow (`sensitive`) |
| Image, PDF, notebook, or a NUL byte in the first 64 KiB | allow (`nontext`, Bash skips that file) |
| Returned lines <= threshold and returned bytes <= `SHUNT_MIN_BYTES` | allow (`allow`, or `targeted` for a range) |
| No session id, or one that is not `[A-Za-z0-9_-]+` | allow (`nostate`) |
| Identical read already redirected this session | allow (`bypass`) |
| Otherwise | exit 2 with the redirect message (`redirect`) |

Returned lines: Read is `min(limit if > 0, total - offset + 1 if offset > 0, else total)`; head/tail use `-n N`, `-N`, `-nN`, `--lines=N`, `-c`/`--bytes` (byte mode), `tail -n +K`, `head -n -K`, default 10; the others return the whole file. Returned bytes are pro rata. Bash decides per file and names the largest offender. The repeat key is the resolved path plus offset and limit for Read, and cwd plus the command string for Bash.

Every logged decision lands in `$XDG_STATE_HOME/claude-hooks/<date>.jsonl` as `{hook: "shunt-read"|"shunt-bash", result, lines, bytes, returned, threshold, duration_ms}`; the script logs `{hook: "bulk-read", result, files, bytes, lines, model, input_tokens, output_tokens, cache_creation_input_tokens, cache_read_input_tokens, cost_usd, child_duration_ms}` from the CLI's JSON result.

## Configuration

| Variable | Default | Used by |
|---|---|---|
| `SHUNT_DISABLE` | unset | hooks: `1` allows everything |
| `SHUNT_MIN_LINES` | 350 (non-numeric falls back) | hooks |
| `SHUNT_MIN_BYTES` | 60000 | hooks |
| `SHUNT_EXCLUDE` | unset | hooks and script: colon-separated globs on full path or basename |
| `SHUNT_CLAUDE_BIN` | `claude` from PATH | script |
| `SHUNT_MODEL` | `haiku` (`--model`) | script |
| `SHUNT_MAX_BUDGET_USD` | 0.05 (`--max-budget-usd`, per call) | script |
| `SHUNT_TIMEOUT_SECONDS` | 90 (coreutils `timeout`, +5s kill grace: inside the Bash tool's 2-minute default) | script |
| `SHUNT_MAX_PAYLOAD_BYTES` | 400000 | script |
| `SHUNT_MAX_FILES` | 12 | script |
| `SHUNT_MAX_OUTPUT_BYTES` | 12000 (truncated with a marker) | script |

`SHUNT_DEPTH` is set to 1 for the child (with `SHUNT_DISABLE=1`); bulk-read refuses to run when it is non-zero, so a child cannot recurse. Hook state lives in `${XDG_RUNTIME_DIR:-$HOME/.cache}/claude-shunt-{read,bash}-<session>.seen` (hashes only, pruned after two days), separate from the shared JSON state file because parallel hooks would race on it.

## The child invocation

`claude -p --model "$SHUNT_MODEL" --tools "" --system-prompt <prompt> --output-format json --no-session-persistence --safe-mode --strict-mcp-config --disable-slash-commands --max-budget-usd "$SHUNT_MAX_BUDGET_USD"`, run in the script's private temp dir with the question and payload on stdin. `--tools ""` removes every tool, so the child answers in one turn from stdin alone; `--safe-mode` drops CLAUDE.md, skills, plugins, hooks and MCP while keeping normal auth; the cwd keeps project context out. `--bare` was rejected because it only accepts `ANTHROPIC_API_KEY` auth. The CLI shows no max-turns flag (none is needed without tools). Credentials and base URL are whatever the environment gives Claude Code; the script reads none.

### Output and cost bounds (measured 2026-11-12, Claude Code 2.1.300, haiku)

There is no working output-token knob, so the answer is bounded only by the prompt (concise bullets, well under 400 words) and `SHUNT_MAX_OUTPUT_BYTES` truncation; `--max-budget-usd` caps cost. `CLAUDE_CODE_MAX_OUTPUT_TOKENS` does reach the child and caps each request, but an answer that hits it is retried in full (re-billing the whole input) up to four requests, and the call then fails with `api_error: max_output_tokens`. With a 300-token cap one call made 4 requests (`num_turns` 4, 1200 output tokens, 18992 cache-write tokens for a 4.8k-token prompt) and returned no answer; the same question with no cap took 1 request and 1287 output tokens. That retry is what billed one payload twice (22.4k write + 20.8k read) in the earlier comparison run. The script therefore removes the variable from the child's environment. Disabling thinking (`MAX_THINKING_TOKENS=0`, `alwaysThinkingEnabled: false`, `--effort low`) did not shorten such answers. `--max-budget-usd` is checked after a request: an over-budget answer is discarded (`error_max_budget_usd`) and the script fails with the fallback line, so the ceiling bounds runaway calls, not single small ones. Delegated calls cost about $0.001 to $0.002 for a 150-line file.

## Failure and bypass

The hooks fail open: any error, missing dependency or missing session allows the read. A redirected read can be forced by repeating it exactly. The script exits 1 with a one-line reason ending in "Fall back: Read the file with offset/limit ranges, or repeat the full Read." on every refusal and failure: usage errors, `SHUNT_DEPTH` set, `claude` not found, nonexistent/non-regular/binary/sensitive files, too many files, payload too large, timeout (`timeout` exit 124), a non-zero exit without JSON, a JSON result with `is_error` or a non-success subtype (classified as budget exceeded, output limit, auth, rate/usage limit, model unavailable or other; message shown, 300 bytes max), non-JSON output, empty answer. It does not retry.

## Security notes

- What leaves the machine: the question, the full content of the named files with line numbers, the paths as given and the fixed system prompt, sent to Anthropic by the child Claude Code: the same destination the main session already uses (or the proxy its `ANTHROPIC_BASE_URL` names), and nowhere else. No environment or directory listing is added.
- The hooks are not a security boundary; they only redirect and stay silent on sensitive paths, leaving existing permission rules in charge. The script's refusal list (`hooks/lib/shunt.sh`, checked on given and resolved paths, so a symlink to a secret is refused) is the real guard. If the list cannot be loaded the script sends nothing. The whole path is lowercased before matching. Names: `.env*`, `*.pem*`, `*.key*`, `*.p12*`, `*.pfx*`, `*.kdbx*`, `*.jks`, `*.gpg`, `*.asc`, `*.age`, `*.ovpn`, `id_rsa*`/`id_dsa*`/`id_ecdsa*`/`id_ed25519*`, `*.sops.*`, `keys.*`, `*secret*`, `*credential*`, `*token*`, `*passw*`, `.netrc`, `.npmrc`, `.pypirc`, `.pgpass`, `.boto`, `.s3cfg`, `kubeconfig*`, `*.tfstate*`, `*.tfvars`, `shadow`, `gshadow`. Directories: `secrets/`, `secret/`, `.ssh/`, `.gnupg/`, `.aws/`, `.azure/`, `.kube/`, `.docker/`, `.config/gh/`, `.config/sops/`, `.config/gcloud/`, `.password-store/`, `.local/share/keyrings/`, and `/run/secrets*`, `/run/agent-runtime/credentials*`, `/run/egress*`, `/etc/shadow*`, `/etc/gshadow*`, `/etc/sudoers*`, `/etc/ssh/ssh_host_*`. The net is wide on purpose; a false positive only means "read it directly".
- The script never reads, sets or prints a credential. The payload goes on stdin, never argv; only the static system prompt (with the per-call delimiter) is on argv.
- Prompt injection: file content is wrapped in a random per-call delimiter and the model is told never to follow instructions inside it, but a hostile file can still skew the answer. The skill treats every answer as a lead to verify with a ranged Read, never as ground truth.

## Rollback

Set `SHUNT_DISABLE=1` in the session environment, or turn the Nix option that registers the hooks off and switch. Nothing stateful needs undoing: the `.seen` files are disposable hashes and the JSONL log is append-only observability.

Attribution: hook and skill design adapted from Spotify's Shunt plugin, licensed under the Apache License 2.0.
