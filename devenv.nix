{ pkgs, lib, ... }:

let
  taskSuites = [ "evidence" "harness-session-summary" "herdr-inspect" "herdr-inventory" "herdr-message-await" "coord-brief" "coord-handoff" "quality" ];
in
{
  imports = [
    ./task-modules/fixtures/fakes.nix
    ./task-modules/herdr.nix
    ./task-modules/harness.nix
    ./task-modules/evidence.nix
    ./task-modules/guard.nix
    ./task-modules/tests.nix
    ./agents/coordinator/tasks.nix
    ./agents/coordinator/tests.nix
    ./agents/quality/tasks.nix
    ./agents/quality/tests.nix
    ./tests/suites.nix
  ];

  packages = [ pkgs.yq-go pkgs.shellcheck pkgs.git pkgs.openssh pkgs.fish ];

  tasks = {
    # the two pre-existing hook-framework suites keep their scripts; everything the roles added is a task
    "skills:test:hooks".exec = "bash tests/test-hooks.sh";
    "skills:test:manifests".exec = "bash tests/test-plugin-manifests.sh";
    "skills:test:tasks" = {
      description = "Aggregator for the per-module fixture suites.";
      exec = "echo skills:test:tasks green";
      after = map (n: "skills:test:tasks:${n}") taskSuites;
    };
    "skills:test" = {
      description = "Every repo test suite.";
      exec = "echo skills:test green";
      after = [ "skills:test:hooks" "skills:test:manifests" "skills:test:policy" "skills:test:contract" "skills:test:negative" "skills:test:tasks" ];
    };
  };
}
