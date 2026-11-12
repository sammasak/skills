# Shunt: redirect large exploratory reads to an inexpensive model

## What it does

Two PreToolUse hooks notice when Claude Code is about to put more than about 8000 tokens of one file into context (a `Read`, or `cat`/`head`/`tail`/`less`/`more`/`bat`/`nl` through Bash) and deny that first attempt with a message carrying the exact `scripts/bulk-read.sh` command and a range that fits. The script hands the files and one question to headless Claude Code (`claude -p`, haiku by default, no tools) and prints a short, cited answer, so only the answer enters context. Delegated tokens are Anthropic usage on the same account: cheaper per token than the main model, not free. The `bulk-reader` skill tells Claude when to use it and when not to. Any later read of the same file in the session is allowed, so the redirect is a nudge, never a wall.

Files: `hooks/shunt-check-read.sh`, `hooks/shunt-check-bash-read.sh`, `hooks/lib/shunt.sh` (shared policy), `hooks/lib/state.sh` (`seen_before`), `scripts/bulk-read.sh`, `skills/bulk-reader/SKILL.md`, `tests/test-shunt.sh` (`devenv tasks run skills:test:shunt`, also in pre-push).

## Upstream and what changed

Adapted from Spotify's Shunt plugin (`plugins/shunt`, Apache-2.0). Upstream blocks Read on files over 350 lines unless `offset` or `limit` is set, blocks `cat`/`head`/`tail`/`less`/`more` on the first non-flag argument, and points at a skill that runs `bulk-read` through Spotify's internal portal CLI.

Reused: the hook to skill to script flow, and the eval case shapes (threshold boundary, empty file, offset/limit, pipes and redirects) now in `tests/test-shunt.sh`.

Changed:

- Headless Claude Code on haiku instead of portal-cli: no gateway or extra credential, the transport is one function (`run_claude`), and tests swap the binary via a fake `claude` on PATH.
- Sensitive paths are never delegated, checked on the given and the symlink-resolved path; the script refuses them.
- Payload lines carry real line numbers inside a per-call random delimiter; the system prompt treats file content as untrusted data.
- Output, payload, file-count and time bounds.
- A token estimate instead of the 350-line threshold, with exemptions for source code, instruction files, `allow_large`, non-interactive modes and lookup subagents.
- Repeat-bypass instead of indefinite blocking: any later read of the same file in a session is allowed and logged.
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
| `permission_mode` is `dontAsk` (cannot run the script) or `plan` | allow (`mode`) |
| `agent_type` is in `SHUNT_SKIP_AGENTS` | allow (`subagent`) |
| Read: `allow_large: true` | allow (`explicit`) |
| Bash: `tail -f/-F`, unknown option, unparseable count (`-n 1K`) | allow (`follow`, `unparsed`) |
| Read: negative, non-numeric or too-large offset, or non-numeric or negative limit (fractions such as `1700.0` or `1e3` are floored and used; a too-large limit counts as huge) | allow (`unparsed`) |
| Path missing, not a regular file, or no file arguments | allow |
| Sensitive or `SHUNT_EXCLUDE` path (given or resolved) | allow (`sensitive`) |
| Image, PDF, notebook, or a NUL byte in the first 64 KiB | allow (`nontext`, Bash skips that file) |
| `CLAUDE.md`, `AGENTS.md`, `ROLE.md`, `SKILL.md`, `MEMORY.md`, anything under a `.claude/` directory, anything in the skills repo the hooks live in | allow (`instructions`) |
| Source code (`.rs .nix .py .ts .tsx .js .go .sh .c .java .kt .rb .lua .tf .zig .swift .cs .ex .hs`, about 50 more, `Makefile`, `Dockerfile`, `justfile`; not `.sql .css .v .r .m .s .pl` or `*.min.js`/`*.min.css`, which are often data) unless `SHUNT_INCLUDE_SOURCE=1` | allow (`source`) |
| Estimated tokens <= `SHUNT_MIN_TOKENS` | allow (`allow`, or `targeted` for a range) |
| Would redirect, but the file is private-mode or holds key material (the script would refuse it) | allow (`private`, `secret`) |
| No session id, or one that is not `[A-Za-z0-9_-]+`, or the state file is unusable | allow (`nostate`) |
| This resolved file was already redirected this session, by either hook | allow (`bypass`) |
| Otherwise | exit 2 with the redirect message (`redirect`) |

