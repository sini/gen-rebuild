{ genRebuild, graph, ... }:
let
  inherit (genRebuild) build affected impactOf;

  # chain: a->b->c->d (edges a=["b"], …) — a depends on b depends on c depends on d.
  ctx = build {
    accessor = graph.fixtures.chain;
    recompute =
      _acc: _s: id:
      id;
    hashOf = builtins.toString;
  };
in
{
  flake.tests.affected = {
    # dependent cone of the leaf "d" = everyone who transitively depends on it.
    test-affected-chain-d = {
      expr = builtins.sort builtins.lessThan (affected ctx "d");
      expected = [
        "a"
        "b"
        "c"
      ];
    };
    # re-export of graph.dependentsOf over the ctx's accessor.
    test-affected-eq-dependentsOf = {
      expr = affected ctx "d";
      expected = graph.dependentsOf ctx.accessor "d";
    };
    # nothing depends on the root "a".
    test-affected-root = {
      expr = affected ctx "a";
      expected = [ ];
    };
    # impactOf is an alias for affected.
    test-impactOf-alias = {
      expr = impactOf ctx "d";
      expected = affected ctx "d";
    };
  };
}
