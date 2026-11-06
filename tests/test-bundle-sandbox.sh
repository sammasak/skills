#!/usr/bin/env bash
# skills#63 acceptance item 3: a bundle built by bundles/default.nix, inside a sandbox fixture (bubblewrap: new user,
# mount, pid, network, ipc and uts namespaces, read-only store, private HOME and /tmp, empty environment, no
# credentials), is loaded the way its harness adapter reads it (the adapter's skills resolve to exactly bundled
# skills, the role's declared tasks to shipped scripts) and runs a declared read and run task of the role against a
# fixture checkout through the existing fake devenv. The tasks are task-modules/ code, evaluated, not copied.
#
#   FAKES=<coordinator.fakes>/bin BWRAP=<bwrap> bash tests/test-bundle-sandbox.sh   (the skills:test:bundle-sandbox task)
# shellcheck disable=SC2016 # programs in single quotes run inside the sandbox
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${FAKES:?the coordinator fakes bin dir}" "${BWRAP:?the bwrap binary}"
T=$(mktemp -d); trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
REV=0123456789abcdef0123456789abcdef01234567
fails=0
ok() { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; fails=$((fails + 1)); }
expect() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi; }

# the bundle, from this working tree (without .git and local state), through the nix entry point a consumer imports
src=$(nix eval --raw --impure --expr "toString (builtins.path { path = $ROOT; name = \"skills-src\";
  filter = p: t: !(builtins.elem (baseNameOf p) [ \".git\" \".devenv\" \".direnv\" \"result\" \"devenv.local.nix\" \"devenv.local.yaml\" ]); })") \
  || { bad "the source tree copies into the store"; exit 1; }
build() { # <extra-module-nix> -> bundle store path
  nix-build --no-out-link -E "let pkgs = import <nixpkgs> { }; in (import $src/bundles { inherit pkgs; src = $src; rev = \"$REV\"; }).bundle {
    role = \"quality\"; harness = \"claude-code\"; skills = [ \"rust-engineering\" \"nix-flake-development\" ]; taskConfig = $1; }" 2>"$T/build.err" | tail -n 1
}
# the fake consumer devenv reads FAKE_SDLC_DIR, so the test bundle passes it through as the quality suite does
B=$(build '{ coordinator.consumerEnvPassthrough = "FAKE_SDLC_DIR FAKE_LOG"; }')
[ -n "$B" ] && [ -f "$B/bundle.json" ] && ok "the bundle builds through bundles/default.nix" || { bad "bundle build ($(tail -3 "$T/build.err"))"; exit 1; }
M="$B/bundle.json"
expect "every declared read and run task ships, act tasks do not" "gh:work git:recent quality:gate quality:report" "$(jq -r '.tasks.scripts | keys | join(" ")' "$M")"
expect "each shipped task is the evaluated task-module code" "yes yes" \
  "$(grep -q 'fail 3 invalid_input "checkout must be a plain absolute path"' "$B/tasks/quality:report" && echo yes || echo no) $(grep -q 'git -C "$checkout" rev-parse --short HEAD' "$B/tasks/quality:gate" && echo yes || echo no)"
expect "a shipped task carries its sha256 in bundle.json" "true" "$(jq --arg s "$(sha256sum <"$B/tasks/quality:report" | cut -c1-64)" '.tasks.scripts["quality:report"].sha256 == $s' "$M")"
B0=$(build '{ }')
expect "the task config is part of the bundle: a different passthrough moves the task's sha256 and the digest" "true true" \
  "$(jq -r --slurpfile o "$B0/bundle.json" '(.tasks.scripts["quality:report"].sha256 != $o[0].tasks.scripts["quality:report"].sha256)' "$M") $(jq -r --slurpfile o "$B0/bundle.json" '.digests.bundle != $o[0].digests.bundle' "$M")"

expect "the coordinator role bundles too: every declared read task ships, no act task does" "true" \
  "$(C=$(nix-build --no-out-link -E "let pkgs = import <nixpkgs> { }; in (import $src/bundles { inherit pkgs; src = $src; rev = \"$REV\"; }).bundle { role = \"coordinator\"; harness = \"claude-code\"; skills = [ \"herdr-operations\" ]; }" 2>/dev/null | tail -n 1)
     [ -n "$C" ] && jq '.tasks.scripts as $s | (.tasks.read - ($s | keys)) == [] and ([.tasks.act[] | . as $a | select($s | has($a))] == [])' "$C/bundle.json" 2>/dev/null || echo false)"

# a task's declared input defaults reach it as devenv merges them (review of #71): the coordinator bundle's herdr:inspect
# declares lines = 40 and source = "visible"; called with only agent_id it must ask the fake herdr for 40 visible lines
C=$(nix-build --no-out-link -E "let pkgs = import <nixpkgs> { }; in (import $src/bundles { inherit pkgs; src = $src; rev = \"$REV\"; }).bundle { role = \"coordinator\"; harness = \"claude-code\"; skills = [ \"herdr-operations\" ]; }" 2>/dev/null | tail -n 1)
expect "a shipped task records its declared input defaults" '{"agent_id":null,"lines":40,"machine":null,"source":"visible"}' "$(jq -cS '.tasks.scripts["herdr:inspect"].input' "$C/bundle.json" 2>/dev/null)"
: > "$T/inspect.log"
rc=0; PATH="$FAKES:$PATH" FAKE_LOG="$T/inspect.log" FAKE_HERDR_READ="$ROOT/task-modules/fixtures/herdr/read-visible.txt" HOME="$T" "$C/bin/bundle-run" herdr:inspect '{"agent_id":"wA:p2"}' > "$T/inspect.out" 2>&1 || rc=$?
expect "bundle-run merges the defaults: herdr:inspect with only agent_id reads 40 visible lines" "0 yes" \
  "$rc $(grep -q '^herdr agent read wA:p2 --lines 40 --source visible' "$T/inspect.log" && echo yes || echo "no ($(head -c 200 "$T/inspect.out"))")"
expect "the caller's value wins over a default" "yes" \
  "$(: > "$T/inspect.log"; PATH="$FAKES:$PATH" FAKE_LOG="$T/inspect.log" FAKE_HERDR_READ="$ROOT/task-modules/fixtures/herdr/read-visible.txt" HOME="$T" "$C/bin/bundle-run" herdr:inspect '{"agent_id":"wA:p2","lines":7}' >/dev/null 2>&1; grep -q -- '--lines 7 ' "$T/inspect.log" && echo yes || echo no)"

# the fixture checkout (the quality suite's own fixture: one red stage, a stale verdict) and a store-only /usr/bin
git init -q "$T/repo" && (cd "$T/repo" && git config user.email t@t && git config user.name t && echo a > a && printf '.devenv/\n' > .gitignore \
  && git add a .gitignore && git commit -qm init && mkdir -p .devenv/state/sdlc && printf '%s' fp1 > .devenv/state/sdlc/sketch-rust-check \
  && printf '{"wrapper":"sdlc:test-rust-test","stage":"test","guard":"rust:test","at":"2026-10-26T10:00:00Z","tail":"test result: FAILED. 1 failed","fingerprint":"fp1"}' > .devenv/state/sdlc/last-red-test-rust-test.json \
  && printf '{"fingerprint":"fp0","grade":9}' > .devenv/state/sdlc/verdict-review.json)
mkdir -p "$T/usrbin"
# the fixture's /usr/bin: coreutils, grep, sed and bash from the store (the fake devenv and the probe use them)
for tool in cat sed grep bash; do d=$(dirname "$(readlink -f "$(command -v "$tool")")"); for f in "$d"/*; do [ -e "$T/usrbin/$(basename "$f")" ] || ln -s "$f" "$T/usrbin/$(basename "$f")"; done; done
ln -sf bash "$T/usrbin/sh"

# inside: no host environment, no network, the store read-only, the bundle read-only, HOME private and empty
# shellcheck disable=SC2094
"$BWRAP" --unshare-all --die-with-parent --new-session --clearenv \
  --ro-bind /nix/store /nix/store --proc /proc --dev /dev --tmpfs /tmp --tmpfs /home --dir /home/agent \
  --ro-bind "$B" /bundle --bind "$T/repo" /work/repo --ro-bind "$ROOT/task-modules/fixtures/sdlc" /fixture/sdlc \
  --ro-bind "$T/usrbin" /usr/bin --symlink usr/bin /bin --ro-bind "$FAKES" /fakes \
  --setenv HOME /home/agent --setenv PATH /fakes:/usr/bin --setenv FAKE_SDLC_DIR /fixture/sdlc --setenv FAKE_LOG /tmp/fake.log \
  "$(readlink -f "$(command -v bash)")" -c '
    M=/bundle/bundle.json
    J=$(grep -o "/nix/store/[a-z0-9]*-jq-[^/]*/bin" /bundle/tasks/quality:report | head -n 1)/jq
    say() { printf "%s=%s\n" "$1" "$2"; }
    say env_keys "$(env | cut -d= -f1 | LC_ALL=C sort | tr "\n" " ")"
    say secrets "$( [ -e /run/secrets ] || [ -e /home/agent/.ssh ] || [ -n "${SSH_AUTH_SOCK:-}" ] && echo present || echo absent)"
    say net "$(tail -n +3 /proc/net/dev | cut -d: -f1 | tr -d " " | tr "\n" " ")"
    say uid "$(cat /proc/self/uid_map | tr -s " ")"
    # the harness adapter, read as claude-code reads it: .claude/agents/<role>.md and its skills under .claude/skills
    a=/bundle/.claude/agents/quality.md; listed=""
    inlist=no; while IFS= read -r line; do
      case $inlist:$line in no:skills:) inlist=yes ;; "yes:  - "*) listed="$listed ${line#  - }" ;; yes:*) inlist=done ;; esac
    done < "$a"
    resolved=""; for s in $listed; do [ -f "/bundle/.claude/skills/$s/SKILL.md" ] && resolved="$resolved $s"; done
    say adapter_skills "${listed# }"; say adapter_resolved "${resolved# }"
    say bundled_skills "$(cd /bundle/.claude/skills && echo *)"
    declared=$("$J" -r "(.tasks.read + .tasks.run) | join(\" \")" $M); shipped=""
    for t in $declared; do [ -x "/bundle/tasks/$t" ] && shipped="$shipped $t"; done
    say declared_tasks "$declared"; say shipped_tasks "${shipped# }"
    /bundle/bin/bundle-check >/dev/null 2>&1; say check $?
    out=$(/bundle/bin/bundle-run quality:report "{\"checkout\":\"/work/repo\"}" 2>/tmp/err); say report_rc $?
    say report "$(printf "%s" "$out" | "$J" -c "{order: (.machine.order | join(\",\")), test: (.stages[] | select(.stage == \"test\") | .state), fp: .fingerprint, dirty: .dirty_files}" 2>/dev/null || head -c 300 /tmp/err)"
    out=$(/bundle/bin/bundle-run quality:gate "{\"checkout\":\"/work/repo\",\"stage\":\"test\"}" 2>/tmp/err); say gate_rc $?
    say gate "$(printf "%s" "$out" | "$J" -c "{stage, exit_code: (.exit_code // .exit // null)}" 2>/dev/null || head -c 300 /tmp/err)"
    /bundle/bin/bundle-run herdr:message "{}" >/dev/null 2>/tmp/err; say act_rc $?; say act_err "$("$J" -r .error.class /tmp/err 2>/dev/null)"
    say fake_calls "$(grep -c "devenv(/work/repo)" /tmp/fake.log 2>/dev/null)"
    touch /bundle/x 2>/dev/null && say bundle_ro no || say bundle_ro yes
  ' > "$T/inside.txt" 2>"$T/inside.err"
inside() { sed -n "s/^$1=//p" "$T/inside.txt"; }
[ -s "$T/inside.txt" ] || { bad "the sandbox ran ($(head -c 400 "$T/inside.err"))"; exit 1; }
expect "sandbox: an empty environment apart from what the fixture sets" "FAKE_LOG FAKE_SDLC_DIR HOME PATH PWD SHLVL _ " "$(inside env_keys)"
expect "sandbox: no secrets, SSH keys or agent socket" "absent" "$(inside secrets)"
expect "sandbox: loopback only, no network" "lo " "$(inside net)"
expect "sandbox: a user namespace (one mapped uid)" "1" "$(inside uid | wc -l | tr -d ' ')"
expect "harness adapter: every skill it lists resolves under .claude/skills" "$(inside adapter_skills)" "$(inside adapter_resolved)"
expect "harness adapter: it lists only bundled skills, and the bundle holds exactly the named ones" "rust-engineering|nix-flake-development rust-engineering" \
  "$(inside adapter_skills)|$(inside bundled_skills)"
expect "harness adapter: every task the role declares is a shipped script" "$(inside declared_tasks)" "$(inside shipped_tasks)"
expect "sandbox: bundle-check passes" "0" "$(inside check)"
expect "sandbox: the declared read task quality:report runs and reports the fixture" "0 {\"order\":\"sketch,model,test,review,perf,security\",\"test\":\"red\",\"fp\":\"fp1\",\"dirty\":0}" "$(inside report_rc) $(inside report)"
expect "sandbox: the declared run task quality:gate runs one stage through the fake devenv" "0" "$(inside gate_rc)"
expect "sandbox: a task the bundle does not ship (an act task) is refused" "3 task" "$(inside act_rc) $(inside act_err)"
expect "sandbox: the consumer devenv was called inside the checkout only" "true" "$( [ "$(inside fake_calls)" -ge 2 ] && echo true || echo false)"
expect "sandbox: the bundle is read-only" "yes" "$(inside bundle_ro)"
if [ "$fails" -eq 0 ]; then echo "bundle-sandbox: all checks passed"; else echo "bundle-sandbox: $fails check(s) failed"; exit 1; fi
