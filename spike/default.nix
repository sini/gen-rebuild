{
  lib,
  graph,
  genRebuild,
}:
let
  # spike modules added by later tasks: instrument, topo, revadj, baseline, vpush, vsummary
  fixtures = import ./fixtures.nix { inherit lib graph genRebuild; };
in
{
  inherit fixtures;
}
