{ pkgs, lib, ... }:

let
  suites = [
    { name = "hooks"; script = "bash tests/test-hooks.sh"; }
    { name = "manifests"; script = "bash tests/test-plugin-manifests.sh"; }
    { name = "policy"; script = "bash tests/test-policy.sh"; }
    { name = "contract"; script = "bash tests/test-role-contract.sh"; }
    { name = "negative"; script = "bash tests/test-coordinator-negative.sh"; }
  ];
in
{
  imports = [
    ./task-modules/herdr.nix
    ./task-modules/harness.nix
    ./task-modules/evidence.nix
    ./agents/coordinator/tasks.nix
  ];

  packages = [ pkgs.jq pkgs.yq-go pkgs.shellcheck pkgs.git pkgs.openssh ];

  tasks = lib.listToAttrs (map (s: lib.nameValuePair "skills:test:${s.name}" { exec = s.script; }) suites)
    // {
      "skills:test" = {
        description = "Every repo test suite, serially.";
        exec = "echo skills:test green";
        after = map (s: "skills:test:${s.name}") suites;
      };
    };
}
