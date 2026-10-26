# herdr:* tasks: live pane state over the installed herdr CLI (local or ssh <host> herdr ...).
{ lib, ... }:

let
  pending = name: {
    description = "epic #16 M1: not implemented yet";
    exec = "echo '{\"schema_version\":1,\"task\":\"${name}\",\"error\":{\"kind\":\"not_implemented\",\"message\":\"epic #16 M1\"}}'; exit 64";
  };
in
{
  tasks = lib.genAttrs [
    "herdr:inventory"
    "herdr:inspect"
    "herdr:message"
    "herdr:await"
  ] pending;
}
