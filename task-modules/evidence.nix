# gh:* and git:* tasks: durable engineering evidence on demand, one repo per call (no repo registry): gh:work
# takes OWNER/REPO (usually named in an agent's title), git:recent a local checkout path. Observations exit 0
# once they produced a record; failures are data (`error`); only coord:brief decides the final exit.
{ lib, config, ... }:
let
  cfg = config.coordinator;
  ts = toString cfg.timeoutSeconds;
in
{
  imports = [ ./common.nix ];

  tasks = {
    "gh:work" = {
      description = "Open issues and recent open/merged PRs of one GitHub repo (bounded, raw).";
      input = { repo = null; };
    exec = ''
      ${cfg.prelude}
      gh=$(input .repo); ctx=$(jq -cn --arg g "$gh" '{task:"gh:work",repo:$g,gh:$g}')
      [[ "$gh" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail 3 invalid_input "repo must be OWNER/REPO" "$ctx"
      at=$(now_iso); rc=0
      issues=$(timeout -k 1 ${ts} ${cfg.ghCommand} issue list -R "$gh" --state open --limit ${toString cfg.ghLimit} --json number,title,state,updatedAt,labels,url 2>/dev/null) || rc=$?
      [ "$rc" -eq 0 ] || { observe_error gh_error "gh issue list exited $rc" "$ctx"; exit 0; }
      fields=number,title,state,isDraft,reviewDecision,mergedAt,updatedAt,headRefName,url,statusCheckRollup,closingIssuesReferences
      open_prs=$(timeout -k 1 ${ts} ${cfg.ghCommand} pr list -R "$gh" --state open --limit ${toString cfg.ghLimit} --json "$fields" 2>/dev/null) || rc=$?
      [ "$rc" -eq 0 ] || { observe_error gh_error "gh pr list (open) exited $rc" "$ctx"; exit 0; }
      merged_prs=$(timeout -k 1 ${ts} ${cfg.ghCommand} pr list -R "$gh" --state merged --limit ${toString cfg.ghLimit} --json "$fields" 2>/dev/null) || rc=$?
      [ "$rc" -eq 0 ] || { observe_error gh_error "gh pr list (merged) exited $rc" "$ctx"; exit 0; }
      prs=$(jq -cn --argjson o "$open_prs" --argjson m "$merged_prs" '$o + $m') || { observe_error malformed "gh returned unexpected JSON" "$ctx"; exit 0; }
      out=$(jq -cn --arg at "$at" --argjson c "$ctx" --argjson i "$issues" --argjson p "$prs" --argjson no "$(jq 'length' <<<"$open_prs")" '
        $c + {schema_version:1, observed_at:$at, error:null, open_pr_count:$no,
         issues: ($i | map({number, title, state, updated_at:.updatedAt, labels:((.labels // []) | map(.name)), url})),
         prs: ($p | map({number, title, state, draft:.isDraft, review_decision:(.reviewDecision // ""), merged_at:.mergedAt, updated_at:.updatedAt,
                        branch:.headRefName, url, checks:((.statusCheckRollup // []) | map((.conclusion | select(. != null and . != "")) // .state // "PENDING")),
                        closes:((.closingIssuesReferences // []) | map(.number))}))}' 2>/dev/null) \
        || { observe_error malformed "gh returned unexpected JSON" "$ctx"; exit 0; }
      emit "$out"
    '';
  };
    "git:recent" = {
      description = "Recent commits, dirty tree and unpushed work in one local checkout.";
      input = { checkout = null; };
    exec = ''
      ${cfg.prelude}
      co=$(input .checkout); ctx=$(jq -cn --arg c "$co" '{task:"git:recent",repo:(($c|split("/"))[-1]),checkout:$c}')
      [[ "$co" =~ ^/[A-Za-z0-9_./-]+$ ]] && [[ "/$co/" != *"/../"* ]] || fail 3 invalid_input "checkout must be a plain absolute path" "$ctx"
      at=$(now_iso)
      g() { timeout -k 1 ${ts} git -C "$co" "$@" 2>/dev/null; }
      [ -e "$co/.git" ] || { observe_error not_found "no git checkout at $co" "$ctx"; exit 0; }
      head=$(g rev-parse --short HEAD) || { observe_error command_failed "git rev-parse failed in $co" "$ctx"; exit 0; }
      branch=$(g rev-parse --abbrev-ref HEAD) || branch=HEAD
      status=$(g status --porcelain) || { observe_error command_failed "git status failed in $co" "$ctx"; exit 0; }
      dirty=$(grep -c . <<<"$status" || true)
      up=$(g rev-parse --abbrev-ref --symbolic-full-name '@{u}') || up=""
      ahead=null; behind=null; unpushed="[]"
      if [ -n "$up" ]; then
        counts=$(g rev-list --left-right --count "$up...HEAD") || { observe_error command_failed "git rev-list failed in $co" "$ctx"; exit 0; }
        behind=''${counts%%[[:space:]]*}; ahead=''${counts##*[[:space:]]}
        unpushed=$(g log --format='%h%x1f%s' "$up..HEAD" | jq -Rsc 'split("\n") | map(select(length>0) | split("\u001f") | {sha:.[0], subject:.[1]})') || { observe_error command_failed "git log failed in $co" "$ctx"; exit 0; }
      fi
      commits=$(g log --since=${lib.escapeShellArg cfg.gitSince} --format='%h%x1f%cI%x1f%s' -n 20 | jq -Rsc 'split("\n") | map(select(length>0) | split("\u001f") | {sha:.[0], at:.[1], subject:.[2]})') || { observe_error command_failed "git log failed in $co" "$ctx"; exit 0; }
      emit "$(jq -cn --arg at "$at" --argjson c "$ctx" --arg head "$head" --arg br "$branch" --argjson dirty "$dirty" --argjson ahead "$ahead" --argjson behind "$behind" --arg up "$up" --argjson cm "$commits" --argjson u "$unpushed" \
        '$c + {schema_version:1, observed_at:$at, error:null, head:$head, branch:$br, upstream:(if $up == "" then null else $up end), dirty_files:$dirty, ahead:$ahead, behind:$behind, unpushed:$u, commits:$cm}')"
    '';
  };
  };
}
