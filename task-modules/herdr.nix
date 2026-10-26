# herdr:* tasks: live pane state over the installed herdr CLI (local or ssh <host> herdr ...).
{ lib, ... }:

{
  tasks = lib.genAttrs [ "herdr:inventory" "herdr:inspect" "herdr:message" "herdr:await" ] (import ./pending.nix);
}
