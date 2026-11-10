# gh:* act tasks: the coordinator's only writes to GitHub. Each one is bounded to a single issue or PR, carries the
# handoff it serves (or a reason), and appends two lines (attempt, then outcome) to the same audit.jsonl herdr:message
# writes. The label vocabulary deliberately excludes the labels that authorize a send (see herdr:message): the
# coordinator must not be able to label an issue into authorizing its own handoff. The one exception is the owner's
# delegation (coordinator.mayApprove, skills#28): an authorizing label on an issue of the owner's repos, never a PR,
# never over an owner hold, each act citing the owner's decision so the send gate can tell it from self-authorization.
{ lib, config, ... }:
let
  cfg = config.coordinator;
  t = toString cfg.timeoutSeconds;
  # shared by every gh act task: target checks, the handoff-or-reason rule, one audit line under the audit lock; gh:issue
  # creates the issue, so it has no number yet
  ghPreludeFor = withNumber: ''
    ${cfg.prelude}
    repo=$(input .repo); num=$(input .number); hid=$(input .handoff_id); reason=$(input .reason)
    [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail 3 invalid_input "repo must be OWNER/REPO" "$ctx"
    case "$repo" in ./*|../*|*/.|*/..) fail 3 invalid_input "repo segments may not be . or .." "$ctx" ;; esac
    ${if withNumber then ''
    [[ "$num" =~ ^[1-9][0-9]{0,8}$ ]] || fail 3 invalid_input "number must be the issue or PR number" "$ctx"
    ctx=$(jq -c --arg r "$repo" --argjson n "$num" '. + {repo:$r, number:$n}' <<<"$ctx")'' else ''
    [ -z "$num" ] || fail 3 invalid_input "number is not an input here (the issue does not exist yet)" "$ctx"
    ctx=$(jq -c --arg r "$repo" '. + {repo:$r}' <<<"$ctx")''}
    # exactly one of handoff_id (an existing coord:handoff draft) or reason (free text, bounded) says why
    if [ -n "$hid" ] && [ -n "$reason" ]; then fail 3 invalid_input "give handoff_id or reason, not both" "$ctx"; fi
    if [ -n "$hid" ]; then
      [[ "$hid" =~ ^[a-f0-9]{12}$ ]] || fail 3 invalid_input "handoff_id must be a 12-hex coord:handoff id" "$ctx"
      [ -r "${cfg.stateDir}/handoffs/$hid.json" ] || fail 3 invalid_input "no draft with handoff_id $hid (run coord:handoff first)" "$ctx"
    elif [ -n "$reason" ]; then
      [ "''${#reason}" -le 4000 ] || fail 3 invalid_input "reason exceeds 4000 characters" "$ctx"
    else fail 3 invalid_input "handoff_id (the draft this serves) or reason is required" "$ctx"; fi
    audit="${cfg.stateDir}/audit.jsonl"; mkdir -p "${cfg.stateDir}"; touch "$audit"
    exec 9>"$audit.lock"; flock -w 10 9 || fail 2 busy "another act task holds the audit lock" "$ctx"
    [ ! -s "$audit" ] || jq -n -e 'all(inputs; type == "object" and (.audit_id|type) == "string" and (.phase|type) == "string")' "$audit" >/dev/null 2>&1 \
      || fail 2 audit_corrupt "audit log is not valid JSON lines; refusing to act until the owner inspects $audit" "$ctx"
    aid=$(printf '%s|%s|%s' "$ctx" "$(now_iso)" "$RANDOM$RANDOM" | sha256sum | cut -c1-12); at=$(now_iso)
    why=$(jq -cn --arg h "$hid" --arg r "$reason" '{handoff_id:(if $h == "" then null else $h end), reason:(if $r == "" then null else $r end)}')
    # attempt line before the GitHub write, outcome line after (from the EXIT trap, so a kill mid-write still leaves
    # "interrupted"): a label or comment never exists on GitHub without a trace here
    attempt() { # <extra-json>: what is about to be written
      jq -cn --arg a "$aid" --arg at "$at" --argjson c "$ctx" --argjson w "$why" --argjson x "$1" \
        '{audit_id:$a, phase:"gh", stage:"attempt"} + $c + $w + {at:$at} + $x' >> "$audit" || fail 2 audit_failed "could not write the attempt line; nothing was sent to GitHub" "$ctx"
      outcome=interrupted; extra='{}'
      trap 'jq -cn --arg a "$aid" --arg i "$(now_iso)" --arg o "$outcome" --argjson c "$ctx" --argjson x "$extra" "{audit_id:\$a, phase:\"gh\", stage:\"outcome\"} + \$c + {at:\$i, outcome:\$o} + \$x" >> "$audit"' EXIT; }
    record() { # <outcome> <extra-json>: the outcome line is written by the trap; the record repeats it
      outcome="$1"; extra=$(jq -c 'del(.message)' <<<"$2")
      emit "$(jq -cn --arg a "$aid" --arg at "$at" --argjson c "$ctx" --argjson w "$why" --arg o "$1" --argjson x "$2" \
        '{schema_version:1} + $c + {audit_id:$a} + $w + {at:$at, outcome:$o} + ($x | del(.message)) + {error:(if $o == "done" then null else {kind:$o, message:($x.message // "gh failed")} end)}')"
      [ "$1" = done ] || exit 2; }
    # refused-row instrumentation (#85 M0b): a gh act refused before it reaches GitHub (no attempt line) leaves a
    # phase:"refused" row for coord:report, under the audit lock this prelude already holds. Evidence refs only (the
    # ctx: task, repo, number, label, action; the handoff id or reason) -- never a body, scope or command. Bounded kinds.
    refuse() { # <exit> <kind> <message>
      # #85 M0b finding A (privacy): the refused row carries refs only -- the ctx (task, repo, number, label, action),
      # the handoff id, and reason_chars (a count, like body_chars), never the caller's free-text reason, which can
      # carry names, paths or scope text.
      case " invalid_input owner_hold " in *" $2 "*)
        jq -cn --arg a "$aid" --arg at "$(now_iso)" --argjson c "$ctx" --argjson w "$why" --arg k "$2" \
          '{audit_id:$a, phase:"refused"} + $c + {handoff_id:$w.handoff_id, reason_chars:($w.reason | if . == null then null else length end)} + {at:$at, kind:$k}' >> "$audit" || true ;;
      esac
      fail "$1" "$2" "$3" "$ctx"; }
  '';
  ghPrelude = ghPreludeFor true;
  # labels a new issue may carry: the owner-protocol ones and enhancement, never one that authorizes a send
  issueLabels = [ "enhancement" "needs-decision" "blocked" "needs-live" ];
