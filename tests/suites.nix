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
  };
}