Estimated tokens are `bytes*2/7 + lines*11/10` over the part the read returns. Returned lines: Read is `min(limit if > 0, total - offset + 1 if offset > 0, else total)`, capped at 2000 when no limit is given (Read's own default); head/tail use `-n N`, `-N`, `-nN`, `--lines=N`, `-c`/`--bytes` (byte mode), `tail -n +K`, `head -n -K`, default 10; the others return the whole file. Returned bytes are pro rata. Bash decides per file and names the file with the largest estimate. The repeat key is the `realpath` of the file, in one state file shared by both hooks, so the second read of a file in any shape (whole, `offset: 1`, `cat  f`, a symlink) passes.

The message gives the script command, or, for a file over `SHUNT_MAX_PAYLOAD_BYTES`, says to use Grep or a range instead. It names the most lines one ranged Read can return under the threshold (omitted for files under 5 lines or with a single line over the threshold), says to Read the range you will change if you will edit the file, and says that repeating the read is enough (no `allow_large` needed).

### Why 8000 tokens

From 7,163 real Read calls in our transcripts: delegating breaks even at a median of about 3.4k tokens (5.9k pessimistic). 350 lines of Rust is about 4k tokens, so the old line rule fired below break-even, and lines under-count markdown about 2x. At over 8000 estimated tokens, 84% of redirects pay off, against 69% for the old rule. Source is exempt because 35% of large source reads are followed by an Edit of the same file, where delegating is pure waste. A 2000-line 9 KB file (about 4.7k tokens) and a 241-line 17.5 KB `ROLE.md` (instructions anyway) do not trigger.

Every logged decision lands in `$XDG_STATE_HOME/claude-hooks/<date>.jsonl` as `{hook: "shunt-read"|"shunt-bash", result, lines, bytes, returned, tokens, threshold, duration_ms}`. The script adds one line per call: `{hook: "bulk-read", result, event: "delegated"|"refused", files, bytes, lines, bytes_sent, exit_status, claude_exit, model, input_tokens, output_tokens, cache_creation_input_tokens, cache_read_input_tokens, cost_usd, child_duration_ms, num_turns}`, so the redirect, bypass and delegated counts can be compared later.

## Configuration

| Variable | Default | Used by |
|---|---|---|
| `SHUNT_DISABLE` | unset | hooks: `1` allows everything |
| `SHUNT_MIN_TOKENS` | 8000 (non-numeric falls back) | hooks |
| `SHUNT_INCLUDE_SOURCE` | unset | hooks: `1` puts source code under the threshold too |
| `SHUNT_SKIP_AGENTS` | `Explore,claude-code-guide,statusline-setup` | hooks: comma-separated `agent_type` values to leave alone; set empty to cover every agent |
| `SHUNT_EXCLUDE` | unset | hooks and script: colon-separated glob patterns, matched against the full path or the basename (never expanded against the filesystem) |
| `SHUNT_MAX_PAYLOAD_BYTES` | 200000 | script; hooks stop suggesting the script above it |
| `SHUNT_CLAUDE_BIN` | `claude` from PATH | script |
| `SHUNT_MODEL` | `haiku` (`--model`) | script |
| `SHUNT_MAX_BUDGET_USD` | 0.15 (`--max-budget-usd`, per call; covers a payload at the cap) | script |
| `SHUNT_TIMEOUT_SECONDS` | 90 (coreutils `timeout`, +5s kill grace: inside the Bash tool's 2-minute default) | script |
| `SHUNT_MAX_FILES` | 12 | script |
| `SHUNT_MAX_OUTPUT_BYTES` | 12000 (truncated with a marker) | script |

Removed: `SHUNT_MIN_LINES` and `SHUNT_MIN_BYTES` (replaced by `SHUNT_MIN_TOKENS`; setting them has no effect) and `SHUNT_MAX_OUTPUT_TOKENS` (see below).

`SHUNT_DEPTH` is set to 1 for the child (with `SHUNT_DISABLE=1`); bulk-read refuses to run when it is non-zero, so a child cannot recurse. Hook state lives in `${XDG_RUNTIME_DIR:-$HOME/.cache}/claude-shunt-<session>.seen` (hashes only, pruned after two days), separate from the shared JSON state file because parallel hooks would race on it.

Permission prompts: in an interactive session in `default` permission mode, each `bulk-read.sh` call is a Bash command and is prompted for unless the owner adds an allow rule for it. This change adds none.

## The child invocation

`claude -p --model "$SHUNT_MODEL" --tools "" --system-prompt <prompt> --output-format json --no-session-persistence --safe-mode --strict-mcp-config --disable-slash-commands --max-budget-usd "$SHUNT_MAX_BUDGET_USD"`, run in one stable empty directory (`${XDG_CACHE_HOME:-$HOME/.cache}/shunt-bulk-read`) with the question and payload on stdin, and without the parent's identity variables (`CLAUDE_CODE_SESSION_ID`, `CLAUDE_CODE_CHILD_SESSION`, `CLAUDE_CODE_MESSAGING_SOCKET`, `CLAUDE_CODE_MESSAGING_TOKEN`, `CLAUDE_CODE_SESSION_ATTENDED`, `CLAUDE_PID`, `CLAUDE_EFFORT`, every `HERDR_*`), so Herdr does not see a phantom agent. `--tools ""` removes every tool, so the child answers in one turn from stdin alone; `--safe-mode` drops CLAUDE.md, skills, plugins, hooks and MCP while keeping normal auth; the cwd keeps project context out. `--bare` was rejected because it only accepts `ANTHROPIC_API_KEY` auth. The CLI shows no max-turns flag (none is needed without tools). Credentials and base URL are whatever the environment gives Claude Code; the script reads none.

### Output and cost bounds (measured 2026-11-12, Claude Code 2.1.300, haiku)

There is no working output-token knob, so the answer is bounded only by the prompt (concise bullets, well under 400 words) and `SHUNT_MAX_OUTPUT_BYTES` truncation; `--max-budget-usd` caps cost. `CLAUDE_CODE_MAX_OUTPUT_TOKENS` does reach the child and caps each request, but an answer that hits it is retried in full (re-billing the whole input) up to four requests, and the call then fails with `api_error: max_output_tokens`. With a 300-token cap one call made 4 requests (`num_turns` 4, 1200 output tokens, 18992 cache-write tokens for a 4.8k-token prompt) and returned no answer; the same question with no cap took 1 request and 1287 output tokens. That retry is what billed one payload twice (22.4k write + 20.8k read) in the earlier comparison run. The script therefore removes the variable from the child's environment. Disabling thinking (`MAX_THINKING_TOKENS=0`, `alwaysThinkingEnabled: false`, `--effort low`) did not shorten such answers. `--max-budget-usd` is checked after a request: an over-budget answer is discarded (`error_max_budget_usd`) and the script fails with the fallback line, so the ceiling bounds runaway calls, not single small ones. Delegated calls cost about $0.001 to $0.002 for a 150-line file.

## Failure and bypass

The hooks fail open: any error, missing dependency or missing session allows the read. A redirected read passes on any second read of the same file. The script exits 1 with a one-line reason ending in "Fall back: Read the file with offset/limit ranges, or repeat the full Read." on every refusal and failure: usage errors, `SHUNT_DEPTH` set, `jq` or `claude` not found, nonexistent/non-regular/binary/sensitive/private-mode/key-material files, too many files, payload too large, timeout (`timeout` exit 124), a non-zero exit without JSON (stderr shown, or stdout when stderr is empty, so "Not logged in" reaches the model), a JSON result with `is_error` or a non-success subtype (classified as budget exceeded, output limit, auth, rate/usage limit, model unavailable or other; message shown, 300 bytes max), non-JSON output, empty answer. It does not retry.

## Security notes

- What leaves the machine: the question, the full content of the named files with line numbers, the paths as given and the fixed system prompt, sent to Anthropic by the child Claude Code: the same destination the main session already uses (or the proxy its `ANTHROPIC_BASE_URL` names), and nowhere else. No environment or directory listing is added.
- The hooks are not a security boundary; they only redirect and stay silent on sensitive files, leaving existing permission rules in charge. The script's refusals (`hooks/lib/shunt.sh`) are the real guard; if that file cannot be loaded the script sends nothing. Each file is resolved once with `realpath`; the name checks run on the given, absolute and resolved paths (so a symlink to a secret is refused), and the content checks and `cat` use the resolved path.
- Names, matched on the lowercased path: `.env*`, `*.env`, `*.pem*`, `*.key*`, `*.p12*`, `*.pfx*`, `*.p8`, `*.der`, `*.kdbx*`, `*.jks`, `*.gpg`, `*.asc`, `*.age`, `*.ovpn`, `id_rsa*`/`id_dsa*`/`id_ecdsa*`/`id_ed25519*`, `ssh_host_*`, `*private*key*`, `*key.txt`, `keys.*`, `*.sops.*`, `*passw*`, `.netrc`, `.npmrc`, `.pypirc`, `.pgpass`, `.boto`, `.s3cfg`, `.my.cnf`, `.dev.vars`, `auth.json`, `wg*.conf`, `rclone.conf`, `*history*`, `.histfile`, `talosconfig`, `.msmtprc`, `.mbsyncrc`, `.authinfo*`, `.claude.json` (`.envrc` via `.env*`), `kube*config*`, `k3s.yaml`, `admin.conf`, `*.tfstate*`, `*.tfvars`, `shadow`, `gshadow`. Anywhere in the path (any directory or the name): `secret`, `credential`, `token`. Directories: `.ssh/`, `.gnupg/`, `.aws/`, `.azure/`, `.kube/`, `.docker/`, `.codex/`, `.password-store/`, `.config/{gh,sops,gcloud,age,rclone,talos}/`, `.local/share/keyrings/`, `etc/wireguard/`, `etc/rancher/`, `var/lib/sops-nix/`, `/run/egress*`, `/etc/shadow*`, `/etc/gshadow*`, `/etc/sudoers*`, `/etc/ssh/ssh_host_*`. The net is wide on purpose; a false positive only means "read it directly".
- A name list always has another gap, so two checks on the file itself back it. Private mode: a file readable by neither group nor other (0600, 0400) is refused (`private`). The mode is a signal only when the caller's umask would normally grant group or other read; under a private umask such as 077, where every file is 0600, this check stands down and only names and content guard. Consequence: with a 022-style umask, a source file deliberately kept at 0600 is never delegated. Key material: a file whose first 64 KiB contain `PRIVATE KEY-----` (PEM, OpenSSH, encrypted), `-----BEGIN PGP PRIVATE KEY BLOCK-----`, `AGE-SECRET-KEY-1`, `ENC[AES256_GCM,`, `sops:` together with `ENC[`, `LS0tLS1CRUdJTi` (base64 of `-----BEGIN`, as in kubeconfig `client-key-data`, Talos configs and TLS Secrets; certificates match too), a plaintext Kubernetes Secret (`kind: Secret`, quoted or not, at a line start after spaces or `- `, so List items count; or JSON `"kind" : "Secret"` with any spacing), a token-auth kubeconfig (`kind: Config` plus a `token:` line), a WireGuard `PrivateKey =` or `PresharedKey =` line, or the token prefixes `ghp_`, `github_pat_`, `sk-ant-` and `access-tokens` is refused (`secret`). A manifest that only mentions `kind: Secret` mid-line is still delegated.
- On these hosts the umask is 077, so the mode check is off and the name list plus the content markers are the only guard.
- Known limits: a secret past the first 64 KiB, password-manager exports, database dumps, and any other file that neither looks like a secret by name nor carries one of the markers is not detected and would be sent. The script is a guard against accidents, not a data-loss-prevention tool.
- The hooks apply the same two checks, but only to a read they would otherwise redirect: such a file is read normally (logged `private` or `secret`), never pointed at a script that would refuse it.
- The script never reads, sets or prints a credential. The payload goes on stdin, never argv; only the static system prompt (with the per-call delimiter) is on argv.
- Prompt injection: file content is wrapped in a random per-call delimiter and the model is told never to follow instructions inside it, but a hostile file can still skew the answer. The skill treats every answer as a lead to verify with a ranged Read, never as ground truth.

## Design notes: considered, not done

- Clamping instead of denying: a PreToolUse hook can rewrite the Read with `updatedInput` (a fitting `limit`) and explain it via `additionalContext`, which is documented and would save the denied turn. Not done: it is unverified whether a clamped Read satisfies Edit's read-before-edit check, and how auto mode treats a rewritten Read.
- Gating on the main model (redirect only when it is expensive): hooks do not receive the model, so there is nothing to gate on.

## Rollback

Set `SHUNT_DISABLE=1` in the session environment, or turn the Nix option that registers the hooks off and switch. Nothing stateful needs undoing: the `.seen` files are disposable hashes and the JSONL log is append-only observability.

Attribution: hook and skill design adapted from Spotify's Shunt plugin, licensed under the Apache License 2.0.
