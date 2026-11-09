"""PreToolUse Bash hook, worker hosts only (skills#28): the review gate for merging a pull request.

Workers run in bypassPermissions, so no classifier asks before a merge. This refuses one unless:
  1. it is `gh pr merge <N> --match-head-commit <40-hex>` and that sha is still the PR's head (a REST
     `gh api .../pulls/N/merge` or GraphQL `mergePullRequest` is refused outright: no pinned head to check);
  2. THIS session was handed the merge by the Coordinator: its transcript holds an assignment for this
     host/pane whose `Allowed actions:` include merge and that names this PR -- `Merge target: <url>`,
     or `Review of: OWNER/REPO#N at head <that sha>`. herdr:message sends neither to the PR's implementer
     (author_merge, #70) and records both in its audit (#77): who may merge comes from that, not from text;
  3. the PR carries `Grade: N/10 (head <prefix of that sha>)` with N >= 9 (the bar the handoff names).
Trust model: GitHub comments all post as one account, so a comment's signature is never identity; the
transcript's user turns are the Coordinator's audited prompts. A command is parsed (shlex), so an absolute
path to gh, `env`/`command`/`exec` prefixes, `sh -c`/`bash -c` strings and `eval` are seen; a quoted
mention (echo, a commit message) is not a merge. Unparsable input or a failed `gh` read fails closed.
"""
import json
import os
import re
import shlex
import subprocess
import sys

SHELLS = {"sh", "bash", "dash", "zsh", "fish", "ksh"}
PREFIXES = {"env", "command", "exec", "nohup", "time", "sudo", "doas", "xargs", "timeout", "nice"}
PUNCT = ";&|()`\n"
HEREDOC = re.compile(r"<<-?[ \t]*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1[^\n]*\n(.*?)^[ \t]*\2[ \t]*$", re.S | re.M)
GRADE = re.compile(r"Grade: ([0-9]+(?:\.[0-9]+)?)/10 \(head ([0-9a-f]{7,40})\)")


def block(msg):
    print(f"BLOCKED: merge: {msg}", file=sys.stderr)
    sys.exit(2)


def commands(text, depth=0):
    """Every simple command in a shell string, recursing into `-c` strings and eval; quoted words stay words."""
    if depth > 4:
        block("command nests shells too deeply to check")
    # a heredoc body is data (a file being written), not commands: drop it, keep the line that opens it
    text = HEREDOC.sub(lambda m: m.group(0).split("\n", 1)[0] + "\n", text)
    lex = shlex.shlex(text, posix=True, punctuation_chars=PUNCT)
    lex.whitespace = " \t\r"
    lex.whitespace_split = True
    lex.commenters = ""
    try:
        words = list(lex)
    except ValueError:
        block("could not parse the command (unbalanced quotes)")
    cmd = []
    for w in words + [";"]:
        if set(w) <= set(PUNCT):
            if cmd:
                yield from expand(cmd, depth)
            cmd = []
        else:
            cmd.append(w)


