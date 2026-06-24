# spike/fixtures.nix — the v3 minimality fixture corpus.
#
# WHY THIS FILE EXISTS (the spike's central risk): the minimality spike measures
# whether incremental rebuild can do SUB-CONE work. The decisive fixtures need a
# recompute that can CUT OFF — a downstream node recomputes to its PRIOR value so
# propagation stops. The v1/v2 generators use the ADDITIVE recompute
# `weight + Σdeps` (ci/tests/gen.nix:78-80), which moves 100% of the cone on ANY
# change — it can NEVER cut off, so AFFECTED == cone always and there is no
# minimality to measure. This file introduces SATURATING and MODULAR recomputes
# (both READ their deps, so changes still propagate) whose values plateau / wrap,
# letting a hash collide downstream and the propagation die. The ratio guards in
# spike/ci/tests/fixtures.nix are the acceptance: they prove the cut-heavy
# fixtures hit |AFFECTED|/|cone| ≤ 0.3.
#
# Edge convention (gen-graph): an edge { from = X; to = Y; } means accessor.edges X
# contains Y — i.e. X DEPENDS ON Y (consumer→producer). So a node's cone (its
# dependents) is graph.dependentsOf, and value flows producer→consumer.
#
# FIXTURE CONTRACT — every `pin name` and `family { kind; seed; }` returns EXACTLY:
#   { accessor; accessor'; changes; changedIds; allIds; edgeList; recompute; hashOf; }
# where:
#   changes    :: { <id> = newDecls; }   — the data-change (variant calling conv.)
#   changedIds == builtins.attrNames changes
#   allIds     == accessor.nodes
#   edgeList   == [ { from; to; } ]      — kept for the rank-order tests
# The dual changes/changedIds representation is load-bearing — keep it coherent.
{
  lib,
  graph,
  genRebuild,
}:
let
  # --- recomputes (deps-reading, cutoff-capable) --------------------------
  # Raw additive accumulation: own weight + Σ dep values. Both cutoff recomputes
  # are this raw value passed through a non-injective post-map (min / mod), so two
  # distinct raws can collapse to one value ⇒ a hash collision ⇒ propagation dies.
  rawOf =
    a: s: id:
    (a.nodeData id).weight + lib.foldl' (sum: dep: sum + s.${dep}) 0 (a.edges id);

  # Saturating: min(cap, raw). Once a node's raw exceeds cap it pins to cap; a
  # later small upstream bump keeps it at cap ⇒ unmoved ⇒ cutoff.
  satRecompute =
    cap: a: s: id:
    let
      raw = rawOf a s id;
    in
    if raw > cap then cap else raw;

  # Modular: raw mod k. raw and raw+k collapse to the same residue ⇒ collision.
  mod = a: b: a - b * (a / b);
  modRecompute =
    k: a: s: id:
    mod (rawOf a s id) k;

  hashOf = v: builtins.hashString "sha256" (builtins.toJSON v);

  # --- generic helpers ----------------------------------------------------
  # withChange: an accessor' that overlays new nodeData for the changed ids,
  # leaving edges (topology) identical — the data-change envelope.
  withChange =
    acc: changes:
    acc
    // {
      nodeData = id: if changes ? ${id} then changes.${id} else acc.nodeData id;
    };

  # mkFixture: fill accessor'/changedIds/allIds from the primitives. recompute and
  # edgeList are supplied per fixture; hashOf is the shared sha256-of-toJSON.
  mkFixture =
    {
      accessor,
      changes,
      recompute,
      edgeList,
    }:
    {
      inherit
        accessor
        changes
        recompute
        edgeList
        hashOf
        ;
      accessor' = withChange accessor changes;
      changedIds = builtins.attrNames changes;
      allIds = accessor.nodes;
    };

  # oracle: the from-scratch ground truth store for accessor' (build over the
  # CHANGED accessor). The minimal-rebuild store must equal this byte-for-byte.
  oracle =
    fx:
    (genRebuild.build {
      accessor = fx.accessor';
      inherit (fx) recompute hashOf;
    }).store;

  # mkChain n: a linear chain n0 <- n1 <- ... <- n(n-1) where n(i) depends on
  # n(i-1) (edge { from = n(i); to = n(i-1); }). Value flows n0 → ... → n(n-1).
  nameOf = i: "n${toString i}";
  chainEdges =
    n:
    map (i: {
      from = nameOf i;
      to = nameOf (i - 1);
    }) (lib.range 1 (n - 1));
  uniformWeights = ids: w: lib.listToAttrs (map (id: lib.nameValuePair id { weight = w; }) ids);

  # --- LCG (mirrors ci/tests/gen.nix): pure deterministic pseudo-random. ----
  # 64-bit safe: lcg output < 2^31, salts small, so 1103515245·input < 9.2e18.
  lcg = s: mod (1103515245 * s + 12345) 2147483648;
  rnd =
    seed: i: j:
    lcg (lcg (lcg (seed + 1) + i) + j);

  # ========================================================================
  # PINS — hand-built shapes (the dependents-terms shapes from the task).
  # ========================================================================
  pins = {
    # chain a→b→c: a linear 3-chain; every node moves (additive, no cutoff).
    # Uses the saturating recompute with a cap high enough that nothing saturates
    # ⇒ behaves additively ⇒ a change at the producer moves the whole chain.
    chain =
      let
        edgeList = chainEdges 3;
        accessor = graph.mkGraph {
          edges = edgeList;
          nodeData = uniformWeights [ "n0" "n1" "n2" ] 5;
        };
      in
      mkFixture {
        inherit accessor edgeList;
        recompute = satRecompute 10000;
        changes.n0 = {
          weight = 6;
        };
      };

    # diamond: fan-out then fan-in. top → {l, r} → bottom. Change top; the whole
    # diamond is in-cone and moves (high cap ⇒ additive).
    diamond =
      let
        edgeList = [
          {
            from = "l";
            to = "top";
          }
          {
            from = "r";
            to = "top";
          }
          {
            from = "bottom";
            to = "l";
          }
          {
            from = "bottom";
            to = "r";
          }
        ];
        accessor = graph.mkGraph {
          edges = edgeList;
          nodeData = uniformWeights [ "top" "l" "r" "bottom" ] 5;
        };
      in
      mkFixture {
        inherit accessor edgeList;
        recompute = satRecompute 10000;
        changes.top = {
          weight = 7;
        };
      };

    # wide-fan: one producer `hub` with many direct dependents d0..d7. Change hub;
    # the whole fan is in-cone (cone = hub + 8 leaves) and moves.
    wide-fan =
      let
        leaves = map (i: "d${toString i}") (lib.range 0 7);
        edgeList = map (d: {
          from = d;
          to = "hub";
        }) leaves;
        accessor = graph.mkGraph {
          edges = edgeList;
          nodeData = uniformWeights ([ "hub" ] ++ leaves) 5;
        };
      in
      mkFixture {
        inherit accessor edgeList;
        recompute = satRecompute 10000;
        changes.hub = {
          weight = 6;
        };
      };

    # deep-cut: a long chain whose cumulative sum SATURATES early, so a tiny bump
    # at the producer dies within a few nodes. cone = whole chain (21), AFFECTED =
    # the handful before saturation (~3) ⇒ ratio ≈ 0.14 ≤ 0.3. THE decisive pin.
    # cap=100, w=25 ⇒ n0=25,n1=50,n2=75,n3=100(sat). Bump n0 25→26 ⇒ n0,n1,n2 move,
    # n3.. stay pinned at 100.
    deep-cut =
      let
        n = 21;
        ids = map nameOf (lib.range 0 (n - 1));
        edgeList = chainEdges n;
        accessor = graph.mkGraph {
          edges = edgeList;
          nodeData = uniformWeights ids 25;
        };
      in
      mkFixture {
        inherit accessor edgeList;
        recompute = satRecompute 100;
        changes.n0 = {
          weight = 26;
        };
      };

    # collision: a single isolated leaf with the saturating recompute. The leaf is
    # already saturated (weight 30 > cap 20 ⇒ value 20); changing weight to 50
    # keeps it saturated at 20 ⇒ hash unmoved ⇒ AFFECTED = []. (`weight+Σdeps` can
    # never collide; this saturating recompute can.)
    collision =
      let
        accessor = graph.mkGraph {
          nodeData.l = {
            weight = 30;
          };
        };
      in
      mkFixture {
        inherit accessor;
        edgeList = [ ];
        recompute = satRecompute 20;
        changes.l = {
          weight = 50;
        };
      };

    # cutoff-join: the §4(B) worked instance. edges consumer→producer; recompute =
    # satRecompute 100; change A's weight 10→20.
    #   A []      10→20  : 10→20            moves (the seed)
    #   M [A]     5       min(100,15)=15 → min(100,25)=25   moves ⇒ enqueues J
    #   P [A]     95      min(100,105)=100 → min(100,115)=100   collides ⇒ CUTOFF
    #   Q [P]     3       min(100,103)=100 → 100             unmoved, never enqueued
    #   J [M,Q]   1       min(100,116)=100 → min(100,126)=100   enqueued by M
    # cone(A) = {A,M,P,Q,J}; AFFECTED = {A,M}. The point: Q is in-cone but never
    # enqueued (its only enqueuer P cut off).
    cutoff-join =
      let
        edgeList = [
          {
            from = "M";
            to = "A";
          }
          {
            from = "P";
            to = "A";
          }
          {
            from = "Q";
            to = "P";
          }
          {
            from = "J";
            to = "M";
          }
          {
            from = "J";
            to = "Q";
          }
        ];
        accessor = graph.mkGraph {
          edges = edgeList;
          nodeData = {
            A = {
              weight = 10;
            };
            M = {
              weight = 5;
            };
            P = {
              weight = 95;
            };
            Q = {
              weight = 3;
            };
            J = {
              weight = 1;
            };
          };
        };
      in
      mkFixture {
        inherit accessor edgeList;
        recompute = satRecompute 100;
        changes.A = {
          weight = 20;
        };
      };

    # tiny-cone-large-graph: a broad forest of K independent chains. Changing one
    # leaf touches only its own chain ⇒ |cone| ≪ |allIds| (cone=4 vs allIds=32).
    tiny-cone-large-graph =
      let
        k = 8;
        chainLen = 4;
        cName = c: i: "c${toString c}_${toString i}";
        cIds = c: map (cName c) (lib.range 0 (chainLen - 1));
        edgeList = lib.concatMap (
          c:
          map (i: {
            from = cName c i;
            to = cName c (i - 1);
          }) (lib.range 1 (chainLen - 1))
        ) (lib.range 0 (k - 1));
        allCIds = lib.concatMap cIds (lib.range 0 (k - 1));
        accessor = graph.mkGraph {
          edges = edgeList;
          nodeData = uniformWeights allCIds 10;
        };
      in
      mkFixture {
        inherit accessor edgeList;
        recompute = satRecompute 100000;
        changes.${cName 0 0} = {
          weight = 11;
        };
      };

    # summary-collision: two structurally-identical subtrees (L*, R*) each a 3-chain
    # feeding a shared `summary` join, differing only in a DEEP transitive weight.
    # The saturating cap pins both subtree heads to the same value, so the summary
    # collides — built HERE so Task 7's summary-aware dedup has a fixture to reach.
    # Change is the deep L-leaf L0; under cap both subtrees saturate identically.
    summary-collision =
      let
        edgeList = [
          {
            from = "L1";
            to = "L0";
          }
          {
            from = "L2";
            to = "L1";
          }
          {
            from = "R1";
            to = "R0";
          }
          {
            from = "R2";
            to = "R1";
          }
          {
            from = "summary";
            to = "L2";
          }
          {
            from = "summary";
            to = "R2";
          }
        ];
        accessor = graph.mkGraph {
          edges = edgeList;
          nodeData = uniformWeights [
            "L0"
            "L1"
            "L2"
            "R0"
            "R1"
            "R2"
            "summary"
          ] 40;
        };
      in
      mkFixture {
        inherit accessor edgeList;
        # cap=100: L0=40,L1=80,L2=100(sat). Bump L0 40→50 ⇒ L1=90,L2=100(sat,
        # unmoved) ⇒ summary unmoved. L0,L1 move; L2 and summary collide.
        recompute = satRecompute 100;
        changes.L0 = {
          weight = 50;
        };
      };

    # rank-order pins: same shapes as chain/diamond/wide-fan, reused by the
    # topo/rank-order tests of later tasks (they assert enqueue order respects the
    # producer→consumer rank). Identical construction; named distinctly so the
    # rank-order suite can pin a known edgeList.
    rank-order-chain =
      let
        edgeList = chainEdges 4;
        accessor = graph.mkGraph {
          edges = edgeList;
          nodeData = uniformWeights (map nameOf (lib.range 0 3)) 5;
        };
      in
      mkFixture {
        inherit accessor edgeList;
        recompute = satRecompute 10000;
        changes.n0 = {
          weight = 6;
        };
      };

    rank-order-diamond =
      let
        edgeList = [
          {
            from = "l";
            to = "top";
          }
          {
            from = "r";
            to = "top";
          }
          {
            from = "bottom";
            to = "l";
          }
          {
            from = "bottom";
            to = "r";
          }
        ];
        accessor = graph.mkGraph {
          edges = edgeList;
          nodeData = uniformWeights [ "top" "l" "r" "bottom" ] 5;
        };
      in
      mkFixture {
        inherit accessor edgeList;
        recompute = satRecompute 10000;
        changes.top = {
          weight = 7;
        };
      };

    rank-order-wide-fan =
      let
        leaves = map (i: "d${toString i}") (lib.range 0 4);
        edgeList = map (d: {
          from = d;
          to = "hub";
        }) leaves;
        accessor = graph.mkGraph {
          edges = edgeList;
          nodeData = uniformWeights ([ "hub" ] ++ leaves) 5;
        };
      in
      mkFixture {
        inherit accessor edgeList;
        recompute = satRecompute 10000;
        changes.hub = {
          weight = 6;
        };
      };
  };

  pin =
    name:
    pins.${name}
      or (throw "gen-rebuild spike: unknown pin '${name}' (have: ${toString (builtins.attrNames pins)})");

  # ========================================================================
  # FAMILIES — seeded LCG-randomised shapes (mirror ci/tests/gen.nix).
  # ========================================================================
  families = {
    # chain: a randomised additive chain (high cap ⇒ no cutoff); every node moves.
    chain =
      seed:
      let
        n = 4 + mod (rnd seed 0 0) 4; # 4..7
        edgeList = chainEdges n;
        weights = lib.listToAttrs (
          map (i: lib.nameValuePair (nameOf i) { weight = 1 + mod (rnd seed i 99) 100; }) (
            lib.range 0 (n - 1)
          )
        );
        accessor = graph.mkGraph {
          edges = edgeList;
          nodeData = weights;
        };
      in
      mkFixture {
        inherit accessor edgeList;
        recompute = satRecompute 1000000;
        changes.n0 = {
          weight = 1 + mod (rnd seed 13 13) 100;
        };
      };

    # wide-fan: one hub, m randomised dependents; change hub ⇒ whole fan moves.
    wide-fan =
      seed:
      let
        m = 5 + mod (rnd seed 1 1) 6; # 5..10 leaves
        leaves = map (i: "d${toString i}") (lib.range 0 (m - 1));
        edgeList = map (d: {
          from = d;
          to = "hub";
        }) leaves;
        weights = uniformWeights ([ "hub" ] ++ leaves) (1 + mod (rnd seed 2 2) 50);
        accessor = graph.mkGraph {
          edges = edgeList;
          nodeData = weights;
        };
      in
      mkFixture {
        inherit accessor edgeList;
        recompute = satRecompute 1000000;
        changes.hub = {
          weight = 1 + mod (rnd seed 3 3) 50;
        };
      };

    # deep-cut: a randomised long chain (18..25) with weights 30..50 so the
    # cumulative sum saturates at cap=100 within ~2 nodes; a small bump to n0 dies
    # early ⇒ mean ratio ≈ 0.09 ≤ 0.3. (A seeded cousin of the deep-cut pin.)
    deep-cut =
      seed:
      let
        cap = 100;
        n = 18 + mod (rnd seed 1 1) 8; # 18..25
        edgeList = chainEdges n;
        weights = lib.listToAttrs (
          map (i: lib.nameValuePair (nameOf i) { weight = 30 + mod (rnd seed i 5) 21; }) (lib.range 0 (n - 1))
        );
        accessor = graph.mkGraph {
          edges = edgeList;
          nodeData = weights;
        };
        bump = 1 + mod (rnd seed 2 2) 4;
        ow = (accessor.nodeData "n0").weight;
      in
      mkFixture {
        inherit accessor edgeList;
        recompute = satRecompute cap;
        changes.n0 = {
          weight = ow + bump;
        };
      };

    # sparse-affected: a randomised chain (16..23) with HIGH weights (40..70) so the
    # sum saturates at cap=100 within ~1-2 nodes; a tiny producer bump dies almost
    # immediately ⇒ AFFECTED is 1-2 nodes against a cone of 16-23 ⇒ mean ≈ 0.06.
    sparse-affected =
      seed:
      let
        cap = 100;
        n = 16 + mod (rnd seed 0 0) 8; # 16..23
        edgeList = chainEdges n;
        weights = lib.listToAttrs (
          map (i: lib.nameValuePair (nameOf i) { weight = 40 + mod (rnd seed i 7) 31; }) (lib.range 0 (n - 1))
        );
        accessor = graph.mkGraph {
          edges = edgeList;
          nodeData = weights;
        };
        bump = 1 + mod (rnd seed 3 3) 5;
        ow = (accessor.nodeData "n0").weight;
      in
      mkFixture {
        inherit accessor edgeList;
        recompute = satRecompute cap;
        changes.n0 = {
          weight = ow + bump;
        };
      };

    # batch-multiseed: a randomised DAG (mirrors gen.nix's edge-rule: i may depend
    # on any j<i with ~1/2 prob ⇒ acyclic) with a MULTI-id change (a batch of two
    # changed producers). Additive (high cap) so it stresses the multi-id splice.
    batch-multiseed =
      seed:
      let
        n = 6 + mod (rnd seed 0 0) 4; # 6..9
        edgeList = lib.concatMap (
          i:
          lib.concatMap (
            j:
            lib.optional (mod (rnd seed i j) 2 == 0) {
              from = nameOf i;
              to = nameOf j;
            }
          ) (lib.range 0 (i - 1))
        ) (lib.range 1 (n - 1));
        weights = lib.listToAttrs (
          map (i: lib.nameValuePair (nameOf i) { weight = 1 + mod (rnd seed i 99) 100; }) (
            lib.range 0 (n - 1)
          )
        );
        accessor = graph.mkGraph {
          edges = edgeList;
          nodeData = weights;
        };
        # two distinct changed producers (low indices ⇒ likely to have dependents).
        c0 = nameOf (mod (rnd seed 7 7) 2); # n0 or n1
        c1 = nameOf (2 + mod (rnd seed 8 8) 2); # n2 or n3
        changes = {
          ${c0} = {
            weight = 1 + mod (rnd seed 11 11) 100;
          };
          ${c1} = {
            weight = 1 + mod (rnd seed 12 12) 100;
          };
        };
      in
      mkFixture {
        inherit accessor edgeList changes;
        recompute = satRecompute 1000000;
      };

    # tiny-cone-large-graph: a randomised broad forest (K chains); change one leaf
    # in one chain ⇒ |cone| ≪ |allIds|.
    tiny-cone-large-graph =
      seed:
      let
        k = 6 + mod (rnd seed 0 0) 5; # 6..10 chains
        chainLen = 3 + mod (rnd seed 1 1) 3; # 3..5 deep
        cName = c: i: "c${toString c}_${toString i}";
        cIds = c: map (cName c) (lib.range 0 (chainLen - 1));
        edgeList = lib.concatMap (
          c:
          map (i: {
            from = cName c i;
            to = cName c (i - 1);
          }) (lib.range 1 (chainLen - 1))
        ) (lib.range 0 (k - 1));
        allCIds = lib.concatMap cIds (lib.range 0 (k - 1));
        accessor = graph.mkGraph {
          edges = edgeList;
          nodeData = uniformWeights allCIds 10;
        };
      in
      mkFixture {
        inherit accessor edgeList;
        recompute = satRecompute 1000000;
        changes.${cName 0 0} = {
          weight = 11;
        };
      };
  };

  family =
    { kind, seed }:
    (families.${kind}
      or (throw "gen-rebuild spike: unknown family kind '${kind}' (have: ${toString (builtins.attrNames families)})")
    )
      seed;
in
{
  inherit
    satRecompute
    modRecompute
    withChange
    mkFixture
    oracle
    pin
    family
    ;
}
