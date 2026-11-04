# Shared options and shell prelude for every coordinator/quality task (epic #16, herdr-native). Hosts are not
# configured here: the fleet IS herdr's saved machines (`herdr machine list --json`), and remote commands go
# through herdr's own forwarding (`herdr --machine <label> …`). A worker with no saved machines sees only itself.
{ lib, config, ... }:
let
  cfg = config.coordinator;
  t = lib.types;
  home = builtins.getEnv "HOME";
in
{
  options.coordinator = {
    herdrCommand = lib.mkOption { type = t.str; default = "herdr"; description = "Overridable for tests (fake herdr)."; };
    ghCommand = lib.mkOption { type = t.str; default = "gh"; description = "Overridable for tests (fake gh)."; };
    ghLimit = lib.mkOption { type = t.ints.between 1 100; default = 20; description = "Page size for gh list calls and the gh:repos GraphQL query (GitHub caps first at 100)."; };
    ghOwner = lib.mkOption { type = t.str; default = "sammasak"; description = "GitHub login whose repositories gh:repos lists."; };
    # the owner's delegation of approval (skills#28, 2026-11-04): set in the owner's config, never by the role. With it,
    # gh:label may add an authorizing label to an issue of the owner's repos, citing the decision in the audit log
    mayApprove = lib.mkOption { type = t.bool; default = false; description = "Owner delegation: gh:label may add an authorizing label (approved) to the owner's issues; each act cites approvalDecision in audit.jsonl."; };
    approvalDecision = lib.mkOption { type = t.nullOr t.str; default = null; description = "URL of the owner's quoted decision (an issue comment) that mayApprove rests on; required when mayApprove is true."; };
    portfolioActive = lib.mkOption { type = t.ints.positive; default = 5; description = "How many active repos coord:brief expands with gh:work."; };
    # One list for discovery. The send gate (herdr:message) is wider on purpose: it accepts any owner-applied label the
    # coordinator cannot write, so an item authorized by another label is still sendable; gh:repos and the brief only
    # COUNT and LIST issues carrying one of these, and other labels surface through a named repo (gh:work) or a handoff.
    authorizingLabels = lib.mkOption {
      type = t.nonEmptyListOf (t.strMatching "[A-Za-z0-9_:./ -]{1,50}");
      default = [ "approved" ];
      description = "Owner-applied labels that gh:repos counts and coord:brief lists as authorized work.";
    };
    gitSince = lib.mkOption { type = t.str; default = "48 hours ago"; };
    stateDir = lib.mkOption {
      type = t.str;
      default = "${if builtins.getEnv "XDG_STATE_HOME" != "" then builtins.getEnv "XDG_STATE_HOME" else "${home}/.local/state"}/coordinator";
      description = "Drafts, audit log and the latest brief.";
    };
    timeoutSeconds = lib.mkOption { type = t.int; default = 8; description = "Bound for one herdr/gh/git call (remote machines included)."; };
    messageTimeoutSeconds = lib.mkOption { type = t.int; default = 20; description = "Bound for herdr agent prompt (submission incl. bracketed paste)."; };
    claudeProjectsDir = lib.mkOption { type = t.str; default = "$HOME/.claude/projects"; };
    piSessionsDir = lib.mkOption { type = t.str; default = "$HOME/.pi/agent/sessions"; };
    prelude = lib.mkOption { type = t.str; readOnly = true; default = ''
      set -uo pipefail
      # Exit codes (RFC 2026-10-26-agent-roles): 0 result (partial allowed), 2 nothing usable, 3 invalid input.
      now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
      now_epoch() { date -u +%s; }
      valid_id() { [[ "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9_:.@/-]*$ ]]; }
      valid_machine() { [[ "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]]; }
      input() { jq -r "$1 // empty" <<<"''${DEVENV_TASK_INPUT:-{\}}"; }
      emit() { printf '%s\n' "$1" | tee "''${DEVENV_TASK_OUTPUT_FILE:-/dev/null}"; }
      fail() { # <exit> <kind> <message> [extra-json-object]
        emit "$(jq -cn --arg k "$2" --arg m "$3" --argjson x "''${4:-{\}}" '{schema_version:1} + $x + {error:{kind:$k, message:$m}}')"
        exit "$1"
      }
      observe_error() { emit "$(jq -cn --arg k "$1" --arg m "$2" --argjson x "$3" --arg at "$(now_iso)" '{schema_version:1} + $x + {observed_at:$at, error:{kind:$k, message:$m}}')"; }
      rc_kind() { case "$1" in 124) echo timeout ;; *) echo command_failed ;; esac; }
      upstream() { jq -c --arg t "$1" '.[$t] // null' <<<"''${DEVENV_TASKS_OUTPUTS:-{\}}"; }
      local_host() { hostname -s 2>/dev/null || hostname; }
      # herdr_at <timeout_s> <machine-label-or-empty> <herdr args...>: the local server, or herdr's own forwarding to a saved machine
      herdr_at() { local tmo="$1" m="$2"; shift 2
        if [ -z "$m" ]; then timeout -k 1 "$tmo" ${cfg.herdrCommand} "$@"; else timeout -k 1 "$tmo" ${cfg.herdrCommand} --machine "$m" "$@"; fi; }
      # machines_json: {machines:[enabled saved machines], error:null|{kind,message}}; a failing herdr is data, never fatal
      machines_json() { local raw rc=0; raw=$(timeout -k 1 ${toString cfg.timeoutSeconds} ${cfg.herdrCommand} machine list --json 2>/dev/null) || rc=$?
        if [ "$rc" -ne 0 ]; then jq -cn --arg m "herdr machine list: $(rc_kind $rc) (exit $rc)" '{machines:[], error:{kind:"herdr_error", message:$m}}'; return 0; fi
        jq -c 'if type == "array" then {machines: map(select(type == "object" and .enabled == true and (.label|type) == "string")), error:null} else {machines:[], error:{kind:"malformed", message:"herdr machine list returned no JSON array"}} end' <<<"$raw" 2>/dev/null \
          || jq -cn '{machines:[], error:{kind:"malformed", message:"herdr machine list returned no JSON"}}'; }
      # valid_decision <url>: the owner's quoted decision is one issue comment (coordinator.approvalDecision, and what a
      # delegated gh:label act cites in audit.jsonl)
      valid_decision() { [[ "$1" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/issues/[1-9][0-9]*#issuecomment-[1-9][0-9]*$ ]]; }
      # auth_shape <json>: the normalised {issue_url, label, verified:false} of an authorized_by input, or nothing.
      # \z, not $ (jq's $ also matches before a trailing newline).
      auth_shape() { jq -c 'if type == "object" and (.issue_url | type) == "string" and (.issue_url | test("^https://github\\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/(issues|pull)/[1-9][0-9]*\\z"))
          and (.label | type) == "string" and (.label | test("^[A-Za-z0-9_:./ -]{1,50}\\z")) then {issue_url, label, verified:false} else empty end' <<<"$1" 2>/dev/null || true; }
      # gh_authorize <noun> <verb-ing> <item>: the GitHub gate shared by every act that starts work (herdr:message,
      # coord:spawn). The label in $auth must be on the issue now (the issues API serves PR labels too), must be one the
      # coordinator cannot write (gh:label's vocabulary is refused) and must not have been added by a gh:label act in
      # $audit, unless every such act was a delegated approval (an authorizing label added under the owner's delegation,
      # its outcome line citing the decision: owner_delegation); a gh failure is reported, never treated as present. On
      # success $auth gains verified, verified_at, who labelled it when, and applied_by (owner, or coordinator-delegated
      # with the gh:label audit_id); otherwise AUTH_EXIT/AUTH_KIND/AUTH_MSG say why and it returns 1.
      gh_authorize() { local what="$1" doing="$2" item="$3" want_label want_url gh_path gh_repo gh_num errf rc=0 labels gherr events ev added line delegated=true applied_by=owner deleg='null' deleg_aid=null
        AUTH_EXIT=2; AUTH_KIND=""; AUTH_MSG=""
        want_label=$(jq -r .label <<<"$auth"); want_url=$(jq -r .issue_url <<<"$auth")
        case "$want_label" in needs-decision|blocked|needs-live) AUTH_KIND=authorization_missing; AUTH_MSG="label '$want_label' is one the coordinator writes itself (gh:label); it cannot authorize a $what. The owner applies the authorizing label"; return 1 ;; esac
        gh_path=$(jq -r '.issue_url | sub("^https://github\\.com/"; "repos/") | sub("/pull/(?<n>[0-9]+)\\z"; "/issues/\(.n)")' <<<"$auth")
        if ! [[ "$gh_path" =~ ^repos/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/issues/[1-9][0-9]*$ ]] || [[ "$gh_path" == */./* ]] || [[ "$gh_path" == */../* ]]; then
          AUTH_EXIT=3; AUTH_KIND=invalid_input; AUTH_MSG="authorized_by.issue_url does not name OWNER/REPO and an issue or PR number"; return 1; fi
        gh_repo=$(sed -E 's#^repos/([^/]+/[^/]+)/issues/.*#\1#' <<<"$gh_path"); gh_num=$(sed -E 's#.*/issues/([0-9]+)$#\1#' <<<"$gh_path")
        added=""; [ ! -s "$audit" ] || added=$(jq -c --arg r "$gh_repo" --argjson n "$gh_num" --arg l "$want_label" \
            'select(.phase == "gh" and .task == "gh:label" and .action == "add" and .repo == $r and .number == $n and .label == $l and (.stage // "outcome") != "attempt" and (.outcome // "done") != "command_failed" and (.outcome // "done") != "timeout")' "$audit" 2>/dev/null) || added=""
        if [ -n "$added" ]; then
          while IFS= read -r line; do [ -n "$line" ] || continue
            [ "$(jq -r '.owner_delegation.may_approve // false' <<<"$line")" = true ] && valid_decision "$(jq -r '.owner_delegation.decision // ""' <<<"$line")" || delegated=false
          done <<<"$added"
          if [ "$delegated" = true ] && jq -en --arg l "$want_label" --argjson a ${lib.escapeShellArg (builtins.toJSON cfg.authorizingLabels)} '$a | index($l)' >/dev/null; then
            line=$(tail -1 <<<"$added"); applied_by=coordinator-delegated; deleg_aid=$(jq -c .audit_id <<<"$line"); deleg=$(jq -c .owner_delegation <<<"$line")
          else AUTH_KIND=authorization_missing; AUTH_MSG="label '$want_label' on $want_url was added by the coordinator (gh:label, see $audit) without the owner's delegation; it cannot authorize a $what"; return 1; fi
        fi
        errf=$(mktemp); labels=$(timeout -k 1 ${toString cfg.timeoutSeconds} ${cfg.ghCommand} api "$gh_path/labels?per_page=100" 2>"$errf" 9>&-) || rc=$?
        gherr=$(head -c 300 "$errf" | head -n 1 | tr -d '\000-\037'); rm -f "$errf"
        if [ "$rc" -ne 0 ]; then AUTH_KIND=gh_error; AUTH_MSG="could not read the labels of $want_url: gh api exited $rc''${gherr:+: $gherr}; not $doing"; return 1; fi
        if ! jq -e --arg l "$want_label" 'type == "array" and any(.[]; (.name // "") == $l)' <<<"$labels" >/dev/null 2>&1; then
          AUTH_KIND=authorization_missing; AUTH_MSG="label '$want_label' is not on $want_url (present: $(jq -r 'if type == "array" then map(.name // empty) | join(", ") else "unreadable" end' <<<"$labels" 2>/dev/null)); the owner has not authorized this $item, not $doing"; return 1; fi
        # who applied it and when, from the issue's label events (best effort: a missing or paginated-away event is null, not a refusal)
        events=$(timeout -k 1 ${toString cfg.timeoutSeconds} ${cfg.ghCommand} api "$gh_path/events?per_page=100" 2>/dev/null 9>&-) || events="[]"
        ev=$(jq -c --arg l "$want_label" 'if type == "array" then ([.[] | select(.event == "labeled" and (.label.name // "") == $l)] | last // null) else null end | if . == null then {labeled_at:null, labeled_by:null} else {labeled_at:(.created_at // null), labeled_by:(.actor.login // null)} end' <<<"$events" 2>/dev/null) || ev='{"labeled_at":null,"labeled_by":null}'
        auth=$(jq -c --arg at "$(now_iso)" --argjson ev "$ev" --arg ab "$applied_by" --argjson da "$deleg_aid" --argjson d "$deleg" '. + {verified:true, verified_at:$at} + $ev + {applied_by:$ab, delegation_audit_id:$da, owner_delegation:$d}' <<<"$auth"); }
      # gh_work_json <OWNER/REPO>: the gh:work record (open issues, open+merged PRs, truncation) or an error record;
      # never exits, so coord:brief can call it per active repo and gh:work can emit it
      gh_work_json() { local gh="$1" ctx at rc=0 issues open_prs merged_prs prs trunc fields out errf msg
        ctx=$(jq -cn --arg g "$gh" '{task:"gh:work",repo:$g,gh:$g}'); at=$(now_iso); errf=$(mktemp)
        gh_err() { rm -f "$errf"; jq -cn --arg k "$1" --arg m "$2" --argjson x "$ctx" --arg at "$at" '{schema_version:1} + $x + {observed_at:$at, error:{kind:$k, message:$m}}'; }
        gh_msg() { local m; m=$(head -c 300 "$errf" | head -n 1 | tr -d '\000-\037'); printf '%s' "''${m:+: $m}"; }
        issues=$(timeout -k 1 ${toString cfg.timeoutSeconds} ${cfg.ghCommand} issue list -R "$gh" --state open --limit ${toString cfg.ghLimit} --json number,title,state,updatedAt,labels,url 2>"$errf") || { rc=$?; gh_err gh_error "gh issue list exited $rc$(gh_msg)"; return 0; }
        fields=number,title,state,isDraft,reviewDecision,mergedAt,updatedAt,headRefName,url,statusCheckRollup,closingIssuesReferences
        open_prs=$(timeout -k 1 ${toString cfg.timeoutSeconds} ${cfg.ghCommand} pr list -R "$gh" --state open --limit ${toString cfg.ghLimit} --json "$fields" 2>"$errf") || { rc=$?; gh_err gh_error "gh pr list (open) exited $rc$(gh_msg)"; return 0; }
        merged_prs=$(timeout -k 1 ${toString cfg.timeoutSeconds} ${cfg.ghCommand} pr list -R "$gh" --state merged --limit ${toString cfg.ghLimit} --json "$fields" 2>"$errf") || { rc=$?; gh_err gh_error "gh pr list (merged) exited $rc$(gh_msg)"; return 0; }
        rm -f "$errf"
        prs=$(jq -cn --argjson o "$open_prs" --argjson m "$merged_prs" '$o + $m' 2>/dev/null) || { gh_err malformed "gh returned unexpected JSON"; return 0; }
        # gh stops at --limit without saying so; a list that is exactly the limit long may be cut, and the reader must know
        trunc=$(jq -cn --argjson i "$issues" --argjson o "$open_prs" --argjson m "$merged_prs" --argjson l ${toString cfg.ghLimit} \
          '[("issues" | select(($i|length) >= $l)), ("open_prs" | select(($o|length) >= $l)), ("merged_prs" | select(($m|length) >= $l))]' 2>/dev/null) || trunc='[]'
        out=$(jq -cn --arg at "$at" --argjson c "$ctx" --argjson i "$issues" --argjson p "$prs" --argjson no "$(jq 'length' <<<"$open_prs")" --argjson l ${toString cfg.ghLimit} --argjson tl "$trunc" '
          $c + {schema_version:1, observed_at:$at, error:null, open_pr_count:$no, limit:$l, truncated:(($tl|length) > 0), truncated_lists:$tl,
           issues: ($i | map({number, title, state, updated_at:.updatedAt, labels:((.labels // []) | map(.name)), url})),
           prs: ($p | map({number, title, state, draft:.isDraft, review_decision:(.reviewDecision // ""), merged_at:.mergedAt, updated_at:.updatedAt,
                          branch:.headRefName, url, checks:((.statusCheckRollup // []) | map((.conclusion | select(. != null and . != "")) // .state // "PENDING")),
                          closes:((.closingIssuesReferences // []) | map(.number))}))}' 2>/dev/null) || { gh_err malformed "gh returned unexpected JSON"; return 0; }
        printf '%s\n' "$out"; }
    ''; };
  };
}
