{
  lib,
  genRebuild,
  graph,
  ...
}:
let
  inherit (genRebuild) build runScc;

  # --- Fixture 1: genuine-join reachability SCC (Arntzenius Lemma-4 ascent) ---
  # 2-node cycle a<->b. Per-node lattice = powerset of {a,b} under union.
  # reachable-from m = {m} U reachable-from-dep. ⊥={} ⊑ {self} ⊑ {a,b} = lfp.
  reachAccessor = graph.mkGraph {
    edges = [
      {
        from = "a";
        to = "b";
      }
      {
        from = "b";
        to = "a";
      }
    ];
    nodeData = {
      a = { };
      b = { };
    };
  };
  setLattice = {
    bottom = [ ];
    join = x: y: lib.sort builtins.lessThan (lib.unique (x ++ y));
    eq = (a: b: a == b);
  };
  reachLattices = {
    a = setLattice;
    b = setLattice;
  };
  reachRecompute =
    a: s: m:
    lib.sort builtins.lessThan (lib.unique ([ m ] ++ s.${builtins.head (a.edges m)}));
  reachResult = runScc {
    accessor = reachAccessor;
    store = { };
    higherStrata = { };
    recompute = reachRecompute;
    scc = [
      "a"
      "b"
    ];
    lattices = reachLattices;
  };

  # --- Fixture 2: overwrite/Sloane peer-agree SCC (NOT Arntzenius) ---
  # 2-node cycle a<->b, "agree on the max". join is a NO-OP overwrite (return the
  # new value, discard prev) — this is NOT a semilattice join; it is a Sloane /
  # Magnusson-Hedin circular attribute, naive iterate-to-stabilization. There is
  # no ascent witness; only maxIter guards divergence. It stabilizes because both
  # peers compute the same max (5) and then quiesce.
  agreeAccessor = graph.mkGraph {
    edges = [
      {
        from = "a";
        to = "b";
      }
      {
        from = "b";
        to = "a";
      }
    ];
    nodeData = {
      a = {
        self = 5;
      };
      b = {
        self = 3;
      };
    };
  };
  overwriteLattice = {
    bottom = 0;
    join = _prev: v: v; # OVERWRITE: a no-op "join", not a semilattice join.
    eq = (a: b: a == b);
  };
  agreeLattices = {
    a = overwriteLattice;
    b = overwriteLattice;
  };
  agreeRecompute =
    a: s: m:
    let
      dep = builtins.head (a.edges m);
    in
    lib.max (a.nodeData m).self s.${dep};
  agreeResult = runScc {
    accessor = agreeAccessor;
    store = { };
    higherStrata = { };
    recompute = agreeRecompute;
    scc = [
      "a"
      "b"
    ];
    lattices = agreeLattices;
  };

  # --- Fixture 3: divergence -> located blame, tryEval false ---
  # 1-member self-loop x->x, recompute x = s.x + 1 (strictly increasing, never
  # quiesces under overwrite). maxIter = 5 caps it; runScc must throw a catchable
  # blame (never Nix infinite recursion).
  divergeAccessor = graph.mkGraph {
    edges = [
      {
        from = "x";
        to = "x";
      }
    ];
    nodeData = {
      x = { };
    };
  };
  divergeLattices = {
    x = {
      bottom = 0;
      join = _: v: v;
      eq = (a: b: a == b);
      maxIter = 5;
    };
  };
  divergeRecompute =
    _a: s: _m:
    s.x + 1;
  divergeRun = runScc {
    accessor = divergeAccessor;
    store = { };
    higherStrata = { };
    recompute = divergeRecompute;
    scc = [ "x" ];
    lattices = divergeLattices;
  };

  # --- Fixture 4: per-member eq is read per node ---
  # 2-member SCC p<->q. p uses default `==`. q uses a custom eq that treats two
  # values equal when they agree mod 10. recompute drives p to 7 and q to 23.
  # q's true iterate would oscillate 13 -> 23 (both ≡ 3 mod 10), so q quiesces
  # ONLY because its OWN eq (mod-10) declares 13 and 23 equal. If a single
  # whole-SCC eq or whole-attrset == drove quiescence, q would never settle and
  # this would diverge. Proves lattices.${m}.eq is read per node.
  perMemberAccessor = graph.mkGraph {
    edges = [
      {
        from = "p";
        to = "q";
      }
      {
        from = "q";
        to = "p";
      }
    ];
    nodeData = {
      p = { };
      q = { };
    };
  };
  perMemberLattices = {
    # p: ordinary overwrite + default ==. Reaches 7 and stays.
    p = {
      bottom = 0;
      join = _: v: v;
      eq = (a: b: a == b);
    };
    # q: overwrite, but eq is mod-10 congruence. 13 and 23 are eq under it.
    q = {
      bottom = 0;
      join = _: v: v;
      eq = (a: b: lib.mod a 10 == lib.mod b 10);
    };
  };
  # p -> 7 (constant). q: bottom 0 -> reads p (0) +13 = 13 -> reads p (7) +13 = 20?
  # Make it deterministic: q = p_dep + 13. Iteration: prev q from ⊥ chain.
  # iter0 seed: p=0,q=0. iter1: p=7, q = p_prev(0)+13 = 13. iter2: p=7 (eq, settled),
  # q = p_prev(7)+13 = 20. iter3: q = 20 (p stable) ... 20 vs 20 default-eq, but the
  # interesting witness is q reaching a value that under mod-10 == its successor.
  # To exercise mod-10 eq, drive q to oscillate between 13 and 23:
  #   q = if q_prev == 13 then 23 else 13. Under default == this never quiesces;
  #   under mod-10 eq, 13 ≡ 23 (mod 10 = 3) so q quiesces at iter where prev=13,next=23.
  perMemberRecompute =
    _a: s: m:
    if m == "p" then
      7
    else
      # q oscillates 13 <-> 23; quiesces only under q's own mod-10 eq.
      (if s.q == 13 then 23 else 13);
  perMemberResult = runScc {
    accessor = perMemberAccessor;
    store = { };
    higherStrata = { };
    recompute = perMemberRecompute;
    scc = [
      "p"
      "q"
    ];
    lattices = perMemberLattices;
  };
in
{
  flake.tests.restabilize = {
    # --- Fixture 1: Arntzenius Lemma-4 genuine-join reachability lfp ---
    test-reach-a = {
      expr = reachResult.a;
      expected = [
        "a"
        "b"
      ];
    };
    test-reach-b = {
      expr = reachResult.b;
      expected = [
        "a"
        "b"
      ];
    };

    # --- Fixture 2: Sloane peer-agree overwrite stabilization ---
    test-agree-a = {
      expr = agreeResult.a;
      expected = 5;
    };
    test-agree-b = {
      expr = agreeResult.b;
      expected = 5;
    };

    # --- Fixture 3: divergence throws a catchable located blame ---
    test-diverge-catchable = {
      expr = (builtins.tryEval (builtins.deepSeq divergeRun true)).success;
      expected = false;
    };

    # --- Fixture 4: per-member eq drives quiescence (q's mod-10 eq) ---
    # q settles at 23 (its prev was 13; mod-10 eq declares them equal -> quiesce).
    test-per-member-q-settles = {
      expr = perMemberResult.q;
      expected = 23;
    };
    test-per-member-p-settles = {
      expr = perMemberResult.p;
      expected = 7;
    };
  };
}
