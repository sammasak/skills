# harness:* tasks: what an agent is doing, from the harness's own session store.
{ lib, ... }:

let
  pending = name: {
    description = "epic #16 M1: not implemented yet";
    exec = "echo '{\"schema_version\":1,\"task\":\"${name}\",\"error\":{\"kind\":\"not_implemented\",\"message\":\"epic #16 M1\"}}'; exit 64";
  };
in
{
  tasks = lib.genAttrs [
    "harness:session-summary"
  ] pending;
}
