# gen-rebuild = the rebuilder dimension (Mokhov 2018) over change propagation
# (Acar 2002) + the AFFECTED set (Reps–Teitelbaum–Demers 1983) + reverse-
# reachability (Arntzenius 2016 Datafun).
{
  lib,
  graph,
  # `scope` (gen-scope) is threaded but unused in v1 — reserved for the v2 S1
  # warm-cache eval seam, when `recompute` is wired to gen-scope's evaluator
  # instead of v1's own thin store-backed lib.fix loop.
  scope,
}:
let
  args = { inherit lib graph scope; };
  # Per-concern modules; one file = one concern. Merged left-to-right with //.
  # The surface grows here as tasks land. drivers.nix is positioned after
  # override.nix so the fused `override` definition wins (drivers.override
  # shadows override.nix:override via the //-fold).
  modules = [
    ./build.nix
    ./affected.nix
    ./dirtySet.nix
    ./override.nix
    ./strategies.nix
    ./affectedSet.nix
    ./provenance.nix
    ./drivers.nix
    ./structural.nix
    ./restabilize.nix
  ];
in
lib.foldl' (acc: m: acc // import m args) { } modules
