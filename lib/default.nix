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
  # The surface grows here as tasks land (build, affected, dirtySet, override).
  modules = [
    ./build.nix
    ./affected.nix
    ./dirtySet.nix
    ./override.nix
  ];
in
lib.foldl' (acc: m: acc // import m args) { } modules
