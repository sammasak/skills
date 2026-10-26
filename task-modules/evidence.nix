# gh:* and git:* tasks: durable engineering evidence. One gh:work:<repo> and one
# git:recent:<repo> per fleet repo; gh:work and git:recent aggregate them with
# @completed. Like herdr:list, a per-repo task always completes its observation
# and carries error as data.
{ lib, config, ... }:

let
  cfg = config.coordinator;
  t = lib.types;
  repoNames = map (r: r.name) cfg.repos;
  ghRepos = lib.filter (r: r.gh != null) cfg.repos;
  coRepos = lib.filter (r: r.checkout != null) cfg.repos;
  ghTask = r: lib.nameValuePair "gh:work:${r.name}" {
    description = "Open issues and recent PRs of ${r.gh} (bounded, raw).";
    exec = ''
      set -uo pipefail
      . ${cfg.lib}
      at=$(now_iso); rc=0
      issues=$(timeout -k 1 ${toString cfg.timeoutSeconds} ${cfg.ghCommand} issue list -R ${r.gh} --state open --limit ${toString cfg.ghLimit} --json number,title,state,updatedAt,labels,url 2>/dev/null) || rc=$?
      [ "$rc" -eq 0 ] || { observe_error gh_error "gh issue list exited $rc" '{"task":"gh:work","repo":"${r.name}","gh":"${r.gh}"}'; exit 0; }
      prs=$(timeout -k 1 ${toString cfg.timeoutSeconds} ${cfg.ghCommand} pr list -R ${r.gh} --state all --limit ${toString cfg.ghLimit} --json number,title,state,isDraft,reviewDecision,mergedAt,updatedAt,headRefName,url,statusCheckRollup,closingIssuesReferences 2>/dev/null) || rc=$?
      [ "$rc" -eq 0 ] || { observe_error gh_error "gh pr list exited $rc" '{"task":"gh:work","repo":"${r.name}","gh":"${r.gh}"}'; exit 0; }
      out=$(jq -cn --arg at "$at" --argjson i "$issues" --argjson p "$prs" '
        {schema_version:1, task:"gh:work", repo:"${r.name}", gh:"${r.gh}", observed_at:$at, error:null,
         issues: ($i | map({number, title, state, updated_at:.updatedAt, labels:(.labels|map(.name)), url})),
         prs: ($p | map({number, title, state, draft:.isDraft, review_decision:(.reviewDecision // ""), merged_at:.mergedAt, updated_at:.updatedAt,
                        branch:.headRefName, url, checks:(.statusCheckRollup // [] | map(.conclusion // .state // "UNKNOWN")),
                        closes:((.closingIssuesReferences // []) | map(.number))}))}' 2>/dev/null) \
        || { observe_error malformed "gh returned unexpected JSON" '{"task":"gh:work","repo":"${r.name}","gh":"${r.gh}"}'; exit 0; }
      emit "$out"
    '';
  };
  gitTask = r: lib.nameValuePair "git:recent:${r.name}" {
    description = "Recent commits, dirty tree and unpushed work in ${r.checkout}.";
    exec = ''
      set -uo pipefail
      . ${cfg.lib}
      at=$(now_iso); co=${lib.escapeShellArg r.checkout}
      g() { timeout -k 1 ${toString cfg.timeoutSeconds} git -C "$co" "$@" 2>/dev/null; }
      [ -d "$co/.git" ] || [ -f "$co/.git" ] || { observe_error not_found "no git checkout at $co" '{"task":"git:recent","repo":"${r.name}","checkout":"${r.checkout}"}'; exit 0; }
      head=$(g rev-parse --short HEAD) || { observe_error command_failed "git rev-parse failed in $co" '{"task":"git:recent","repo":"${r.name}","checkout":"${r.checkout}"}'; exit 0; }
      branch=$(g rev-parse --abbrev-ref HEAD || echo HEAD)
      dirty=$(g status --porcelain | grep -c . || true)
      ahead=0; behind=0
      if up=$(g rev-parse --abbrev-ref --symbolic-full-name '@{u}'); then
        read -r behind ahead < <(g rev-list --left-right --count "$up...HEAD" || echo "0 0")
      else up=null; fi
      commits=$(g log --since="${cfg.gitSince}" --format='%h%x1f%cI%x1f%s' -n 20 | jq -Rsc 'split("\n") | map(select(length>0) | split("\u001f") | {sha:.[0], at:.[1], subject:.[2]})')
      unpushed="[]"; [ "$up" != null ] && unpushed=$(g log --format='%h%x1f%s' "$up..HEAD" | jq -Rsc 'split("\n") | map(select(length>0) | split("\u001f") | {sha:.[0], subject:.[1]})')
      emit "$(jq -cn --arg at "$at" --arg head "$head" --arg br "$branch" --argjson dirty "$dirty" --argjson ahead "$ahead" --argjson behind "$behind" --arg up "$up" --argjson c "$commits" --argjson u "$unpushed" \
        '{schema_version:1, task:"git:recent", repo:"${r.name}", checkout:"${r.checkout}", observed_at:$at, error:null,
          head:$head, branch:$br, upstream:(if $up=="null" then null else $up end), dirty_files:$dirty, ahead:$ahead, behind:$behind, unpushed:$u, commits:$c}')"
    '';
  };
  aggregate = name: upstreamPrefix: items: key: {
    description = "Aggregate of ${upstreamPrefix}:<repo> (partial on failures).";
    after = map (n: "${upstreamPrefix}:${n}@completed") items;
    exec = ''
      set -uo pipefail
      . ${cfg.lib}
      at=$(now_iso); out="[]"; failed="[]"
      for name in ${lib.concatStringsSep " " items}; do
        up=$(upstream "${upstreamPrefix}:$name")
        if [ "$up" = null ]; then failed=$(jq -c --arg n "$name" '. + [{repo:$n, error:{kind:"missing", message:"task produced no output"}}]' <<<"$failed")
        elif [ "$(jq -r '.error' <<<"$up")" != null ]; then failed=$(jq -c --argjson u "$up" '. + [{repo:$u.repo, error:$u.error}]' <<<"$failed")
        else out=$(jq -c --argjson u "$up" '. + [$u]' <<<"$out"); fi
      done
      emit "$(jq -cn --arg at "$at" --argjson r "$out" --argjson f "$failed" --argjson total ${toString (lib.length items)} \
        '{schema_version:1, task:"${name}", observed_at:$at, partial:(($f|length) > 0), failed_sources:$f, ${key}:$r}')"
      [ "$(jq -r 'length' <<<"$out")" -gt 0 ] || [ ${toString (lib.length items)} -eq 0 ] || exit 2
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
    "gh:work" = aggregate "gh:work" "gh:work" (map (r: r.name) ghRepos) "repos";
    "git:recent" = aggregate "git:recent" "git:recent" (map (r: r.name) coRepos) "repos";
  };
}
