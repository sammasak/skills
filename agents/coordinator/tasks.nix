# Coordinator role DAG: composes shared tasks into work:status and coord:brief.
{ lib, ... }:

{
  tasks = lib.genAttrs [ "work:status" "coord:brief" "coord:handoff" ] (import ../../task-modules/pending.nix);
}
