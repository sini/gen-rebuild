# Guard tests for the cone-local producers-first rank (spike/topo.nix).
#
# LOAD-BEARING: V-push drains its worklist in `coneRank` order, and is byte-identical
# to a full build ONLY IF every producer is ranked before its consumers. These tests
# assert that invariant on the three rank-order shapes (chain/diamond/wide-fan) and
# cross-check the order against the whole-graph reference `(graph.condensation acc).bottomUp`.
#
# Edge convention: `edgeList` entries are { from = consumer; to = producer; } — an
# edge means `from` DEPENDS ON `to`. So a sound order has index(producer) < index(consumer),
# i.e. for each edge index(to) < index(from).
{
  lib,
  graph,
  spike,
  ...
}:
let
  # rank the full id-set of a named rank-order pin.
  ranked =
    name:
    let
      f = spike.fixtures.pin name;
    in
    spike.topo.coneRank f.accessor f.allIds;

  # index of x in a list (linear scan; lists are tiny).
  indexOf =
    xs: x:
    let
      go =
        i: rest:
        if rest == [ ] then
          -1
        else if builtins.head rest == x then
          i
        else
          go (i + 1) (builtins.tail rest);
    in
    go 0 xs;
  precedes =
    order: a: b:
    indexOf order a < indexOf order b;

  # every edge { from = consumer; to = producer; } has producer before consumer.
  producersFirst = order: edgeList: builtins.all (e: precedes order e.to e.from) edgeList;

  # condensation bottomUp restricted to the cone (here: cone == allIds), as the
  # whole-graph reference order to cross-check against.
  condOrder = name: (graph.condensation (spike.fixtures.pin name).accessor).bottomUp;

  chainPin = spike.fixtures.pin "rank-order-chain";
  diamondPin = spike.fixtures.pin "rank-order-diamond";
  wideFanPin = spike.fixtures.pin "rank-order-wide-fan";
in
{
  flake.tests.topo = {
    # rank-order-chain is a 4-chain n0<-n1<-n2<-n3 (n_i deps n_{i-1}); the producer
    # n0 ranks first, n3 last. (The task's illustrative a→b→c ⇒ [c,b,a] is the same
    # producers-first shape over this fixture's actual `n*` ids.)
    test-chain-producers-first-order = {
      expr = (ranked "rank-order-chain").order;
      expected = [
        "n0"
        "n1"
        "n2"
        "n3"
      ];
    };

    # the producer n0 (the changed node) is ranked strictly before every consumer.
    test-chain-deps-first = {
      expr = producersFirst (ranked "rank-order-chain").order chainPin.edgeList;
      expected = true;
    };

    # diamond: every edge has its producer before its consumer in `order`.
    test-diamond-deps-first = {
      expr = producersFirst (ranked "rank-order-diamond").order diamondPin.edgeList;
      expected = true;
    };

    # wide-fan: same.
    test-widefan-deps-first = {
      expr = producersFirst (ranked "rank-order-wide-fan").order wideFanPin.edgeList;
      expected = true;
    };

    # coneRank agrees with the whole-graph reference: on all three shapes, for every
    # edge the producer precedes the consumer in BOTH coneRank.order AND condensation
    # bottomUp (topological consistency — robust to tie-break differences).
    test-agrees-condensation = {
      expr =
        builtins.all
          (
            name:
            {
              coneRank = producersFirst (ranked name).order (spike.fixtures.pin name).edgeList;
              cond = producersFirst (condOrder name) (spike.fixtures.pin name).edgeList;
            } == {
              coneRank = true;
              cond = true;
            }
          )
          [
            "rank-order-chain"
            "rank-order-diamond"
            "rank-order-wide-fan"
          ];
      expected = true;
    };

    # depth sanity: chain depths are 0,1,2,3 and precompute counts every in-cone edge.
    test-chain-depth-and-precompute = {
      expr =
        let
          r = ranked "rank-order-chain";
        in
        {
          depth = r.depth;
          precompute = r.precompute;
        };
      expected = {
        depth = {
          n0 = 0;
          n1 = 1;
          n2 = 2;
          n3 = 3;
        };
        # 3 edges in the 4-chain (n1→n0, n2→n1, n3→n2), each one in-cone producer.
        precompute = 3;
      };
    };
  };
}
