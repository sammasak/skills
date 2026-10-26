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
cat > "$work/bin/nix-audit" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  --version) echo "nix-audit 0.1.0 (a1b2c3d4e5f6)"; exit 0 ;;
  scan) ;;
  *) echo "stub: unexpected subcommand $1" >&2; exit 2 ;;
esac
shift
for a in "$@"; do
  case "$a" in
    --help|-h) printf 'Usage: nix-audit scan [OPTIONS] <TARGET>\n  --json\n  --policy <FILE>\n  --scanners <LIST>\n  --no-scan\n  --offline\n'; exit 0 ;;
    --json-out*) echo "error: unexpected argument '--json-out' found" >&2; exit 2 ;;
  esac
done
target=""; for a in "$@"; do case "$a" in /run/current-system|"$NEXT_GEN") target=$a ;; esac; done
[ -n "$target" ] || { echo "stub: no target" >&2; exit 2; }
side=next; [ "$target" = /run/current-system ] && side=now
rc=$(cat "$STUB_RC_DIR/$side")
echo "nix-audit: diagnostics on stderr" >&2
printf '{"schema":"nix-audit-report/v0","target":"%s"}\n' "$target"
[ "$rc" = 3 ] && echo "nix-audit: scan incomplete — vulnix failed" >&2
exit "$rc"
STUB
chmod +x "$work/bin/nix-audit"

# run <now-rc> <next-rc>: fresh dir, stub exit codes per target, run the script
run() {
  local d="$work/run-$1-$2"; mkdir -p "$d/rc"
  echo "$1" > "$d/rc/now"; echo "$2" > "$d/rc/next"; mkdir -p "$d/candidate"
  printf 'schema = "nix-audit-policy/v0"\n' > "$d/policy.toml"
  ( cd "$d" && PATH="$work/bin:$PATH" STUB_RC_DIR="$d/rc" NEXT_GEN="$d/candidate" AUDIT_POLICY="$d/policy.toml" \
      timeout 30 bash "$OUTPUT" >/dev/null 2>&1 ) || true
  echo "$d"
}
valid() { [ -f "$1" ] && jq -e '.schema == "nix-audit-report/v0"' "$1" >/dev/null 2>&1; }

d=$(run 0 0)
valid "$d/gen-now.json" && valid "$d/gen-next.json" || { echo "FAIL: clean scans must leave two valid JSON snapshots (stdout only)"; exit 1; }
d=$(run 1 0)
valid "$d/gen-now.json" || { echo "FAIL: exit 1 (policy violations) is a valid report and must be kept"; exit 1; }
valid "$d/gen-next.json" || { echo "FAIL: exit 1 on one side must not stop the other snapshot"; exit 1; }
d=$(run 0 3)
if valid "$d/gen-next.json"; then echo "FAIL: exit 3 (incomplete) left gen-next.json looking usable"; exit 1; fi
valid "$d/gen-now.json" || { echo "FAIL: a complete current snapshot must survive the candidate's exit 3"; exit 1; }
echo PASS
