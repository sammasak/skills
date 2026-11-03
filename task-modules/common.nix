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
