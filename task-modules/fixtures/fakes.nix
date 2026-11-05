# Test doubles for the task suites, built by Nix instead of shipped as scripts: a fake herdr (local server plus
# saved machines via --machine), gh and devenv, all logging their calls to $FAKE_LOG.
{ lib, pkgs, ... }:
{
  options.coordinator.fakes = lib.mkOption {
    type = lib.types.package;
    readOnly = true;
    description = "bin/{herdr,gh,devenv} fakes for the test tasks; FAKE_* variables drive their behaviour.";
    default = pkgs.symlinkJoin {
      name = "coordinator-fakes";
      paths = [
      (pkgs.writeShellScriptBin "herdr" ''
        # Fake herdr for task tests. FAKE_HERDR_LIST=<file> is what `agent list` prints; FAKE_HERDR_READ=<file>
        # what `agent read` prints; FAKE_HERDR_EXIT forces an exit code; FAKE_HERDR_SLEEP delays.
        # FAKE_HERDR_STATE drives `agent get`/`agent wait`; FAKE_HERDR_STATE_SEQ="idle,working,idle" plays one
        # state per call (counter in $FAKE_LOG.seq); FAKE_HERDR_SEQ sets state_change_seq, FAKE_HERDR_SESSION the
        # session id, FAKE_HERDR_MISSING=<id> makes get/wait fail with agent_not_found, FAKE_HERDR_GET_RAW replaces
        # the get output; FAKE_HERDR_PROMPT=ok|blocked|stalled|timeout drives `agent prompt` and FAKE_PROMPT_OUT
        # captures the prompt text; FAKE_HERDR_WAIT=timeout / FAKE_HERDR_WAIT_SLEEP shape `agent wait`.
        echo "herdr $*" >> "''${FAKE_LOG:-/dev/null}"
        # saved machines: FAKE_HERDR_MACHINES is the `machine list --json` answer; `--machine <L>` selects FAKE_HERDR_LIST_<L>
        # (and FAKE_HERDR_EXIT_<L>) for that machine, like herdr forwarding to another server; `*down*` labels are unreachable
        if [ "$1" = --machine ]; then
          m="$2"; shift 2; echo "herdr(machine=$m) $*" >> "''${FAKE_LOG:-/dev/null}"
          # like herdr 0.9.5: a connection failure is exit 1 with one stderr line, an unknown machine is exit 2
          case "$m" in *down*) echo "error: failed to connect to machine '$m': ssh exited 255" >&2; exit 1 ;; esac
          jq -e --arg m "$m" 'any(.[]?; .label == $m and .enabled == true)' <<<"''${FAKE_HERDR_MACHINES:-[]}" >/dev/null 2>&1 || { echo "error: unknown machine '$m'; use \`herdr machine list\`" >&2; exit 2; }
          lv="FAKE_HERDR_LIST_''${m//-/_}"; [ -n "''${!lv:-}" ] && export FAKE_HERDR_LIST="''${!lv}"
          ev="FAKE_HERDR_EXIT_''${m//-/_}"; [ -n "''${!ev:-}" ] && export FAKE_HERDR_EXIT="''${!ev}"
          mv_="FAKE_HERDR_MISSING_''${m//-/_}"; [ -n "''${!mv_:-}" ] && export FAKE_HERDR_MISSING="''${!mv_}"
        fi
        if [ "$1 $2" = "machine list" ]; then [ -n "''${FAKE_HERDR_MACHINES_EXIT:-}" ] && exit "$FAKE_HERDR_MACHINES_EXIT"; printf '%s\n' "''${FAKE_HERDR_MACHINES:-[]}"; exit 0; fi
        [ -n "''${FAKE_HERDR_SLEEP:-}" ] && sleep "$FAKE_HERDR_SLEEP"
        state() {
          if [ -n "''${FAKE_HERDR_STATE_SEQ:-}" ]; then
            local n; n=$(cat "''${FAKE_LOG:-/tmp/fake}.seq" 2>/dev/null || echo 0); IFS=, read -ra arr <<<"$FAKE_HERDR_STATE_SEQ"
            [ "$n" -lt "''${#arr[@]}" ] || n=$(( ''${#arr[@]} - 1 )); echo $(( n + 1 )) > "''${FAKE_LOG:-/tmp/fake}.seq"; printf '%s' "''${arr[$n]}"
          else printf '%s' "''${FAKE_HERDR_STATE:-idle}"; fi
        }
        want_state() { local s="$1"; shift; while [ $# -gt 0 ]; do [ "$1" = --until ] && [ "$2" = "$s" ] && return 0; shift; done; return 1; }
        agent_info() { printf '{"id":"cli:agent:%s","result":{"agent":{"pane_id":"%s","agent":"claude","agent_session":{"agent":"claude","kind":"id","value":"%s"},"agent_status":"%s","state_change_seq":%s,"revision":3},"type":"agent_info"}}\n' "$1" "$2" "''${FAKE_HERDR_SESSION:-sess-1}" "$3" "$4"; }
        case "$1 $2" in
          # FAKE_HERDR_STARTED=<file>: agents a successful `agent start` registered (one JSON object per line) join the list,
          # like a real server listing the new agent
          "agent list") if [ -s "''${FAKE_HERDR_STARTED:-/nonexistent}" ]; then jq --slurpfile s "$FAKE_HERDR_STARTED" '.result.agents += $s' "''${FAKE_HERDR_LIST:?}"; else cat "''${FAKE_HERDR_LIST:?}"; fi ;;
          "agent read") # like herdr 0.9.5: <TARGET> comes first; an option or `--` in its place is "unknown option"
            case "$3" in -*|"") echo "unknown option: ''${3:-<none>}" >&2; exit 2 ;; esac
            # FAKE_HERDR_READ_<agent id, non-alphanumerics as _> is that agent's pane, else FAKE_HERDR_READ
            rv="FAKE_HERDR_READ_''${3//[^A-Za-z0-9]/_}"; cat "''${!rv:-''${FAKE_HERDR_READ:?}}" ;;
          "agent get") [ "''${FAKE_HERDR_MISSING:-}" = "$3" ] && { echo '{"error":{"code":"agent_not_found","message":"no such agent"}}' >&2; exit 1; }
            [ -n "''${FAKE_HERDR_GET_RAW:-}" ] && { printf '%s\n' "$FAKE_HERDR_GET_RAW"; exit 0; }
            agent_info get "$3" "$(state)" "''${FAKE_HERDR_SEQ:-7}" ;;
          "agent prompt") [ -n "''${FAKE_PROMPT_OUT:-}" ] && printf '%s' "$4" > "$FAKE_PROMPT_OUT"
            case "''${FAKE_HERDR_PROMPT:-ok}" in
              ok) printf '{"id":"cli:agent:prompt","result":{"type":"agent_prompt","delivered":true}}\n' ;;
              blocked) echo '{"error":{"code":"agent_blocked","message":"agent is blocked"}}' >&2; exit 1 ;;
              stalled) echo '{"error":{"code":"agent_prompt_stalled","message":"no activity within 5000ms"}}' >&2; exit 1 ;;
              timeout) exec sleep 60 ;;
            esac ;;
          "agent wait") [ -n "''${FAKE_HERDR_WAIT_SLEEP:-}" ] && sleep "$FAKE_HERDR_WAIT_SLEEP"
            s=$(state)
            [ "''${FAKE_HERDR_MISSING:-}" = "$3" ] && { echo '{"error":{"code":"agent_not_found","message":"no such agent"}}' >&2; exit 1; }
            if [ "''${FAKE_HERDR_WAIT:-reached}" = timeout ] || ! want_state "$s" "$@"; then echo '{"error":{"code":"timeout","message":"state not reached"}}' >&2; exit 1; fi
            agent_info wait "$3" "$s" 9 ;;
          # coord:spawn: FAKE_HERDR_WS=<id> names the created workspace (root pane <id>:p1); FAKE_HERDR_START=ok|not_ready|fail,
          # FAKE_HERDR_START_SLEEP delays it
          "workspace create") w="''${FAKE_HERDR_WS:-wN}"; printf '{"id":"cli:workspace:create","result":{"type":"workspace_created","workspace":{"workspace_id":"%s"},"tab":{"tab_id":"%s:t1"},"root_pane":{"pane_id":"%s:p1"}}}\n' "$w" "$w" "$w" ;;
          "agent start") [ -n "''${FAKE_HERDR_START_SLEEP:-}" ] && sleep "$FAKE_HERDR_START_SLEEP"
            case "''${FAKE_HERDR_START:-ok}" in
              ok) [ -n "''${FAKE_HERDR_STARTED:-}" ] && jq -cn --arg p "$7" --arg s "''${FAKE_HERDR_SESSION:-sess-new}" '{pane_id:$p, agent:"claude", agent_status:"idle", agent_session:{agent:"claude", kind:"id", value:$s}, cwd:"/home/lukas", terminal_title_stripped:"Claude Code"}' >> "$FAKE_HERDR_STARTED"
                printf '{"id":"cli:agent:start","result":{"type":"agent_started","agent":{"name":"%s","pane_id":"%s","agent":"claude","agent_session":{"agent":"claude","kind":"id","value":"%s"},"agent_status":"idle"}}}\n' "$3" "$7" "''${FAKE_HERDR_SESSION:-sess-new}" ;;
              not_ready) echo '{"error":{"code":"agent_not_ready","message":"agent blocked during startup"}}' >&2; exit 1 ;;
              *) echo '{"error":{"code":"pane_not_available","message":"pane is not at a shell prompt"}}' >&2; exit 1 ;;
            esac ;;
          *) echo "fake herdr: unsupported $*" >&2; exit 2 ;;
        esac
        exit "''${FAKE_HERDR_EXIT:-0}"
      '')
      (pkgs.writeShellScriptBin "gh" ''
        # Fake gh for task tests: FAKE_GH_DIR holds <repo-slug>.issues.json / .prs.json; FAKE_GH_EXIT forces failure.
        echo "gh $*" >> "''${FAKE_LOG:-/dev/null}"
        [ -n "''${FAKE_GH_EXIT:-}" ] && { echo "gh: HTTP 401 Bad credentials" >&2; exit "$FAKE_GH_EXIT"; }
        repo=""; kind=""; prev=""
        for a in "$@"; do case "$prev" in -R|--repo) repo="$a" ;; esac; prev="$a"; done
        # `gh api [-X METHOD] repos/O/R/issues/N/labels[/L] | .../events | .../comments [--input -]`: FAKE_GH_LABELS (JSON
        # array) is the issue's label set, FAKE_GH_EVENTS its label events, FAKE_GH_API_EXIT forces failure, FAKE_GH_SLEEP
        # delays, FAKE_GH_COMMENT_OUT captures a posted body, FAKE_GH_COMMENT_RAW replaces the comment answer. The audit
        # lock (fd 9) must never reach gh: an inherited fd 9 is a test failure.
        if [ "$1" = api ]; then
          [ -e /proc/self/fd/9 ] && { echo "fake gh: fd 9 (the audit lock) was inherited" >&2; exit 99; }
          [ -n "''${FAKE_GH_SLEEP:-}" ] && sleep "$FAKE_GH_SLEEP"
          [ -n "''${FAKE_GH_API_EXIT:-}" ] && { echo "gh: HTTP 404 Not Found (HTTP 404)" >&2; exit "$FAKE_GH_API_EXIT"; }
          # `gh api graphql -f query=… -F owner=… -F n=N`: FAKE_GH_REPOS is the owner's repository node list (archived ones
          # included, as if the server ignored isArchived:false), cut at n like a page; FAKE_GH_GRAPHQL_RAW replaces the answer
          if [ "$2" = graphql ]; then
            [ -n "''${FAKE_GH_GRAPHQL_RAW:-}" ] && { printf '%s\n' "$FAKE_GH_GRAPHQL_RAW"; exit 0; }
            # like GitHub: `labels` arrives as a list only through repeated -F labels[]=<label>; each fixture node carries
            # issue_labels (one label list per open issue) and `approved.totalCount` is computed against the requested list,
            # so a query that never sends the list reads 0
            n=100; req='[]'; prev=""; for a in "$@"; do case "$prev" in -F|--field) case "$a" in n=*) n="''${a#n=}" ;; "labels[]="*) req=$(jq -c --arg l "''${a#labels[]=}" '. + [$l]' <<<"$req") ;; esac ;; esac; prev="$a"; done
            [ -n "''${FAKE_GH_IGNORE_N:-}" ] && n=1000   # a server that ignores first:n, to prove the client-side cap
            jq -c --argjson n "$n" --argjson req "$req" '{data:{repositoryOwner:{repositories:{totalCount:length,
              nodes:(.[:$n] | map(. + {approved:{totalCount:([(.issue_labels // [])[] | select(any(.[]; . as $l | ($req | index($l)) != null))] | length)}} | del(.issue_labels)))}}}}' <<<"''${FAKE_GH_REPOS:-[]}"
            exit 0
          fi
          method=GET; path=""; body=""; prev=""
          for a in "$@"; do case "$prev" in -X|--method) method="$a" ;; --input) [ "$a" = - ] && body=$(cat) ;; esac; case "$a" in repos/*) path="''${a%%\?*}" ;; esac; prev="$a"; done
          case "$method $path" in
            "GET "*/labels) printf '%s\n' "''${FAKE_GH_LABELS:-[]}" | jq 'map({name:.})' ;;
            "GET "*/events) printf '%s\n' "''${FAKE_GH_EVENTS:-[]}" ;;
            # `gh api repos/O/R/issues/N`: the issue with FAKE_GH_LABELS; FAKE_GH_ISSUE_IS_PR makes it a pull request
            "GET "repos/*/issues/[0-9]*) printf '%s\n' "''${FAKE_GH_LABELS:-[]}" | jq --arg n "''${path##*/}" --arg pr "''${FAKE_GH_ISSUE_IS_PR:-}" --arg u "''${FAKE_GH_ISSUE_USER:-sammasak}" --arg st "''${FAKE_GH_ISSUE_STATE:-open}" '{number:($n|tonumber), state:$st, user:{login:$u}, author_association:(if $u == "sammasak" then "OWNER" else "NONE" end), labels:map({name:.})} + (if $pr == "" then {} else {pull_request:{url:"x"}} end)' ;;
            "POST "*/labels) jq -c --argjson have "''${FAKE_GH_LABELS:-[]}" '($have + .labels) | unique | map({name:.})' <<<"$body" ;;
            "DELETE "*/labels/*) echo '[]' ;;
            # `gh api repos/O/R/issues?state=open…`: FAKE_GH_OPEN_ISSUES (the open issues); POST creates one: FAKE_GH_ISSUE_OUT
            # captures the request, FAKE_GH_ISSUE_RAW replaces the answer, FAKE_GH_POST_ISSUE_EXIT fails the create alone
            "GET "repos/*/issues) printf '%s\n' "''${FAKE_GH_OPEN_ISSUES:-[]}" ;;
            "POST "repos/*/issues) [ -n "''${FAKE_GH_ISSUE_OUT:-}" ] && printf '%s\n' "$body" > "$FAKE_GH_ISSUE_OUT"
              [ -n "''${FAKE_GH_POST_ISSUE_EXIT:-}" ] && { echo "gh: HTTP 422 Validation Failed" >&2; exit "$FAKE_GH_POST_ISSUE_EXIT"; }
              [ -n "''${FAKE_GH_ISSUE_RAW:-}" ] && { printf '%s\n' "$FAKE_GH_ISSUE_RAW"; exit 0; }
              printf '{"number":99,"html_url":"https://github.com/%s/issues/99"}\n' "$(sed -E 's#^repos/([^/]+/[^/]+)/issues$#\1#' <<<"$path")" ;;
            "POST "*/comments) [ -n "''${FAKE_GH_COMMENT_OUT:-}" ] && jq -r .body <<<"$body" > "$FAKE_GH_COMMENT_OUT"
              [ -n "''${FAKE_GH_COMMENT_RAW:-}" ] && { printf '%s\n' "$FAKE_GH_COMMENT_RAW"; exit 0; }
              printf '{"id":1,"html_url":"https://github.com/%s#issuecomment-1"}\n' "$(sed -E 's#^repos/([^/]+/[^/]+)/issues/([0-9]+)/comments$#\1/issues/\2#' <<<"$path")" ;;
            *) echo "fake gh: unsupported api $method $path" >&2; exit 2 ;;
          esac
          exit 0
        fi
        # `gh search issues --owner O --label L --state open --json repository,number,title,url`: FAKE_GH_SEARCH is the hit list
        # (objects with repository.nameWithOwner, number, title, url); FAKE_GH_SEARCH_EXIT fails the search alone
        if [ "$1 $2" = "search issues" ]; then
          [ -n "''${FAKE_GH_SEARCH_EXIT:-}" ] && { echo "gh: HTTP 403 API rate limit exceeded for search" >&2; exit "$FAKE_GH_SEARCH_EXIT"; }
          printf '%s\n' "''${FAKE_GH_SEARCH:-[]}"; exit 0; fi
        case "$1 $2" in "issue list") kind="issues" ;; "pr list") kind="prs" ;; *) echo "fake gh: unsupported $*" >&2; exit 2 ;; esac
        # FAKE_GH_LIST_EXIT fails the list calls alone (the GraphQL repo query above keeps answering)
        [ -n "''${FAKE_GH_LIST_EXIT:-}" ] && { echo "gh: HTTP 502 Bad Gateway" >&2; exit "$FAKE_GH_LIST_EXIT"; }
        # like gh: --limit N cuts the list silently at N
        state=""; limit=30; prev=""; for a in "$@"; do case "$prev" in --state) state="$a" ;; --limit|-L) limit="$a" ;; esac; prev="$a"; done
        f="''${FAKE_GH_DIR:?}/''${repo//\//__}.$kind.json"
        if [ -r "$f" ]; then case "$kind:$state" in prs:open) jq --argjson n "$limit" 'map(select(.state == "OPEN")) | .[:$n]' "$f" ;; prs:merged) jq --argjson n "$limit" 'map(select(.state == "MERGED")) | .[:$n]' "$f" ;; *) jq --argjson n "$limit" '.[:$n]' "$f" ;; esac; else echo "[]"; fi
      '')
      (pkgs.writeShellScriptBin "ssh" ''
        # Fake ssh for host:locks: logs the call; a `*down*` target fails like an unreachable host (exit 255);
        # otherwise prints FAKE_SSH_OUT_<target> (a file) or FAKE_SSH_OUT; stdin (the observer script) is ignored.
        echo "ssh $*" >> "''${FAKE_LOG:-/dev/null}"
        target=""; for a in "$@"; do case "$a" in -*|sh|-s|BatchMode=yes|ConnectTimeout=5) ;; *) [ -z "$target" ] && target="$a" ;; esac; done
        case "$target" in *down*) echo "ssh: connect to host $target port 22: Connection refused" >&2; exit 255 ;; esac
        v="FAKE_SSH_OUT_$(printf '%s' "$target" | tr -c 'A-Za-z0-9_' '_')"; f="''${!v:-''${FAKE_SSH_OUT:-}}"
        [ -n "$f" ] && cat "$f"; exit 0
      '')
      (pkgs.writeShellScriptBin "host-locks" ''
        # Fake local locks observer for host:locks: prints FAKE_LOCKS_OUT (a TSV file), or nothing.
        echo "host-locks $*" >> "''${FAKE_LOG:-/dev/null}"
        [ -n "''${FAKE_LOCKS_OUT:-}" ] && cat "$FAKE_LOCKS_OUT"; exit 0
      '')
      (pkgs.writeShellScriptBin "devenv" ''
        # Fake devenv for quality tests: answers the three calls quality:report/quality:gate make inside a checkout.
        # FAKE_SDLC_DIR holds machine.json and status.txt; FAKE_GATE_EXIT forces `tasks run sdlc:<stage>`'s exit.
        echo "devenv($PWD) $*" >> "''${FAKE_LOG:-/dev/null}"
        env | grep -E '^(DEVENV_|SDLC_|IN_NIX_SHELL=|name=|NIX_CFLAGS|PKG_CONFIG_PATH=|DIRENV_|TZ=$|XDG_[A-Z_]+=$)' >> "''${FAKE_LOG:-/dev/null}.leak" || true   # also: no empty-but-set TZ/XDG_*
        case ":$PATH:" in *".devenv/profile"*) echo "PATH=$PATH" >> "''${FAKE_LOG:-/dev/null}.leak" ;; esac
        case "$1 $2" in
          "shell -q") # one-shot: sh -c '<script>' sh <workdir>  -> write machine/status/fp like the real consumer shell would
            work="''${*: -1}"
            # the fake stands for the consumer shell + the shipped script: no machine => the script's own `exit 42`
            [ -f "''${FAKE_SDLC_DIR:?}/machine.json" ] || exit 42
            cp "$FAKE_SDLC_DIR/machine.json" "$work/machine.json"; cp "$FAKE_SDLC_DIR/status.txt" "$work/status.txt"; printf '%s\n' "''${FAKE_SDLC_FP:-fp1}" > "$work/fp.txt" ;;
          "tasks run") case "$3" in sdlc:*) echo "fake stage $3 running"; echo "fake tail line"; exit "''${FAKE_GATE_EXIT:-0}" ;; *) echo "fake devenv: unknown task $3" >&2; exit 2 ;; esac ;;
          *) echo "fake devenv: unsupported $*" >&2; exit 2 ;;
        esac
      '')
      ];
    };
  };
}
