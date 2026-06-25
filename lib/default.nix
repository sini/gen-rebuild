# gen-rebuild = the rebuilder dimension (Mokhov 2018) over change propagation
# (Acar 2002) + the AFFECTED set (Reps–Teitelbaum–Demers 1983) + reverse-
# reachability (Arntzenius 2016 Datafun).
{
  lib,
  graph,
  # `scope` (gen-scope) is threaded for call-compatibility but UNUSED — no lib op
  # consumes it. The sketched warm-cache adapter (gen-scope `evalWarm`) was found
  # unsound (it resolved deps via its own fixpoint, not the relocatable store) and
  # never wired; cross-eval/cross-host reuse uses frozen-snapshot value-passing on
  # the deferred substrate (gen-specs/gen-rebuild/FUTURE_WORK.md), not a warm cache.
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
    ./eager.nix
    ./structural.nix
    ./restabilize.nix
  ];
in
lib.foldl' (acc: m: acc // import m args) { } modules
