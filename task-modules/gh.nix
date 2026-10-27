# gh:* act tasks: the coordinator's only writes to GitHub. Each one is bounded to a single issue or PR, carries the
# handoff it serves (or a reason), and appends one line to the same audit.jsonl herdr:message writes.
{ lib, config, ... }:
let
  cfg = config.coordinator;
  t = toString cfg.timeoutSeconds;
  # shared by both tasks: target checks, the handoff-or-reason rule, one audit line under the audit lock
  ghPrelude = ''
    ${cfg.prelude}
    repo=$(input .repo); num=$(input .number); hid=$(input .handoff_id); reason=$(input .reason)
    [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail 3 invalid_input "repo must be OWNER/REPO" "$ctx"
    [[ "$num" =~ ^[1-9][0-9]{0,8}$ ]] || fail 3 invalid_input "number must be the issue or PR number" "$ctx"
    ctx=$(jq -c --arg r "$repo" --argjson n "$num" '. + {repo:$r, number:$n}' <<<"$ctx")
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
    # <outcome> <extra-json>: the audit line is written whatever gh did; the record repeats it
    record() { jq -cn --arg a "$aid" --arg at "$at" --argjson c "$ctx" --argjson w "$why" --arg o "$1" --argjson x "$2" \
        '{audit_id:$a, phase:"gh"} + $c + $w + {at:$at, outcome:$o} + $x' >> "$audit" || fail 2 audit_failed "could not write the audit line" "$ctx"
      emit "$(jq -cn --arg a "$aid" --arg at "$at" --argjson c "$ctx" --argjson w "$why" --arg o "$1" --argjson x "$2" \
        '{schema_version:1} + $c + {audit_id:$a} + $w + {at:$at, outcome:$o} + ($x | del(.message)) + {error:(if $o == "done" then null else {kind:$o, message:($x.message // "gh failed")} end)}')"
      [ "$1" = done ] || exit 2; }
  '';
in
{
  imports = [ ./common.nix ];

  tasks = {
    "gh:label" = {
      description = "ACT: add or remove one owner-protocol label (needs-decision, blocked, needs-live, approved) on OWNER/REPO#N; audited with the handoff or reason.";
      input = { repo = null; number = null; label = null; action = null; handoff_id = null; reason = null; };
      exec = ''
        ctx='{"task":"gh:label"}'
        ${ghPrelude}
        label=$(input .label); action=$(input .action)
        case "$label" in needs-decision|blocked|needs-live|approved) ;; *) fail 3 invalid_input "label must be one of needs-decision, blocked, needs-live, approved" "$ctx" ;; esac
        case "$action" in add|remove) ;; *) fail 3 invalid_input "action must be add or remove" "$ctx" ;; esac
        ctx=$(jq -c --arg l "$label" --arg a "$action" '. + {label:$l, action:$a}' <<<"$ctx")
        errf=$(mktemp); rc=0
        # the issues API serves PRs too, so one path covers both
        if [ "$action" = add ]; then
          jq -cn --arg l "$label" '{labels:[$l]}' | timeout -k 1 ${t} ${cfg.ghCommand} api -X POST "repos/$repo/issues/$num/labels" --input - >/dev/null 2>"$errf" 9>&- || rc=$?
        else
          timeout -k 1 ${t} ${cfg.ghCommand} api -X DELETE "repos/$repo/issues/$num/labels/$label" >/dev/null 2>"$errf" 9>&- || rc=$?
        fi
        msg=$(head -c 300 "$errf" | head -n 1 | tr -d '\000-\037'); rm -f "$errf"
        [ "$rc" -eq 0 ] && record done '{}' || record "$(rc_kind $rc)" "$(jq -cn --arg m "gh api exited $rc''${msg:+: $msg}" '{message:$m}')"
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
        # the comment is the coordinator's, never the owner's: signed as such, and a body already signed is not re-signed
        case "$body" in *"-- Coordinator") ;; *) body="$body"$'\n\n-- Coordinator (automated; not the owner)' ;; esac
        errf=$(mktemp); rc=0
        res=$(jq -cn --arg b "$body" '{body:$b}' | timeout -k 1 ${t} ${cfg.ghCommand} api -X POST "repos/$repo/issues/$num/comments" --input - 2>"$errf" 9>&-) || rc=$?
        msg=$(head -c 300 "$errf" | head -n 1 | tr -d '\000-\037'); rm -f "$errf"
        url=$(jq -r '.html_url // empty' <<<"$res" 2>/dev/null || true)
        if [ "$rc" -eq 0 ] && [ -n "$url" ]; then record done "$(jq -cn --arg u "$url" --argjson n "''${#body}" '{comment_url:$u, body_chars:$n}')"
        elif [ "$rc" -eq 0 ]; then record malformed '{"message":"gh api returned no html_url; the comment may or may not exist, check the issue"}'
        else record "$(rc_kind $rc)" "$(jq -cn --arg m "gh api exited $rc''${msg:+: $msg}" '{message:$m}')"; fi
      '';
    };
  };
}
