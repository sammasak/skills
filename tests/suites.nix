# Repo-level suites as devenv tasks. hooks and manifests wrap the pre-existing scripts of the hook framework.
{ config, lib, ... }:
{
  tasks = {
    "skills:test:policy" = {
      description = "No owner-stand-in language anywhere in skills, agents or docs";
      exec = ''
        # Policy gate: nothing an agent reads may let it stand in for the owner on
        # privileged decisions (epic #16 M0). Run: bash tests/test-policy.sh
        set +e -uo pipefail   # the task runner enables errexit; these suites inspect exit codes themselves
        ROOT="$DEVENV_ROOT"
        cd "$ROOT" || exit 1
        FAIL=0

        while IFS= read -r f; do
          if grep -nEi '\bstand(s|ing)?[- ]in\b|\bstood in\b|\bstand[- ]ins\b|acting for the owner' "$f"; then
            echo "FAIL: $f contains owner stand-in language" >&2; FAIL=1
          fi
        done < <(find global-context.md README.md skills agents docs -type f -not -path 'docs/plans/*' -not -path '*/.archived/*')

        if ! grep -qEi 'may not approve|cannot approve|AI review is evidence' "$ROOT/global-context.md"; then
          echo "FAIL: global-context.md does not state that agents cannot approve privileged actions" >&2; FAIL=1
        fi

        [ "$FAIL" -eq 0 ] && echo "PASS: policy gate" || exit 1
      '';
    };
    "skills:test:contract" = {
      description = "ROLE.md <-> adapters <-> tasks agreement for every role";
      exec = ''
        # Contract test: every role's ROLE.md frontmatter and its Claude adapter agree, and every
        # named skill/task exists (needs yq-go, jq).
        set +e -uo pipefail   # the task runner enables errexit; these suites inspect exit codes themselves
        ROOT="$DEVENV_ROOT"
        cd "$ROOT" || exit 1
        FAIL=0; PASS=0
        ok() { PASS=$((PASS+1)); }
        bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }

        TASKS="$(devenv tasks list 2>/dev/null | grep -oE '[a-z0-9_-]+(:[a-z0-9_-]+)+' | sort -u)"
        [ -n "$TASKS" ] || { echo "FAIL: devenv tasks list returned nothing"; exit 1; }

        for role_md in agents/*/ROLE.md; do
          dir="$(dirname "$role_md")"; role="$(basename "$dir")"
          fm="$(yq --front-matter=extract -o=json '.' "$role_md")" || { bad "$role: frontmatter not parseable"; continue; }
          [ "$(jq -r .name <<<"$fm")" = "$role" ] && ok || bad "$role: name != directory"
          [ "$(jq -r .version <<<"$fm")" = "1" ] && ok || bad "$role: version must be 1"
          jq -e '(.tasks.read | type == "array" and length > 0) and (.tasks.act | type == "array") and (.skills | type == "array" and length > 0)' <<<"$fm" >/dev/null && ok || bad "$role: tasks.read, tasks.act and skills must be lists"
          jq -e '.tasks.inputless | type == "array" and length > 0' <<<"$fm" >/dev/null && ok || bad "$role: tasks.inputless must be a non-empty list"

          for s in $(jq -r '.skills[]' <<<"$fm"); do
            [ -f "skills/$s/SKILL.md" ] && ok || bad "$role: skill $s missing"
          done
          for t in $(jq -r '.tasks.read[], (.tasks.run // [])[], .tasks.act[]' <<<"$fm"); do
            grep -qxF "$t" <<<"$TASKS" && ok || bad "$role: task $t not in devenv tasks list"
          done
          [ "$(jq '.forbidden|length' <<<"$fm")" -ge 5 ] && ok || bad "$role: forbidden list too short"

          for t in $(jq -r '.tasks.inputless[]?' <<<"$fm"); do
            jq -e --arg t "$t" '.tasks.read | index($t)' <<<"$fm" >/dev/null && ok || bad "$role: inputless task $t is not a read task"
          done

          for adapter in $(jq -r '.adapters[]' <<<"$fm"); do
            case "$adapter" in
              claude)
                f="agents/$role.md"; [ -f "$f" ] || { bad "$role: claude adapter $f missing"; continue; }
                afm="$(yq --front-matter=extract -o=json '.' "$f")"
                [ "$(jq -r .name <<<"$afm")" = "$role" ] && ok || bad "$role: claude adapter name mismatch"
                grep -q "ROLE.md" "$f" && ok || bad "$role: claude adapter does not point at ROLE.md"
                for s in $(jq -r '.skills[]' <<<"$fm"); do jq -e --arg s "$s" '.skills|index($s)' <<<"$afm" >/dev/null && ok || bad "$role: claude adapter does not preload $s"; done
                jq -e '[.tools[]] - ["Bash","Read"] | length == 0' <<<"$afm" >/dev/null && ok || bad "$role: claude adapter tools must be within Bash, Read"
                jq -e '.hooks == null' <<<"$afm" >/dev/null && ok || bad "$role: claude adapter must not wire hooks (the owner's permission prompt is the gate)"
                jq -e '.permissionMode == "default"' <<<"$afm" >/dev/null && ok || bad "$role: claude adapter must keep permissionMode default (prompts)"
                ;;
              *) bad "$role: unknown adapter $adapter" ;;
            esac
          done
        done

        echo "passed=$PASS failed=$FAIL"; [ "$FAIL" -eq 0 ]
      '';
    };
  };
}
