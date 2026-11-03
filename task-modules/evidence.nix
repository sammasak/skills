# gh:* and git:* tasks: durable engineering evidence on demand, no repo registry: gh:repos discovers the owner's
# repositories, gh:work takes one OWNER/REPO (usually named in an agent's title), git:recent a local checkout path. Observations exit 0
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
      description = "Open issues and recent open/merged PRs of one GitHub repo (bounded by coordinator.ghLimit; truncated:true names the lists that hit it).";
      input = { repo = null; };
      exec = ''
        ${cfg.prelude}
        gh=$(input .repo); ctx=$(jq -cn --arg g "$gh" '{task:"gh:work",repo:$g,gh:$g}')
        [[ "$gh" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail 3 invalid_input "repo must be OWNER/REPO" "$ctx"
        emit "$(gh_work_json "$gh")"
      '';
    };

    "gh:repos" = {
      description = "The owner's repositories by recent push, one GraphQL call: open PR/issue counts and issues carrying an authorizing label (coordinator.authorizingLabels) per repo; archived excluded; capped by limit, at most 100 (truncated says so).";
      input = { owner = cfg.ghOwner; limit = cfg.ghLimit; };
      exec = ''
        ${cfg.prelude}
        owner=$(input .owner); limit=$(input .limit); ctx=$(jq -cn --arg o "$owner" '{task:"gh:repos",owner:$o}')
        [[ "$owner" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}$ ]] || fail 3 invalid_input "owner must be a GitHub login" "$ctx"
        [[ "$limit" =~ ^([1-9][0-9]?|100)$ ]] || fail 3 invalid_input "limit must be 1..100 (GitHub caps a GraphQL page at 100)" "$ctx"
        at=$(now_iso); rc=0; errf=$(mktemp)
        # one query instead of one gh call per repo: counts come from GitHub, nothing is paged or stored here; the
        # authorizing labels are the configured list (coordinator.authorizingLabels), passed as a typed variable
        q='query($owner:String!,$n:Int!,$labels:[String!]!){ repositoryOwner(login:$owner){ repositories(first:$n, orderBy:{field:PUSHED_AT,direction:DESC}, isArchived:false, ownerAffiliations:OWNER){ totalCount nodes{ name pushedAt isArchived isPrivate pullRequests(states:OPEN){totalCount} issues(states:OPEN){totalCount} approved: issues(states:OPEN, labels:$labels){totalCount} } } } }'
        raw=$(timeout -k 1 ${ts} ${cfg.ghCommand} api graphql -f query="$q" -F owner="$owner" -F n="$limit" -f labels=${lib.escapeShellArg (builtins.toJSON cfg.authorizingLabels)} 2>"$errf") || rc=$?
        msg=$(head -c 300 "$errf" | head -n 1 | tr -d '\000-\037'); rm -f "$errf"
        [ "$rc" -eq 0 ] || { observe_error gh_error "gh api graphql exited $rc''${msg:+: $msg}" "$ctx"; exit 0; }
        # archived repos are dropped here too, and the cap is applied here too, so a server that ignored either argument
        # could not widen the list; truncated means the page was full and GitHub counts more
        out=$(jq -cn --argjson c "$ctx" --arg at "$at" --argjson l "$limit" --arg o "$owner" --argjson r "$raw" --argjson labels ${lib.escapeShellArg (builtins.toJSON cfg.authorizingLabels)} '
          ($r.data.repositoryOwner.repositories) as $rs
          | select(($rs|type) == "object" and ($rs.nodes|type) == "array")
          | ($rs.nodes | map(select(type == "object" and (.name|type) == "string" and (.isArchived // false) == false))
             | map({repo:($o + "/" + .name), name, pushed_at:(.pushedAt // ""), private:(.isPrivate // false),
                    open_prs:(.pullRequests.totalCount // 0), open_issues:(.issues.totalCount // 0), approved_issues:(.approved.totalCount // 0)})
             | map(. + {active:(.open_prs > 0 or .approved_issues > 0)}) | sort_by(.pushed_at) | reverse | .[:$l]) as $repos
          | $c + {schema_version:1, observed_at:$at, error:null, limit:$l, authorizing_labels:$labels, total:($rs.totalCount // ($repos|length)), listed:($repos|length),
                  truncated:((($rs.nodes|length) >= $l) and (($rs.totalCount // 0) > $l)), repos:$repos}' 2>/dev/null) || out=""
        [ -n "$out" ] || { observe_error malformed "gh api graphql returned no repository list (GraphQL error or unexpected JSON)" "$ctx"; exit 0; }
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
