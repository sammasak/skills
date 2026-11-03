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
      description = "ROLE.md <-> adapters (Claude, Codex) <-> tasks agreement and adapter parity for every role";
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

          for s in $(jq -r '.skills[]' <<<"$fm"); do
            [ -f "skills/$s/SKILL.md" ] && ok || bad "$role: skill $s missing"
          done
          for t in $(jq -r '.tasks.read[], (.tasks.run // [])[], .tasks.act[]' <<<"$fm"); do
            grep -qxF "$t" <<<"$TASKS" && ok || bad "$role: task $t not in devenv tasks list"
          done
          [ "$(jq '.forbidden|length' <<<"$fm")" -ge 5 ] && ok || bad "$role: forbidden list too short"

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
              codex)
                # Codex loads agents/<role>/codex.toml directly (agents_dir format: name, description, developer_instructions);
                # the instructions are plain text that point at the one ROLE.md, never a shell command
                f="agents/$role/codex.toml"; [ -f "$f" ] || { bad "$role: codex adapter $f missing"; continue; }
                cfm="$(yq -p toml -o json '.' "$f" 2>/dev/null)" || { bad "$role: codex adapter is not valid TOML"; continue; }
                [ "$(jq -r .name <<<"$cfm")" = "$role" ] && ok || bad "$role: codex adapter name must be $role"
                [ -n "$(jq -r '.description // ""' <<<"$cfm" | tr -d ' ')" ] && [ -n "$(jq -r '.developer_instructions // ""' <<<"$cfm" | tr -d ' \n')" ] && ok || bad "$role: codex adapter needs description and developer_instructions"
                di=$(jq -r '.developer_instructions // ""' <<<"$cfm")
                grep -q "agents/$role/ROLE.md" <<<"$di" && ok || bad "$role: codex instructions do not point at agents/$role/ROLE.md"
                for s in $(jq -r '.skills[]' <<<"$fm"); do grep -q "skills/$s/SKILL.md" <<<"$di" && ok || bad "$role: codex instructions do not name skill $s to read"; done
                ! grep -qE '\$\(|`[^`]*\bcat\b|codex exec|^\s*cat ' <<<"$di" && ok || bad "$role: codex instructions must not embed a shell command"
                [ "$(jq 'keys - ["name","description","developer_instructions"] | length' <<<"$cfm")" = 0 ] && ok || bad "$role: codex adapter has keys outside the agents_dir format"
                ;;
              *) bad "$role: unknown adapter $adapter" ;;
            esac
          done
          # adapter parity: every adapter points at the same ROLE.md, and any task name an adapter mentions is in the contract
          # (so neither adapter can widen or narrow the task list on its own)
          allowed=$(jq -r '[.tasks.read[], (.tasks.run // [])[], .tasks.act[]] | .[]' <<<"$fm")
          for f in "agents/$role.md" "agents/$role/codex.toml"; do
            [ -f "$f" ] || continue
            grep -q "agents/$role/ROLE.md" "$f" && ok || bad "$role: $f does not name agents/$role/ROLE.md"
            stray=$(grep -oE '\b(coord|gh|herdr|work|harness|git|quality):[a-z][a-z-]*' "$f" | sort -u | grep -vxF -f <(printf '%s\n' "$allowed") || true)
            [ -z "$stray" ] && ok || bad "$role: $f names tasks outside the contract: $(tr '\n' ' ' <<<"$stray")"
          done
          # autonomy parity: a role whose ROLE.md carries an Autonomy block has it byte-identical in every adapter,
          # so Claude and Codex sessions start from the same default; the coordinator must have one
          block() { awk '/^BEGIN autonomy/{f=1} f{print} /^END autonomy/{f=0}'; }
          canon=$(block < "$role_md")
          if [ "$role" = coordinator ]; then
            [ -n "$canon" ] && ok || bad "$role: ROLE.md has no BEGIN/END autonomy block"
            for rule in "Never authorize yourself" "ends that item, not the session" "exactly /clear" "Escalate only owner decisions" "never two handoffs for one item" "Nothing continues after this session ends"; do
              grep -qF "$rule" <<<"$canon" && ok || bad "$role: autonomy block lost the rule: $rule"
            done
            for boundary in "merging pull requests" "approving anything on the owner's behalf" "editing, writing or generating code"; do
              jq -e --arg b "$boundary" '[.forbidden[] | contains($b)] | any' <<<"$fm" >/dev/null && ok || bad "$role: forbidden lost: $boundary"
            done
          fi
          if [ -n "$canon" ]; then
            [ "$(block < "agents/$role.md")" = "$canon" ] && ok || bad "$role: claude adapter autonomy block differs from ROLE.md"
            if [ -f "agents/$role/codex.toml" ]; then
              [ "$(yq -p toml -o json '.' "agents/$role/codex.toml" | jq -r .developer_instructions | block)" = "$canon" ] && ok || bad "$role: codex adapter autonomy block differs from ROLE.md"
            fi
          fi
        done

        echo "passed=$PASS failed=$FAIL"; [ "$FAIL" -eq 0 ]
      '';
    };
  };
}
