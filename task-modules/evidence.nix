# gh:* and git:* tasks: durable engineering evidence.
{ lib, ... }:

{
  tasks = lib.genAttrs [ "gh:work" "git:recent" ] (import ./pending.nix);
}
