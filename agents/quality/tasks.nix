# Quality role tasks: read a fleet checkout's platform.sdlc state (quality:report)
# and run one of its stages (quality:gate). Both delegate to the checkout's own
# devenv; the machine, stamps and verdicts stay devenv-platform's.
{ lib, config, ... }:

let
  cfg = config.coordinator;
  t = lib.types;
  checkouts = map (r: r.checkout) (lib.filter (r: r.checkout != null) cfg.repos);
  # the consumer's devenv sees a clean environment: an allowlist of host variables (only those that are set),
  # a system-only PATH, and nothing from the outer skills shell
  consumerEnv = ''
    cenv=(HOME="$HOME" TERM="''${TERM:-dumb}" LANG="''${LANG:-C.UTF-8}" PATH="/run/current-system/sw/bin:/etc/profiles/per-user/''${USER:-nobody}/bin:$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:/usr/bin:/bin")
    for v in USER LOGNAME TZ NIX_PATH NIX_SSL_CERT_FILE SSL_CERT_FILE XDG_CONFIG_HOME XDG_CACHE_HOME XDG_DATA_HOME XDG_STATE_HOME ${cfg.consumerEnvPassthrough}; do
      [ -n "''${!v+x}" ] && cenv+=("$v=''${!v}")
    done
  '';
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
  options.coordinator.consumerEnvPassthrough = lib.mkOption { type = t.str; default = ""; description = "Extra variable names forwarded to the consumer's devenv (tests use it for FAKE_*)."; };
  options.coordinator.consumerTimeoutSeconds = lib.mkOption { type = t.int; default = 180; description = "Bound for evaluating the consumer's devenv shell (cold evals of Rust consumers take a while)."; };
  # below Claude's longest Bash tool timeout (600s) so a gate call can always report
  options.coordinator.gateTimeoutSeconds = lib.mkOption { type = t.int; default = 540; };

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
        if porcelain=$(timeout -k 1 ${toString cfg.timeoutSeconds} git -C "$checkout" status --porcelain 2>/dev/null); then dirty=$(grep -c . <<<"$porcelain" || true); else dirty=null; fi
        # one consumer shell: machine, digest and fingerprint to files (stdout of enterShell cannot corrupt them);
        # the outer task's DEVENV_*/SDLC_* environment is scrubbed so the consumer's devenv sees only its own
        work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
        devenv_bin=$(command -v ${cfg.devenvCommand}) || fail 2 command_failed "devenv not on PATH" "$ctx"
        rc=0
        ${consumerEnv}
        (cd "$checkout" && timeout -k 1 ${toString cfg.consumerTimeoutSeconds} env -i "''${cenv[@]}" \
            "$devenv_bin" shell -q -- sh -c '[ -n "''${SDLC_MACHINE:-}" ] || exit 42; cat "$SDLC_MACHINE" > "$1/machine.json" && sdlc-status > "$1/status.txt" && sdlc-fingerprint > "$1/fp.txt"' sh "$work") >/dev/null 2>"$work/err.txt" || rc=$?
        case "$rc" in
          0) ;;
          42) fail 2 no_sdlc "the checkout's devenv exposes no platform.sdlc machine (\$SDLC_MACHINE unset)" "$ctx" ;;
          124) fail 2 timeout "the consumer's devenv shell did not answer within ${toString cfg.consumerTimeoutSeconds}s" "$ctx" ;;
          *) fail 2 command_failed "consumer devenv shell exited $rc: $(tail -c 300 "$work/err.txt" | tr '\n' ' ')" "$ctx" ;;
        esac
        machine=$(jq -c . "$work/machine.json" 2>/dev/null) && jq -e '.schemaVersion == 1 and (.order | type == "array")' <<<"$machine" >/dev/null 2>&1 \
          || fail 2 no_sdlc "the checkout's devenv exposes no platform.sdlc machine" "$ctx"
        status=$(cat "$work/status.txt"); fp=$(tr -d '\n' < "$work/fp.txt" 2>/dev/null || true)
        state="$checkout/.devenv/state/sdlc"
        reds="[]"; verdicts="[]"
        if [ -d "$state" ]; then
          # devenv runs execs with errexit: an unmatched glob must not end the loop with a failing status
          reds=$(for f in "$state"/last-red-*.json; do [ -f "$f" ] || continue; jq -c --arg fp "$fp" '{stage, guard, at, fingerprint, current: (.fingerprint == $fp), tail: (.tail // "" | .[-1200:])}' "$f" 2>/dev/null || true; done | jq -sc '.')
          verdicts=$(for f in "$state"/verdict-*.json; do [ -f "$f" ] || continue; jq -c --arg fp "$fp" --arg n "$(basename "$f" .json)" '{stage: ($n | ltrimstr("verdict-")), grade, fingerprint, current: (.fingerprint == $fp)}' "$f" 2>/dev/null || true; done | jq -sc '.')
        fi
        # stage state from sdlc-status's own table rows: "| <stage> | green|red|unverified |" (sdlc-status is read-only and already handles staleness)
        stages=$(jq -cn --argjson m "$machine" --arg s "$status" '
          # only the table that follows the "| stage | state |" header, up to the first blank line (the digest also echoes repo text)
          ($s | split("\n") | (index(["| stage | state |"]) // -1) as $h
            | if $h < 0 then [] else .[$h+2:] | (index([""]) // length) as $e | .[:$e] end
            | map(capture("^\\s*\\|\\s*(?<stage>[A-Za-z0-9_-]+)\\s*\\|\\s*(?<state>green|red|unverified)\\s*\\|")?) | map(select(. != null)) | map({key:.stage, value:.state}) | from_entries) as $st
          | [$m.order[] | {stage:., guards:($m.stages[.].guards // []), verdict:($m.stages[.].verdict // false), state:($st[.] // "unknown")}]')
        emit "$(jq -cn --arg at "$at" --argjson c "$ctx" --arg head "$head" --argjson dirty "$dirty" --arg fp "$fp" --argjson m "$machine" --argjson st "$stages" --arg txt "$status" --argjson reds "$reds" --argjson v "$verdicts" \
          '{schema_version:1} + $c + {observed_at:$at, error:null, head:(if $head=="null" then null else $head end), dirty_files:$dirty, fingerprint:(if $fp == "" then null else $fp end),
                 machine:{name:$m.name, bar:$m.bar, order:$m.order, terminal:$m.terminal}, stages:$st, status_text:($txt | .[0:4000]), red:$reds, verdicts:$v,
                 all_green:(($st | length) > 0 and ([$st[] | .state] | all(. == "green"))), note:"states come from sdlc-status (green|red|unverified); exit codes of this task are never a verdict"}')"
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
        [[ "$stage" =~ ^[A-Za-z0-9_-]{1,40}$ ]] || fail 3 invalid_input "stage must be a short name ([A-Za-z0-9_-])" "$ctx"
        ${checkoutCase}
        [ -d "$checkout" ] || fail 2 not_found "checkout does not exist: $checkout" "$ctx"
        devenv_bin=$(command -v ${cfg.devenvCommand}) || fail 2 command_failed "devenv not on PATH" "$ctx"
        at=$(now_iso); log=$(mktemp); rc=0
        head=$(timeout -k 1 ${toString cfg.timeoutSeconds} git -C "$checkout" rev-parse --short HEAD 2>/dev/null) || head=null
        ${consumerEnv}
        (cd "$checkout" && timeout -k 5 ${toString cfg.gateTimeoutSeconds} env -i "''${cenv[@]}" "$devenv_bin" tasks run "sdlc:$stage" --show-output) >"$log" 2>&1 || rc=$?
        tail_txt=$(tail -n 40 "$log" | LC_ALL=C cut -c1-400); rm -f "$log"
        kind=null
        if [ "$rc" -eq 124 ]; then kind='{"kind":"timeout","message":"stage did not finish within ${toString cfg.gateTimeoutSeconds}s"}'
        elif [ "$rc" -ne 0 ] && grep -qiE 'task .* not found|no such task|unknown task' <<<"$tail_txt"; then kind='{"kind":"invalid_input","message":"sdlc:'"$stage"' is not a stage of this machine"}'
        elif [ "$rc" -ne 0 ]; then kind='{"kind":"stage_red","message":"devenv tasks run sdlc:'"$stage"' exited '"$rc"'"}'; fi
        emit "$(jq -cn --arg at "$at" --argjson c "$ctx" --arg head "$head" --argjson rc "$rc" --arg tail "$tail_txt" --argjson e "$kind" \
          '{schema_version:1} + $c + {started_at:$at, head:(if $head=="null" then null else $head end), exit:$rc, green:($rc == 0), output_tail:$tail, error:$e}')"
        [ "$rc" -eq 0 ] || exit 2
      '';
    };
  };
}
