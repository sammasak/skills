# gh:* and git:* tasks: durable engineering evidence. One gh:work:<repo> and one
# git:recent:<repo> per fleet repo; gh:work and git:recent aggregate them with
# @completed. Every task here exits 0 once it has produced a record; failures are
# data (`error`, `failed_sources`), and only coord:brief decides the final exit.
{ lib, config, ... }:

let
  cfg = config.coordinator;
  t = lib.types;
  ts = toString cfg.timeoutSeconds;
  ghRepos = lib.filter (r: r.gh != null) cfg.repos;
  coRepos = lib.filter (r: r.checkout != null) cfg.repos;
  ghTask = r: lib.nameValuePair "gh:work:${r.name}" {
    description = "Open issues and recent PRs of ${r.gh} (bounded, raw).";
    exec = ''
      ${cfg.prelude}
      ctx=$(jq -cn --arg n ${lib.escapeShellArg r.name} --arg g ${lib.escapeShellArg r.gh} '{task:"gh:work",repo:$n,gh:$g}')
      at=$(now_iso); rc=0
      issues=$(timeout -k 1 ${ts} ${cfg.ghCommand} issue list -R ${lib.escapeShellArg r.gh} --state open --limit ${toString cfg.ghLimit} --json number,title,state,updatedAt,labels,url 2>/dev/null) || rc=$?
      [ "$rc" -eq 0 ] || { observe_error gh_error "gh issue list exited $rc" "$ctx"; exit 0; }
      prs=$(timeout -k 1 ${ts} ${cfg.ghCommand} pr list -R ${lib.escapeShellArg r.gh} --state all --limit ${toString cfg.ghLimit} --json number,title,state,isDraft,reviewDecision,mergedAt,updatedAt,headRefName,url,statusCheckRollup,closingIssuesReferences 2>/dev/null) || rc=$?
      [ "$rc" -eq 0 ] || { observe_error gh_error "gh pr list exited $rc" "$ctx"; exit 0; }
      out=$(jq -cn --arg at "$at" --argjson c "$ctx" --argjson i "$issues" --argjson p "$prs" '
        $c + {schema_version:1, observed_at:$at, error:null,
         issues: ($i | map({number, title, state, updated_at:.updatedAt, labels:((.labels // []) | map(.name)), url})),
         prs: ($p | map({number, title, state, draft:.isDraft, review_decision:(.reviewDecision // ""), merged_at:.mergedAt, updated_at:.updatedAt,
                        branch:.headRefName, url, checks:((.statusCheckRollup // []) | map((.conclusion | select(. != null and . != "")) // .state // "PENDING")),
                        closes:((.closingIssuesReferences // []) | map(.number))}))}' 2>/dev/null) \
        || { observe_error malformed "gh returned unexpected JSON" "$ctx"; exit 0; }
      emit "$out"
    '';
  };
  gitTask = r: lib.nameValuePair "git:recent:${r.name}" {
    description = "Recent commits, dirty tree and unpushed work in ${r.checkout}.";
    exec = ''
      ${cfg.prelude}
      co=${lib.escapeShellArg r.checkout}
      ctx=$(jq -cn --arg n ${lib.escapeShellArg r.name} --arg c "$co" '{task:"git:recent",repo:$n,checkout:$c}')
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
  aggregate = name: items: {
    description = "Aggregate of ${name}:<repo>; partial on failures, never fails itself.";
    after = map (n: "${name}:${n}@completed") items;
    exec = ''
      ${cfg.prelude}
      at=$(now_iso); out="[]"; failed="[]"
      for name in ${lib.concatStringsSep " " items}; do
        up=$(upstream "${name}:$name")
        if [ "$up" = null ]; then failed=$(jq -c --arg n "$name" '. + [{repo:$n, error:{kind:"missing", message:"task produced no output"}}]' <<<"$failed")
        elif [ "$(jq -r '.error' <<<"$up")" != null ]; then failed=$(jq -c --argjson u "$up" '. + [{repo:$u.repo, error:$u.error}]' <<<"$failed")
        else out=$(jq -c --argjson u "$up" '. + [$u]' <<<"$out"); fi
      done
      emit "$(jq -cn --arg at "$at" --argjson r "$out" --argjson f "$failed" '{schema_version:1, task:"${name}", observed_at:$at, partial:(($f|length) > 0), failed_sources:$f, repos:$r}')"
    '';
  };
in
{
  imports = [ ./fleet.nix ];

  options.coordinator = {
    ghCommand = lib.mkOption { type = t.str; default = "gh"; };
    ghLimit = lib.mkOption { type = t.int; default = 20; };
    gitSince = lib.mkOption { type = t.str; default = "48 hours ago"; };
  };

  config.tasks = lib.listToAttrs (map ghTask ghRepos) // lib.listToAttrs (map gitTask coRepos) // {
    "gh:work" = aggregate "gh:work" (map (r: r.name) ghRepos);
    "git:recent" = aggregate "git:recent" (map (r: r.name) coRepos);
  };
}