in
{
  imports = [ ./common.nix ];

  tasks = {
    "gh:label" = {
      description = "ACT: add or remove one owner-protocol label (needs-decision, blocked, needs-live) on OWNER/REPO#N; audited with the handoff or reason. Removing a hold needs evidence (the resolving PR or commit URL) and an earlier gh:label add of that label in the audit: an owner-applied hold is the owner's to lift. An authorizing label (approved) only under the owner's delegation (coordinator.mayApprove): added to an issue of the owner's repos that carries no owner hold, never a PR, citing coordinator.approvalDecision in the audit lines.";
      input = { repo = null; number = null; label = null; action = null; handoff_id = null; reason = null; evidence = null; };
      exec = ''
        ctx='{"task":"gh:label"}'
        ${ghPrelude}
        label=$(input .label); action=$(input .action)
        case "$action" in add|remove) ;; *) fail 3 invalid_input "action must be add or remove" "$ctx" ;; esac
        ctx=$(jq -c --arg l "$label" --arg a "$action" '. + {label:$l, action:$a}' <<<"$ctx")
        delegation='{}'
        if jq -en --arg l "$label" --argjson a ${lib.escapeShellArg (builtins.toJSON cfg.authorizingLabels)} '$a | index($l)' >/dev/null; then
          # an authorizing label: only as the owner's delegate, on an issue the owner has not put on hold
          ${if cfg.mayApprove then "true" else "false"} || fail 3 not_delegated "label '$label' authorizes a send; the owner has not delegated approval (coordinator.mayApprove is off)" "$ctx"
          decision=${lib.escapeShellArg (if cfg.approvalDecision == null then "" else cfg.approvalDecision)}
          valid_decision "$decision" || fail 3 not_delegated "coordinator.mayApprove is on but coordinator.approvalDecision is not the URL of the owner's decision comment (https://github.com/OWNER/REPO/issues/N#issuecomment-ID)" "$ctx"
          [ "''${repo%%/*}" = ${lib.escapeShellArg cfg.ghOwner} ] || fail 3 not_delegated "delegated approval covers ${cfg.ghOwner}'s repositories only, not $repo" "$ctx"
          [ "$action" = add ] || fail 3 invalid_input "label '$label' can only be added under delegation; withdrawing an approval is the owner's" "$ctx"
          errf=$(mktemp); rc=0; issue=$(timeout -k 1 ${t} ${cfg.ghCommand} api "repos/$repo/issues/$num" 2>"$errf" 9>&-) || rc=$?
          msg=$(head -c 300 "$errf" | head -n 1 | tr -d '\000-\037'); rm -f "$errf"
          [ "$rc" -eq 0 ] || fail 2 "$(rc_kind $rc)" "could not read $repo#$num before approving: gh api exited $rc''${msg:+: $msg}" "$ctx"
          jq -e 'type == "object" and (has("pull_request") | not)' <<<"$issue" >/dev/null 2>&1 || fail 3 invalid_input "$repo#$num is a pull request (or unreadable); delegated approval covers issues only" "$ctx"
          hold=$(jq -r '[.labels[]? | .name // empty | select(. == "needs-live" or . == "blocked" or . == "needs-decision")] | first // empty' <<<"$issue")
          [ -z "$hold" ] || fail 3 owner_hold "$repo#$num carries $hold, an owner hold; not approving" "$ctx"
          [ "$(jq -r '.state // ""' <<<"$issue")" = open ] || fail 3 invalid_input "$repo#$num is not open; not approving" "$ctx"
          # public repositories accept issues from anyone: only the owner's own issues (every agent posts as the owner) may be approved
          author=$(jq -r '.user.login // ""' <<<"$issue")
          [ "$author" = ${lib.escapeShellArg cfg.ghOwner} ] || fail 3 not_delegated "$repo#$num is not the owner's issue (written by ''${author:-?}); delegated approval covers the owner's own issues only" "$ctx"
          delegation=$(jq -cn --arg d "$decision" --arg a "$author" '{owner_delegation:{may_approve:true, decision:$d, author:$a}}')
        else
          case "$label" in needs-decision|blocked|needs-live) ;; *) fail 3 invalid_input "label must be one of needs-decision, blocked, needs-live (an authorizing label only under the owner's delegation, coordinator.mayApprove)" "$ctx" ;; esac
          if [ "$action" = remove ]; then
            # skills#28: the coordinator lifts only a hold it put there itself -- an add the audit records with both its attempt
            # and a done outcome line -- and only citing what resolved it; an owner-applied hold stays the owner's to lift
            evidence=$(input .evidence)
            [[ "$evidence" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/(pull/[1-9][0-9]*|commit/[0-9a-f]{7,40})$ ]] \
              || refuse 3 invalid_input "removing '$label' from $repo#$num needs evidence: the URL of the PR or commit that resolved it (https://github.com/OWNER/REPO/pull/N or .../commit/SHA)"
            mine=$(jq -sc --arg r "$repo" --argjson n "$num" --arg l "$label" '
              [.[] | select(.phase == "gh" and .task == "gh:label" and .action == "add" and .repo == $r and .number == $n and .label == $l)]
              | group_by(.audit_id) | map(select(any(.[]; .stage == "attempt") and any(.[]; .stage == "outcome" and .outcome == "done"))) | length' "$audit" 2>/dev/null) || mine=0
            [ "''${mine:-0}" -gt 0 ] || refuse 3 owner_hold "'$label' on $repo#$num was not added by the coordinator (no gh:label add with a done outcome in $audit); it is the owner's hold. Required: the owner removes '$label' from $repo#$num"
            delegation=$(jq -cn --arg e "$evidence" '{evidence:$e}')
          fi
        fi
        attempt "$delegation"
        errf=$(mktemp); rc=0
        # the issues API serves PRs too, so one path covers both
        if [ "$action" = add ]; then
          jq -cn --arg l "$label" '{labels:[$l]}' | timeout -k 1 ${t} ${cfg.ghCommand} api -X POST "repos/$repo/issues/$num/labels" --input - >/dev/null 2>"$errf" 9>&- || rc=$?
        else
          timeout -k 1 ${t} ${cfg.ghCommand} api -X DELETE "repos/$repo/issues/$num/labels/$label" >/dev/null 2>"$errf" 9>&- || rc=$?
        fi
        msg=$(head -c 300 "$errf" | head -n 1 | tr -d '\000-\037'); rm -f "$errf"
        [ "$rc" -eq 0 ] && record done "$delegation" || record "$(rc_kind $rc)" "$(jq -cn --arg m "gh api exited $rc''${msg:+: $msg}" --argjson d "$delegation" '{message:$m} + $d')"
      '';
    };

    "gh:comment" = {
      description = "ACT: post one bounded comment (max 4000 characters) on OWNER/REPO#N, signed Coordinator; audited with the handoff or reason.";
      input = { repo = null; number = null; body = null; handoff_id = null; reason = null; };
      exec = ''
        ctx='{"task":"gh:comment"}'
        ${ghPrelude}
        body=$(input .body)
        [ -n "$body" ] || fail 3 invalid_input "body is required" "$ctx"
        [ "''${#body}" -le 4000 ] || fail 3 invalid_input "body exceeds 4000 characters" "$ctx"
        # the comment is the coordinator's, never the owner's: any trailing "-- Coordinator" line the caller wrote is
        # replaced by the one canonical signature, so every comment ends the same way exactly once
        body=$(jq -rn --arg b "$body" '$b | sub("(\\s*\n-- Coordinator[^\n]*)*\\s*\\z"; "") + "\n\n-- Coordinator (automated; not the owner)"')
        attempt "$(jq -cn --argjson n "''${#body}" '{body_chars:$n}')"
        errf=$(mktemp); rc=0
        res=$(jq -cn --arg b "$body" '{body:$b}' | timeout -k 1 ${t} ${cfg.ghCommand} api -X POST "repos/$repo/issues/$num/comments" --input - 2>"$errf" 9>&-) || rc=$?
        msg=$(head -c 300 "$errf" | head -n 1 | tr -d '\000-\037'); rm -f "$errf"
        url=$(jq -r '.html_url // empty' <<<"$res" 2>/dev/null || true)
        if [ "$rc" -eq 0 ] && [ -n "$url" ]; then record done "$(jq -cn --arg u "$url" --argjson n "''${#body}" '{comment_url:$u, body_chars:$n}')"
        elif [ "$rc" -eq 0 ]; then record malformed '{"message":"gh api returned no html_url; the comment may or may not exist, check the issue"}'
        else record "$(rc_kind $rc)" "$(jq -cn --arg m "gh api exited $rc''${msg:+: $msg}" '{message:$m}')"; fi
      '';
    };

    "gh:issue" = {
      description = "ACT: create one issue in one of ${cfg.ghOwner}'s repositories (title one line, max 256; body max 8000, signed Coordinator; labels only ${lib.concatStringsSep ", " issueLabels}, never an authorizing label); refused when an open issue has the same title; audited with the handoff or reason.";
      input = { repo = null; title = null; body = null; labels = null; handoff_id = null; reason = null; };
      exec = ''
        ctx='{"task":"gh:issue"}'
        ${ghPreludeFor false}
        [ "''${repo%%/*}" = ${lib.escapeShellArg cfg.ghOwner} ] || fail 3 invalid_input "gh:issue creates issues in ${cfg.ghOwner}'s repositories only, not $repo" "$ctx"
        title=$(input .title); body=$(input .body)
        [ -n "$title" ] || fail 3 invalid_input "title is required" "$ctx"
        [ "''${#title}" -le 256 ] || fail 3 invalid_input "title exceeds 256 characters" "$ctx"
        ! [[ "$title" =~ [[:cntrl:]] ]] || fail 3 invalid_input "title must be one line without control characters" "$ctx"
        [ -n "$body" ] || fail 3 invalid_input "body is required" "$ctx"
        [ "''${#body}" -le 8000 ] || fail 3 invalid_input "body exceeds 8000 characters" "$ctx"
        labels=$(jq -c '.labels // []' <<<"''${DEVENV_TASK_INPUT:-{\}}")
        jq -e 'type == "array" and length <= 4 and all(.[]; type == "string") and (unique | length) == length' <<<"$labels" >/dev/null 2>&1 \
          || fail 3 invalid_input "labels must be a list of at most 4 distinct names" "$ctx"
        jq -e --argjson a ${lib.escapeShellArg (builtins.toJSON cfg.authorizingLabels)} 'any(.[]; . as $l | $a | index($l))' <<<"$labels" >/dev/null \
          && fail 3 invalid_input "a new issue never carries a label that authorizes a send ($(jq -r --argjson a ${lib.escapeShellArg (builtins.toJSON cfg.authorizingLabels)} '[.[] | select(. as $l | $a | index($l))] | join(", ")' <<<"$labels")); approval is gh:label's, under the owner's delegation" "$ctx"
        jq -e --argjson ok ${lib.escapeShellArg (builtins.toJSON issueLabels)} 'all(.[]; . as $l | $ok | index($l))' <<<"$labels" >/dev/null \
          || fail 3 invalid_input "labels must be among ${lib.concatStringsSep ", " issueLabels}" "$ctx"
        ctx=$(jq -c --arg t "$title" '. + {title:$t}' <<<"$ctx")
        # one issue per call and per title: a retry after an ambiguous outcome must not open a second one
        errf=$(mktemp); rc=0
        open=$(timeout -k 1 ${t} ${cfg.ghCommand} api "repos/$repo/issues?state=open&per_page=100" 2>"$errf" 9>&-) || rc=$?
        msg=$(head -c 300 "$errf" | head -n 1 | tr -d '\000-\037'); rm -f "$errf"
        [ "$rc" -eq 0 ] || fail 2 "$(rc_kind $rc)" "could not list the open issues of $repo before creating one: gh api exited $rc''${msg:+: $msg}" "$ctx"
        dup=$(jq -r --arg t "$title" 'if type == "array" then [.[] | select((has("pull_request") | not) and .title == $t) | .number] | first // empty else "unreadable" end' <<<"$open" 2>/dev/null || echo unreadable)
        [ "$dup" != unreadable ] || fail 2 malformed "the open-issue list of $repo was not a JSON array; not creating" "$ctx"
        [ -z "$dup" ] || fail 3 duplicate "$repo#$dup is open with the same title; not creating a second one" "$ctx"
        body=$(jq -rn --arg b "$body" '$b | sub("(\\s*\n-- Coordinator[^\n]*)*\\s*\\z"; "") + "\n\n-- Coordinator (automated; not the owner)"')
        attempt "$(jq -cn --argjson l "$labels" --argjson n "''${#body}" '{labels:$l, body_chars:$n}')"
        errf=$(mktemp); rc=0
        res=$(jq -cn --arg t "$title" --arg b "$body" --argjson l "$labels" '{title:$t, body:$b, labels:$l}' | timeout -k 1 ${t} ${cfg.ghCommand} api -X POST "repos/$repo/issues" --input - 2>"$errf" 9>&-) || rc=$?
        msg=$(head -c 300 "$errf" | head -n 1 | tr -d '\000-\037'); rm -f "$errf"
        url=$(jq -r '.html_url // empty' <<<"$res" 2>/dev/null || true); number=$(jq -r '.number // empty' <<<"$res" 2>/dev/null || true)
        if [ "$rc" -eq 0 ] && [ -n "$url" ] && [[ "$number" =~ ^[0-9]+$ ]]; then record done "$(jq -cn --arg u "$url" --argjson n "$number" --argjson l "$labels" '{issue_url:$u, number:$n, labels:$l}')"
        elif [ "$rc" -eq 0 ]; then record malformed '{"message":"gh api returned no html_url or number; the issue may or may not exist, check the repository"}'
        else record "$(rc_kind $rc)" "$(jq -cn --arg m "gh api exited $rc''${msg:+: $msg}" '{message:$m}')"; fi
      '';
    };
  };
}