def expand(cmd, depth):
    while cmd and (re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", cmd[0]) or os.path.basename(cmd[0]) in PREFIXES):
        head = os.path.basename(cmd[0])
        cmd = cmd[1:]
        if head == "timeout" and cmd and not cmd[0].startswith("-"):
            cmd = cmd[1:]  # the duration
        while cmd and cmd[0].startswith("-") and head in PREFIXES:
            cmd = cmd[1:]
    if not cmd:
        return
    exe = os.path.basename(cmd[0])
    if exe in SHELLS:
        for i, a in enumerate(cmd[1:], 1):
            if re.fullmatch(r"-[a-zA-Z]*c[a-zA-Z]*", a) and i + 1 < len(cmd):
                yield from commands(cmd[i + 1], depth + 1)
                return
        return
    if exe == "eval":
        yield from commands(" ".join(cmd[1:]), depth + 1)
        return
    yield [exe] + cmd[1:]


def merges(text):
    for c in commands(text):
        if c[0] != "gh":
            continue
        args = c[1:]
        if args[:2] == ["pr", "merge"]:
            yield ("pr", args[2:])
        elif args[:1] == ["api"]:
            joined = " ".join(args[1:])
            if re.search(r"pulls/[0-9]+/merge\b", joined) or "mergePullRequest" in joined or "enablePullRequestAutoMerge" in joined:
                yield ("api", args[1:])


def parse_pr_merge(args):
    pr = repo = head = None
    i = 0
    while i < len(args):
        a = args[i]
        if a in ("-R", "--repo"):
            i += 1
            repo = args[i] if i < len(args) else None
        elif a.startswith("--repo="):
            repo = a.split("=", 1)[1]
        elif a == "--match-head-commit":
            i += 1
            head = args[i] if i < len(args) else None
        elif a.startswith("--match-head-commit="):
            head = a.split("=", 1)[1]
        elif a in ("-t", "--subject", "-b", "--body", "-F", "--body-file", "-A", "--author-email"):
            i += 1
        elif not a.startswith("-") and pr is None:
            pr = a.rstrip("/").rsplit("/pull/", 1)[-1]
        i += 1
    return pr, repo, head


def user_texts(path):
    """The user turns of this session's transcript: the prompts Herdr delivered."""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                try:
                    e = json.loads(line)
                except ValueError:
                    continue
                if e.get("type") != "user":
                    continue
                c = (e.get("message") or {}).get("content")
                if isinstance(c, str):
                    yield c
                elif isinstance(c, list):
                    for item in c:
                        if isinstance(item, dict) and item.get("type") == "text":
                            yield item.get("text", "")
    except OSError:
        return


def authorized(transcript, me_host, me_pane, repo, num, head):
    url = f"https://github.com/{repo}/pull/{num}"
    for t in user_texts(transcript):
        m = re.search(r"^Assignment \S+ for ([A-Za-z0-9._-]+)/([A-Za-z0-9]+:p[0-9]+)\s*$", t, re.M)
        if not m or m.group(2) != me_pane or m.group(1).split("-")[0].lower() != me_host:
            continue
        acts = re.search(r"^Allowed actions: ([^.\n]*)", t, re.M)
        if not acts or "merge" not in [a.strip() for a in acts.group(1).split(",")]:
            continue
        if re.search(rf"^Merge target: {re.escape(url)}\s*$", t, re.M):
            return "merge handoff"
        r = re.search(rf"^Review of: {re.escape(repo)}#{num} at head ([0-9a-f]{{7,40}})\s*$", t, re.M)
        if r and head.startswith(r.group(1)):
            return "review handoff"
    return None


def main():
    try:
        hook = json.load(sys.stdin)
    except ValueError:
        sys.exit(0)  # not a hook call we understand: nothing to judge
    cmd = (hook.get("tool_input") or {}).get("command") or ""
    found = list(merges(cmd))
    if not found:
        sys.exit(0)
    if len(found) > 1:
        block("one merge per command")
    kind, args = found[0]
    if kind == "api":
        block("merge with `gh pr merge <N> --match-head-commit <sha>`, not through the API: the API path pins no reviewed head")
    pr, repo, head = parse_pr_merge(args)
    if not pr or not pr.isdigit():
        block(f"name the PR number (got {pr!r}); a merge of the current branch is not reviewable here")
    if not head or not re.fullmatch(r"[0-9a-f]{40}", head):
        block("pin the graded head: --match-head-commit <40-hex sha>")
    view_cmd = ["gh", "pr", "view", pr] + (["-R", repo] if repo else []) + ["--json", "url,headRefOid,comments"]
    try:
        view = json.loads(subprocess.run(view_cmd, capture_output=True, text=True, check=True, timeout=25).stdout)
    except (subprocess.SubprocessError, OSError, ValueError):
        block(f"could not read PR #{pr} to check its review (fail closed)")
    if view.get("headRefOid") != head:
        block(f"PR #{pr}'s head is {view.get('headRefOid') or 'unknown'}, not the pinned {head}; the grade must be on the head you merge")
    m = re.fullmatch(r"https://github\.com/([^/]+/[^/]+)/pull/([0-9]+)", view.get("url") or "")
    if not m:
        block(f"could not resolve PR #{pr}'s repository (fail closed)")
    full_repo, num = m.group(1), m.group(2)
    pane = os.environ.get("HERDR_PANE_ID", "")
    host = (os.environ.get("CHECK_MERGE_TEST_HOST") or os.uname().nodename).split(".")[0].split("-")[0].lower()
    if not pane:
        block("not in a Herdr pane: a worker merges only on a Coordinator handoff")
    why = authorized(hook.get("transcript_path") or "", host, pane, full_repo, num, head)
    if not why:
        block(f"no Coordinator handoff in this session authorizes {host} {pane} to merge {full_repo}#{num} at {head[:7]} "
              "(a merge handoff naming it, or a review handoff for this head, with merge allowed); the implementer never gets one")
    graded = any(float(g) >= 9 and head.startswith(h)
                 for c in view.get("comments") or [] for g, h in GRADE.findall(c.get("body") or ""))
    if not graded:
        block(f"{full_repo}#{num} carries no 'Grade: N/10 (head {head[:7]})' with N >= 9 on this head; get the review first")
    sys.exit(0)


if __name__ == "__main__":
    main()
