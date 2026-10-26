# harness:* tasks: what an agent is doing, from the harness's own session store.
{ lib, ... }:

{
  tasks = lib.genAttrs [ "harness:session-summary" ] (import ./pending.nix);
}
