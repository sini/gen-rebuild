{
  lib,
  genRebuild,
  graph,
  ...
}:
let
  inherit (genRebuild) build dirtySet affected;

  mkCtx =
    accessor:
    build {
      inherit accessor;
      recompute =
        _a: _s: id:
        id;
      hashOf = builtins.toString;
    };
  chainCtx = mkCtx graph.fixtures.chain;
  # diamond: a->{b,c}->d (edges a=["b","c"], b=["d"], c=["d"], d=[]).
  diamondCtx = mkCtx graph.fixtures.diamond;

  sort = builtins.sort builtins.lessThan;
in
{
  flake.tests.dirtySet = {
    # single change on chain: {d} ∪ cone(d) == sort([d] ++ affected d).
    test-single-chain-d = {
      expr = sort (dirtySet chainCtx [ "d" ]);
      expected = sort ([ "d" ] ++ affected chainCtx "d");
    };
    test-single-chain-d-explicit = {
      expr = sort (dirtySet chainCtx [ "d" ]);
      expected = [
        "a"
        "b"
        "c"
        "d"
      ];
    };
    # canonical form (acceptance): deduped union of changed ids + their cones.
    test-canonical-form = {
      expr = dirtySet diamondCtx [ "d" ];
      expected = lib.unique ([ "d" ] ++ lib.concatMap (graph.dependentsOf diamondCtx.accessor) [ "d" ]);
    };
    # two-change union + dedup on diamond: cone(b)=cone(c)={a}, so a appears once.
    test-two-change-dedup = {
      expr = sort (
        dirtySet diamondCtx [
          "b"
          "c"
        ]
      );
      expected = [
        "a"
        "b"
        "c"
      ];
    };
    # result carries no duplicate ids.
    test-no-duplicates = {
      expr =
        let
          r = dirtySet diamondCtx [
            "b"
            "c"
          ];
        in
        builtins.length r == builtins.length (lib.unique r);
      expected = true;
    };
  };
}
