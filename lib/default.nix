{
  lib,
  graph,
  scope,
}:
let
  args = { inherit lib graph scope; };
  # Per-concern modules; one file = one concern. Merged left-to-right with //.
  # The surface grows here as tasks land (build, affected, dirtySet, override).
  modules = [
    ./build.nix
    ./affected.nix
  ];
in
lib.foldl' (acc: m: acc // import m args) { } modules
