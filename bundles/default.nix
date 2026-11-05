# Agent skill bundles (skills#63) for a consumer that pins this repository as a flake = false
# input, e.g. nixos-config's `inputs.skills`:
#   (import "${inputs.skills}/bundles" { inherit pkgs; src = inputs.skills; rev = inputs.skills.rev; }).bundle {
#     role = "quality"; harness = "claude-code"; skills = [ "rust-engineering" "nix-flake-development" ]; }
# A bad name, role or harness fails the build with build.sh's JSON error line.
{ pkgs, src, rev }:
{
  bundle =
    { role, harness, skills }:
    pkgs.runCommand "agent-skill-bundle-${role}-${harness}"
      { nativeBuildInputs = [ pkgs.bash pkgs.coreutils pkgs.findutils pkgs.gnugrep pkgs.jq pkgs.yq-go ]; }
      ''
        bash ${./build.sh} --src ${src} --rev ${pkgs.lib.escapeShellArg rev} --role ${pkgs.lib.escapeShellArg role} --harness ${pkgs.lib.escapeShellArg harness} \
          ${pkgs.lib.concatMapStringsSep " " (s: "--skill ${pkgs.lib.escapeShellArg s}") skills} --out "$TMPDIR/bundle"
        cp -a "$TMPDIR/bundle" "$out"
      '';
}
