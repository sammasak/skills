# Quality role tasks: read a fleet checkout's platform.sdlc state (quality:report)
# and run one of its stages (quality:gate). Both delegate to the checkout's own
# devenv; the machine, stamps and verdicts stay devenv-platform's.
{ lib, config, ... }:

let
  cfg = config.coordinator;
  t = lib.types;
  checkouts = map (r: r.checkout) (lib.filter (r: r.checkout != null) cfg.repos);
  # resolve $checkout against the fleet or fail; $repo gets the fleet name
  checkoutCase = ''
    repo=""
    case "$checkout" in
      ${lib.concatMapStringsSep "\n      " (r: ''${r.checkout}) repo="${r.name}" ;;'') (lib.filter (r: r.checkout != null) cfg.repos)}
      *) fail 3 invalid_input "checkout is not a fleet repo: $checkout" "$ctx" ;;
    esac
  '';
in
{
  imports = [ ../../task-modules/fleet.nix ];

  options.coordinator.devenvCommand = lib.mkOption { type = t.str; default = "devenv"; description = "Overridable for tests (fake devenv)."; };
  options.coordinator.gateTimeoutSeconds = lib.mkOption { type = t.int; default = 1800; };

  config.tasks = {
    "quality:report" = {
      description = "SDLC machine + durable stage state of one fleet checkout (read-only; sdlc-status is the authority).";
      input = { checkout = null; };
      exec = ''
        ${cfg.prelude}
        checkout=$(input .checkout)
        ctx=$(jq -cn --arg c "$checkout" '{task:"quality:report",checkout:$c}')
        [ -n "$checkout" ] || fail 3 invalid_input "checkout is required" "$ctx"
        ${checkoutCase}
        ctx=$(jq -cn --arg c "$checkout" --arg r "$repo" '{task:"quality:report",checkout:$c,repo:$r}')
        [ -d "$checkout" ] || fail 2 not_found "checkout does not exist: $checkout" "$ctx"
        at=$(now_iso)
        head=$(timeout -k 1 ${toString cfg.timeoutSeconds} git -C "$checkout" rev-parse --short HEAD 2>/dev/null) || head=null
        dirty=$(timeout -k 1 ${toString cfg.timeoutSeconds} git -C "$checkout" status --porcelain 2>/dev/null | grep -c . || true)
        rc=0
        machine=$(cd "$checkout" && timeout -k 1 ${toString cfg.timeoutSeconds} ${cfg.devenvCommand} shell -q -- sh -c 'cat "$SDLC_MACHINE"' 2>/dev/null) || rc=$?
        [ "$rc" -eq 0 ] && jq -e '.schemaVersion == 1 and (.order | type == "array")' <<<"$machine" >/dev/null 2>&1 \
          || fail 2 no_sdlc "the checkout's devenv exposes no platform.sdlc machine (exit $rc)" "$ctx"
        rc=0
        status=$(cd "$checkout" && timeout -k 1 ${toString cfg.timeoutSeconds} ${cfg.devenvCommand} shell -q -- sdlc-status --context 2>/dev/null) || rc=$?
        [ "$rc" -eq 0 ] || fail 2 command_failed "sdlc-status --context exited $rc" "$ctx"
        state="$checkout/.devenv/state/sdlc"
        reds="[]"; verdicts="[]"
        if [ -d "$state" ]; then
          # devenv runs execs with errexit: an unmatched glob must not end the loop with a failing status
          reds=$(for f in "$state"/last-red-*.json; do [ -f "$f" ] || continue; jq -c '{stage, guard, at, fingerprint, tail: (.tail // "" | .[-1200:])}' "$f" 2>/dev/null || true; done | jq -sc '.')
          verdicts=$(for f in "$state"/verdict-*.json; do [ -f "$f" ] || continue; jq -c --arg n "$(basename "$f" .json)" '{stage: ($n | ltrimstr("verdict-")), grade, fingerprint}' "$f" 2>/dev/null || true; done | jq -sc '.')
        fi
        # stage state from sdlc-status's own context lines: "<stage>: <state>" (fresh|stale|red|unverified|...)
        stages=$(jq -cn --argjson m "$machine" --arg s "$status" '
          ($s | split("\n") | map(capture("^\\s*(?<stage>[a-z][a-z0-9-]*)\\s*[:=]\\s*(?<state>fresh|stale|red|unverified|green|skipped|pending)\\b")?) | map(select(. != null)) | map({key:.stage, value:.state}) | from_entries) as $st
          | [$m.order[] | {stage:., guards:($m.stages[.].guards // []), verdict:($m.stages[.].verdict // false), state:($st[.] // "unknown")}]')
        emit "$(jq -cn --arg at "$at" --argjson c "$ctx" --arg head "$head" --argjson dirty "$dirty" --argjson m "$machine" --argjson st "$stages" --arg txt "$status" --argjson reds "$reds" --argjson v "$verdicts" \
          '{schema_version:1} + $c + {observed_at:$at, error:null, head:(if $head=="null" then null else $head end), dirty_files:$dirty,
                 machine:{name:$m.name, bar:$m.bar, order:$m.order, terminal:$m.terminal}, stages:$st, status_context:($txt | .[0:4000]), red:$reds, verdicts:$v,
                 all_fresh:([$st[] | .state] | all(. == "fresh")), note:"states come from sdlc-status; exit codes of this task are never a verdict"}')"
      '';
    };

    "quality:gate" = {
      description = "RUN: execute one SDLC stage (devenv tasks run sdlc:<stage>) in a fleet checkout and record exit + output tail.";
      input = { checkout = null; stage = null; };
      exec = ''
        ${cfg.prelude}
        checkout=$(input .checkout); stage=$(input .stage)
        ctx=$(jq -cn --arg c "$checkout" --arg s "$stage" '{task:"quality:gate",checkout:$c,stage:$s}')
        [ -n "$checkout" ] && [ -n "$stage" ] || fail 3 invalid_input "checkout and stage are required" "$ctx"
        [[ "$stage" =~ ^[a-z][a-z0-9-]{0,40}$ ]] || fail 3 invalid_input "stage must be a short lowercase name" "$ctx"
        ${checkoutCase}
        [ -d "$checkout" ] || fail 2 not_found "checkout does not exist: $checkout" "$ctx"
        at=$(now_iso); log=$(mktemp); rc=0
        head=$(timeout -k 1 ${toString cfg.timeoutSeconds} git -C "$checkout" rev-parse --short HEAD 2>/dev/null) || head=null
        (cd "$checkout" && timeout -k 5 ${toString cfg.gateTimeoutSeconds} ${cfg.devenvCommand} tasks run "sdlc:$stage" --show-output) >"$log" 2>&1 || rc=$?
        tail_txt=$(tail -n 40 "$log" | LC_ALL=C cut -c1-400); rm -f "$log"
        kind=null; [ "$rc" -eq 0 ] || { [ "$rc" -eq 124 ] && kind='{"kind":"timeout","message":"stage did not finish within ${toString cfg.gateTimeoutSeconds}s"}' || kind='{"kind":"stage_red","message":"devenv tasks run sdlc:'"$stage"' exited '"$rc"'"}'; }
        emit "$(jq -cn --arg at "$at" --argjson c "$ctx" --arg head "$head" --argjson rc "$rc" --arg tail "$tail_txt" --argjson e "$kind" \
          '{schema_version:1} + $c + {started_at:$at, head:(if $head=="null" then null else $head end), exit:$rc, green:($rc == 0), output_tail:$tail, error:$e}')"
        [ "$rc" -eq 0 ] || exit 2
      '';
    };
  };
}
