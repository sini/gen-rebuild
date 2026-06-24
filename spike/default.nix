{
  lib,
  graph,
  genRebuild,
}:
let
  # spike modules added by later tasks: vpush, vsummary
  fixtures = import ./fixtures.nix { inherit lib graph genRebuild; };
  topo = import ./topo.nix { inherit lib graph; };
  revadj = import ./revadj.nix { inherit lib graph; };
  instrument = import ./instrument.nix { inherit lib graph genRebuild; };
  # vpush exposes the FUNCTION `ctx: changes: { store; settled; metrics; }`.
  vpush =
    (import ./vpush.nix {
      inherit
        lib
        graph
        genRebuild
        topo
        revadj
        instrument
        ;
    }).vpush;
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
  # vsummary exposes the FUNCTION `ctx: changes: { store; metrics; }`.
  vsummary =
    (import ./vsummary.nix {
      inherit
        lib
        graph
        genRebuild
        instrument
        ;
    }).vsummary;
in
{
  inherit
    fixtures
    topo
    revadj
    instrument
    vpush
    baseline
    vsummary
    ;
}
