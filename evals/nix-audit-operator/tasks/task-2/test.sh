#!/usr/bin/env bash
# Behavioural grader: run snapshot.sh against a stub nix-audit (json-only, like the task's
# binary) whose exit code per target is set below, then check which snapshots survive.
set -uo pipefail
OUTPUT="${EVAL_OUTPUT_DIR:-/tmp/eval-output}/snapshot.sh"
[[ -f "$OUTPUT" ]] || { echo "FAIL: $OUTPUT not found"; exit 1; }
bash -n "$OUTPUT" || { echo "FAIL: not valid bash"; exit 1; }
if grep -vE '^\s*#' "$OUTPUT" | grep -q -- '--gate'; then echo "FAIL: ran a gate that was not asked for"; exit 1; fi

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
# JSON only with --json; policy and scan sections only when --policy / a real scan were requested.
cat > "$work/bin/nix-audit" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  --version) echo "nix-audit 0.1.0 (a1b2c3d4e5f6)"; exit 0 ;;
  scan) ;;
  *) echo "stub: unexpected subcommand $1" >&2; exit 2 ;;
esac
shift
json=0; policy=""; noscan=0; target=""
while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h) printf 'Usage: nix-audit scan [OPTIONS] <TARGET>\n  --json\n  --policy <FILE>\n  --scanners <LIST>\n  --no-scan\n  --offline\n'; exit 0 ;;
    --json-out*) echo "error: unexpected argument '--json-out' found" >&2; exit 2 ;;
    --json) json=1 ;;
    --policy) policy=$2; shift ;;
    --no-scan) noscan=1 ;;
    --scanners|--work-dir|--today) shift ;;
    -*) ;;
    *) target=$1 ;;
  esac
  shift
done
case "$target" in /run/current-system) side=now ;; "$NEXT_GEN") side=next ;; *) echo "stub: unexpected target $target" >&2; exit 2 ;; esac
rc=$(cat "$STUB_RC_DIR/$side")
echo "nix-audit: diagnostics on stderr" >&2
if [ $json = 1 ]; then
  scan='{"scanners":["grype","vulnix"]}'; [ $noscan = 1 ] && scan=null
  pol=null; [ -n "$policy" ] && pol="{\"source\":{\"path\":\"$policy\"}}"
  printf '{"schema":"nix-audit-report/v0","target":"%s","scan":%s,"policy":%s}\n' "$target" "$scan" "$pol"
else
  printf 'nix-audit summary for %s\n  packages: 1476\n' "$target"
fi
[ "$rc" = 3 ] && echo "nix-audit: scan incomplete — grype failed: vulnerability database missing" >&2
exit "$rc"
STUB
# The real host lock may be held by other work; a correct script that takes it must not hang.
cat > "$work/bin/flock" <<'STUB'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do case "$1" in -w|--wait|-E|--timeout|--conflict-exit-code) shift 2 ;; -*) shift ;; *) break ;; esac; done
shift   # the lock file (or fd)
if [ "${1:-}" = -c ]; then exec bash -c "$2"; fi
[ $# -gt 0 ] && exec "$@"
exit 0
STUB
chmod +x "$work/bin/nix-audit" "$work/bin/flock"

# run <now-rc> <next-rc>: fresh dir holding a copy of the script, stub exit codes per target
run() {
  local d="$work/run-$1-$2"; mkdir -p "$d/rc" "$d/candidate"
  echo "$1" > "$d/rc/now"; echo "$2" > "$d/rc/next"; cp "$OUTPUT" "$d/snapshot.sh"
  printf 'schema = "nix-audit-policy/v0"\n' > "$d/policy.toml"
  ( cd "$d" && PATH="$work/bin:$PATH" STUB_RC_DIR="$d/rc" NEXT_GEN="$d/candidate" AUDIT_POLICY="$d/policy.toml" \
      timeout 30 bash ./snapshot.sh >/dev/null 2>&1 ) || true
  echo "$d"
}
# usable = a JSON report of a real scan under the requested policy
valid() { [ -f "$1" ] && jq -e --arg p "$2/policy.toml" \
  '.schema == "nix-audit-report/v0" and .scan != null and .policy.source.path == $p' "$1" >/dev/null 2>&1; }

d=$(run 0 0)
valid "$d/gen-now.json" "$d" && valid "$d/gen-next.json" "$d" || { echo "FAIL: clean scans must leave two JSON snapshots of real scans (--json, --policy \$AUDIT_POLICY, stdout only, no --no-scan)"; exit 1; }
d=$(run 1 0)
valid "$d/gen-now.json" "$d" || { echo "FAIL: exit 1 (policy violations) is a valid report and must be kept"; exit 1; }
valid "$d/gen-next.json" "$d" || { echo "FAIL: exit 1 on one side must not stop the other snapshot"; exit 1; }
d=$(run 0 3)
if valid "$d/gen-next.json" "$d"; then echo "FAIL: exit 3 (incomplete) left gen-next.json looking usable"; exit 1; fi
valid "$d/gen-now.json" "$d" || { echo "FAIL: a complete current snapshot must survive the candidate's exit 3"; exit 1; }
d=$(run 3 0)
if valid "$d/gen-now.json" "$d"; then echo "FAIL: exit 3 (incomplete) left gen-now.json looking usable"; exit 1; fi
echo PASS
