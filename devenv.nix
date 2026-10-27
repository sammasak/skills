{ pkgs, lib, ... }:

let
  taskSuites = [ "evidence" "harness-session-summary" "herdr-inspect" "herdr-inventory" "herdr-message-await" "coord-brief" "coord-handoff" "quality" ];
in
{
  imports = [
    ./task-modules/common.nix
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
    "skills:herdr-skill-sync" = {
      description = "Refresh skills/herdr/SKILL.md from the installed `herdr --skill` (Herdr's own skill, vendored verbatim).";
      exec = ''
        type -P herdr >/dev/null || { echo "herdr is not installed here; nothing to sync" >&2; exit 1; }
        tmp=$(mktemp); herdr --skill > "$tmp" && mv "$tmp" skills/herdr/SKILL.md && echo "skills/herdr/SKILL.md <- $(herdr --version)"
      '';
    };
    "skills:test:herdr-skill" = {
      description = "skills/herdr/SKILL.md equals the installed `herdr --skill` byte for byte (no herdr = fail, not pass).";
      exec = ''
        type -P herdr >/dev/null || { echo "FAIL: herdr is not installed here, so skills/herdr/SKILL.md cannot be verified" >&2; exit 1; }
        diff -u skills/herdr/SKILL.md <(herdr --skill) || { echo "FAIL: skills/herdr/SKILL.md differs from $(herdr --version); run: devenv tasks run skills:herdr-skill-sync" >&2; exit 1; }
        echo "skills/herdr/SKILL.md matches $(herdr --version)"
      '';
    };
    "skills:test" = {
      description = "Every repo test suite.";
      exec = "echo skills:test green";
      after = [ "skills:test:hooks" "skills:test:manifests" "skills:test:policy" "skills:test:contract" "skills:test:negative" "skills:test:tasks" "skills:test:herdr-skill" ];
    };
  };
}
