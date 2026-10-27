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
          "agent list") cat "''${FAKE_HERDR_LIST:?}" ;;
          "agent read") # like herdr 0.9.5: <TARGET> comes first; an option or `--` in its place is "unknown option"
            case "$3" in -*|"") echo "unknown option: ''${3:-<none>}" >&2; exit 2 ;; esac
            cat "''${FAKE_HERDR_READ:?}" ;;
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
        # `gh api [-X METHOD] repos/O/R/issues/N/labels[/L] | .../comments [--input -]`: FAKE_GH_LABELS (JSON array) is the
        # issue's label set, FAKE_GH_API_EXIT forces failure, FAKE_GH_COMMENT_OUT captures a posted body
        if [ "$1" = api ]; then
          [ -n "''${FAKE_GH_API_EXIT:-}" ] && { echo "gh: HTTP 404 Not Found (HTTP 404)" >&2; exit "$FAKE_GH_API_EXIT"; }
          method=GET; path=""; body=""; prev=""
          for a in "$@"; do case "$prev" in -X|--method) method="$a" ;; --input) [ "$a" = - ] && body=$(cat) ;; esac; case "$a" in repos/*) path="$a" ;; esac; prev="$a"; done
          case "$method $path" in
            "GET "*/labels) printf '%s\n' "''${FAKE_GH_LABELS:-[]}" | jq 'map({name:.})' ;;
            "POST "*/labels) jq -c --argjson have "''${FAKE_GH_LABELS:-[]}" '($have + .labels) | unique | map({name:.})' <<<"$body" ;;
            "DELETE "*/labels/*) echo '[]' ;;
            "POST "*/comments) [ -n "''${FAKE_GH_COMMENT_OUT:-}" ] && jq -r .body <<<"$body" > "$FAKE_GH_COMMENT_OUT"
              printf '{"id":1,"html_url":"https://github.com/%s#issuecomment-1"}\n' "$(sed -E 's#^repos/([^/]+/[^/]+)/issues/([0-9]+)/comments$#\1/issues/\2#' <<<"$path")" ;;
            *) echo "fake gh: unsupported api $method $path" >&2; exit 2 ;;
          esac
          exit 0
        fi
        case "$1 $2" in "issue list") kind="issues" ;; "pr list") kind="prs" ;; *) echo "fake gh: unsupported $*" >&2; exit 2 ;; esac
        state=""; prev=""; for a in "$@"; do case "$prev" in --state) state="$a" ;; esac; prev="$a"; done
        f="''${FAKE_GH_DIR:?}/''${repo//\//__}.$kind.json"
        if [ -r "$f" ]; then case "$kind:$state" in prs:open) jq 'map(select(.state == "OPEN"))' "$f" ;; prs:merged) jq 'map(select(.state == "MERGED"))' "$f" ;; *) cat "$f" ;; esac; else echo "[]"; fi
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
