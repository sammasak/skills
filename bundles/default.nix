# Agent skill bundles (skills#63) for a consumer that pins this repository as a flake = false
# input, e.g. nixos-config's `inputs.skills`:
#   (import "${inputs.skills}/bundles" { inherit pkgs; src = inputs.skills; rev = inputs.skills.rev; }).bundle {
#     role = "quality"; harness = "claude-code"; skills = [ "rust-engineering" "nix-flake-development" ]; }
# A bad name, role or harness fails the build with build.sh's JSON error line.
# The role's declared read and run tasks are evaluated from task-modules/ and agents/<role>/*.nix (the
# same modules devenv imports) and ship as tasks/<name>; `taskConfig` is one extra module for their
# `coordinator.*` options (a test passes its fake's variables through), never task code.
{ pkgs, src, rev }:
let
  lib = pkgs.lib;
  # what devenv provides to these modules, reduced to what they read: a tasks attrset and packages
  stub = {
    options.tasks = lib.mkOption { type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything); default = { }; };
    options.packages = lib.mkOption { type = lib.types.listOf lib.types.package; default = [ ]; };
  };
  taskModules = map (f: src + "/task-modules/${f}.nix") [ "common" "herdr" "locks" "gh" "harness" "evidence" ];
  roleModules =
    role:
    let
      dir = src + "/agents/${role}";
      files = if builtins.pathExists dir then lib.attrNames (builtins.readDir dir) else [ ];
    in
    map (f: dir + "/${f}") (lib.filter (f: lib.hasSuffix ".nix" f && f != "tests.nix") files);
  # the task scripts run with these on PATH ahead of the caller's; herdr, gh and devenv stay the caller's
  # devenv: "When no suffix is given the default is `@ready` for processes and `@succeeded` for oneshot tasks"
  # (https://devenv.sh/tasks/); only `@completed` lets a failure through, so every other edge blocks
  name = a: lib.head (lib.splitString "@" a);
  blockingEdges = after: map name (lib.filter (a: !lib.hasSuffix "@completed" a) after);
  runtime = lib.makeBinPath (with pkgs; [ bash coreutils findutils gnugrep gnused gawk jq git util-linux procps inetutils ]);
  tasksDir =
    role: taskConfig:
    let
      tasks =
        (lib.evalModules {
          specialArgs = { inherit pkgs; };
          modules = [
            stub
            # the state dir follows the instance's HOME at run time, not the builder's
            { coordinator.stateDir = lib.mkDefault "\${HOME}/.local/state/coordinator"; }
            taskConfig
          ] ++ taskModules ++ roleModules role;
        }).config.tasks;
      runnable = lib.filterAttrs (_: t: (t.exec or null) != null) tasks;
      # devenv merges a task's `input` defaults into DEVENV_TASK_INPUT, so bundle-run must too; an `after` edge keeps its
      # mode (a blocking edge must not run past a failed dependency)
      index = lib.mapAttrs (_: t: {
        after = map name (t.after or [ ]);
        afterSucceeded = blockingEdges (t.after or [ ]);
        input = t.input or { };
      }) runnable;
    in
    pkgs.runCommand "agent-skill-bundle-tasks-${role}" { passAsFile = [ "index" ]; index = builtins.toJSON index; } (
      ''
        mkdir -p "$out"
        cp "$indexPath" "$out/index.json"
      ''
      + lib.concatStrings (
        lib.mapAttrsToList (name: t: ''
          cp ${pkgs.writeText "task-${lib.replaceStrings [ ":" ] [ "-" ] name}" ''
            #!${pkgs.bash}/bin/bash
            export PATH=${runtime}''${PATH:+:$PATH}
            ${t.exec}
          ''} "$out/"${lib.escapeShellArg name}
          chmod 755 "$out/"${lib.escapeShellArg name}
        '') runnable
      )
    );
in
{
  inherit blockingEdges;
  bundle =
    { role, harness, skills, taskConfig ? { } }:
    pkgs.runCommand "agent-skill-bundle-${role}-${harness}"
      { nativeBuildInputs = [ pkgs.bash pkgs.coreutils pkgs.findutils pkgs.gnugrep pkgs.jq pkgs.yq-go ]; }
      ''
        bash ${./build.sh} --src ${src} --rev ${lib.escapeShellArg rev} --role ${lib.escapeShellArg role} --harness ${lib.escapeShellArg harness} \
          ${lib.concatMapStringsSep " " (s: "--skill ${lib.escapeShellArg s}") skills} --tasks ${tasksDir role taskConfig} --runtime ${lib.escapeShellArg runtime} --out "$TMPDIR/bundle"
        cp -a "$TMPDIR/bundle" "$out"
      '';
}
