{
  lib,
  graph,
  genRebuild,
}:
let
  # spike modules added by later tasks: topo, revadj, vpush, vsummary
  fixtures = import ./fixtures.nix { inherit lib graph genRebuild; };
  instrument = import ./instrument.nix { inherit lib graph genRebuild; };
  # baseline exposes the FUNCTION `ctx: changes: { store; metrics; }`.
  baseline =
    (import ./baseline.nix {
      inherit
        lib
        graph
        genRebuild
        instrument
        ;
    }).baseline;
in
{
  inherit fixtures instrument baseline;
}
