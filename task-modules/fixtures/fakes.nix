# Test doubles for the task suites, built by Nix instead of shipped as scripts: a fake ssh (runs the remote
# argv through fish like the fleet's login shell), herdr, gh and devenv, all logging their calls to $FAKE_LOG.
{ lib, pkgs, ... }:
{
  options.coordinator.fakes = lib.mkOption {
    type = lib.types.package;
    readOnly = true;
    description = "bin/{ssh,herdr,gh,devenv} fakes for the test tasks; FAKE_* variables drive their behaviour.";
    default = pkgs.symlinkJoin {
      name = "coordinator-fakes";
      paths = [
      (pkgs.writeShellScriptBin "ssh" ''
        # Fake ssh for task tests. The target decides the behaviour:
        #   *timeout*  -> hang until killed;  *down* -> exit 255 like a refused connection;
        #   otherwise  -> like real ssh, join the remote argv into ONE string and run it through a shell,
        #                 with the sibling fake herdr first on PATH.
        echo "ssh $*" >> "''${FAKE_LOG:-/dev/null}"
        while [ $# -gt 0 ]; do case "$1" in -o|-p|-i|-l|-F) shift 2 ;; --) shift; break ;; -*) shift ;; *) break ;; esac; done
        target="$1"; shift
        case "$target" in
          *timeout*) exec sleep 60 ;;
          *down*) echo "ssh: connect to host $target port 22: Connection refused" >&2; exit 255 ;;
        esac
        here=$(dirname "$0"); export PATH="$here:$PATH" FAKE_HERDR_LIST="''${FAKE_REMOTE_LIST:-''${FAKE_HERDR_LIST:-}}"
        # the remote login shell is fish on the fleet; the task ships `bash -c '<runner>' _ <b64>`, which any shell runs.
        # Log the decoded argv (NUL-separated words joined by spaces) so tests can assert on the real remote command.
        b64=$(sed -nE "s/^bash -c '.*' _ ([A-Za-z0-9+\/=]+)$/\1/p" <<<"$*")
        [ -n "$b64" ] && { printf '%s' "$b64" | base64 -d | tr '\0' ' ' >> "''${FAKE_LOG:-/dev/null}"; echo >> "''${FAKE_LOG:-/dev/null}"; }
        command -v fish >/dev/null || { echo "fake ssh: fish required to emulate the fleet's login shell" >&2; exit 2; }
        exec fish --no-config -c "$*"
      '')
      (pkgs.writeShellScriptBin "herdr" ''
        # Fake herdr for task tests. FAKE_HERDR_LIST=<file> is what `agent list` prints; FAKE_HERDR_READ=<file>
        # what `agent read` prints; FAKE_HERDR_EXIT forces an exit code; FAKE_HERDR_SLEEP delays.
        # FAKE_HERDR_STATE drives `agent get`/`agent wait`; FAKE_HERDR_STATE_SEQ="idle,working,idle" plays one
        # state per call (counter in $FAKE_LOG.seq); FAKE_HERDR_SEQ sets state_change_seq, FAKE_HERDR_SESSION the
        # session id, FAKE_HERDR_MISSING=<id> makes get/wait fail with agent_not_found, FAKE_HERDR_GET_RAW replaces
        # the get output; FAKE_HERDR_PROMPT=ok|blocked|stalled|timeout drives `agent prompt` and FAKE_PROMPT_OUT
        # captures the prompt text; FAKE_HERDR_WAIT=timeout / FAKE_HERDR_WAIT_SLEEP shape `agent wait`.
        echo "herdr $*" >> "''${FAKE_LOG:-/dev/null}"
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
