{
  lib,
  genRebuild,
  graph,
  mkCyclicCase,
  ...
}:
let
  inherit (genRebuild)
    build
    override
    runScc
    restabilize
    ;

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

  # ==========================================================================
  # restabilize fixtures + the fixed-point-equality soundness property.
  # ==========================================================================

  # --- Property: restabilize == from-scratch fixpoint build (120 seeds) ---
  # For a random cyclic graph, restabilize(build acc) over a data-change to
  # changedId must yield the SAME store as a from-scratch build over acc' (the
  # changed topology). For the cyclic strata this is FIXED-POINT-EQUALITY: both
  # converge to the unique lfp on the finite-height overwrite lattices with the
  # same externals (Arntzenius 2016 Lemma 4); the acyclic strata are byte-
  # identical (== override). Convergence is guaranteed every seed (max-fold).
  restabSound =
    seed:
    let
      c = mkCyclicCase seed;
      ctx = build {
        accessor = c.acc;
        inherit (c) recompute hashOf;
        fixpoint = c.lattices;
      };
      r = restabilize ctx c.changedId c.newDecls;
      oracle = build {
        accessor = c.acc';
        inherit (c) recompute hashOf;
        fixpoint = c.lattices;
      };
    in
    r.store == oracle.store;
  restabFailing = builtins.filter (seed: !(restabSound seed)) (lib.range 1 120);

  # --- Fixture A: acyclic-regression — restabilize == override (byte-identical) ---
  # A hand-built acyclic chain a→b→c (c is the producer; a the top consumer).
  # restabilize over an acyclic cone reduces to the v1 override splice, so its
  # store must be byte-identical to override's. We build the restabilize ctx WITH
  # an (all-singleton) fixpoint and the override ctx WITHOUT one, change `c`, and
  # assert the two stores agree (and pin the expected store).
  acyclicChain = graph.mkGraph {
    edges = [
      {
        from = "a";
        to = "b";
      }
      {
        from = "b";
        to = "c";
      }
    ];
    nodeData = {
      a = {
        weight = 10;
      };
      b = {
        weight = 20;
      };
      c = {
        weight = 30;
      };
    };
  };
  acyclicIds = [
    "a"
    "b"
    "c"
  ];
  # node value = own weight + sum of dep values (deps from accessor.edges).
  chainRecompute =
    a: s: id:
    (a.nodeData id).weight + lib.foldl' (sum: dep: sum + s.${dep}) 0 (a.edges id);
  chainHashOf = v: builtins.hashString "sha256" (builtins.toJSON v);
  acyclicSingletonFixpoint = {
    lattices = lib.genAttrs acyclicIds (_: {
      bottom = 0;
      join = _: v: v;
      eq = (a: b: a == b);
    });
  };
  # restabilize ctx: built WITH a fixpoint (acyclic ⇒ all singleton strata).
  chainCtxFix = build {
    accessor = acyclicChain;
    recompute = chainRecompute;
    hashOf = chainHashOf;
    fixpoint = acyclicSingletonFixpoint;
  };
  # override ctx: the SAME acyclic graph built v1-style (no fixpoint key).
  chainCtxV1 = build {
    accessor = acyclicChain;
    recompute = chainRecompute;
    hashOf = chainHashOf;
  };
  chainChangedId = "c";
  chainNewDecls = {
    weight = 100;
  };
  chainRestab = restabilize chainCtxFix chainChangedId chainNewDecls;
  chainOverride = override chainCtxV1 chainChangedId chainNewDecls;
  # Pinned expected store after c := 100: c=100, b=20+100=120, a=10+120=130.
  chainExpectedStore = {
    c = 100;
    b = 120;
    a = 130;
  };

  # --- Fixture B: a built cyclic ctx, reused by the precheck/throw tests ---
  # 2-SCC {x,y} reading an acyclic producer p; an acyclic consumer c reads y.
  #   edges: x→y, y→x (the SCC); x→p (SCC reads producer); c→y (consumer reads SCC)
  mixedAccessor = graph.mkGraph {
    edges = [
      {
        from = "x";
        to = "y";
      }
      {
        from = "y";
        to = "x";
      }
      {
        from = "x";
        to = "p";
      }
      {
        from = "c";
        to = "y";
      }
    ];
    nodeData = {
      p = {
        weight = 5;
      };
      x = {
        weight = 1;
      };
      y = {
        weight = 1;
      };
      c = {
        weight = 0;
      };
    };
  };
  mixedIds = [
    "p"
    "x"
    "y"
    "c"
  ];
  # MAX-fold (monotone + bounded ⇒ always converges).
  mixedRecompute =
    a: s: id:
    lib.foldl' lib.max (a.nodeData id).weight (map (d: s.${d}) (a.edges id));
  mixedHashOf = v: builtins.hashString "sha256" (builtins.toJSON v);
  mixedFixpoint = {
    lattices = lib.genAttrs mixedIds (_: {
      bottom = 0;
      join = _: v: v;
      eq = (a: b: a == b);
    });
  };
  mixedCtx = build {
    accessor = mixedAccessor;
    recompute = mixedRecompute;
    hashOf = mixedHashOf;
    fixpoint = mixedFixpoint;
  };

  # --- Fixture C (test 3): mutate the built cyclic ctx to DROP a cyclic node's
  # lattice, triggering restabilize's OWN undeclared-cyclic-node precheck. (build
  # would reject such a fixpoint up front, so we mutate post-build.) `x` is cyclic.
  mixedCtxMissingLattice = mixedCtx // {
    fixpoint = {
      lattices = removeAttrs mixedCtx.fixpoint.lattices [ "x" ];
    };
  };

  # --- Fixture D (test 4): a v1-built ctx (NO fixpoint key) over the acyclic
  # chain ⇒ restabilize must throw "requires ctx.fixpoint". Reuses chainCtxV1.

  # --- Fixture E (test 5): mixed-strata producer change. Change p; restabilize
  # must re-solve the whole p-cone (SCC {x,y} + consumer c). Oracle = build acc'.
  mixedChangedId = "p";
  mixedNewDecls = {
    weight = 50;
  };
  mixedAccessor' = mixedAccessor // {
    nodeData = id: if id == mixedChangedId then mixedNewDecls else mixedAccessor.nodeData id;
  };
  mixedRestab = restabilize mixedCtx mixedChangedId mixedNewDecls;
  mixedOracle = build {
    accessor = mixedAccessor';
    recompute = mixedRecompute;
    hashOf = mixedHashOf;
    fixpoint = mixedFixpoint;
  };

  # --- Fixture F (test 6): chaining. restabilize ∘ restabilize stays cyclic-
  # capable (fixpoint threaded) and == oracle build over the twice-changed acc.
  chainId1 = "p";
  chainDecls1 = {
    weight = 40;
  };
  chainId2 = "x";
  chainDecls2 = {
    weight = 70;
  };
  chainDouble = restabilize (restabilize mixedCtx chainId1 chainDecls1) chainId2 chainDecls2;
  mixedAccessorDouble = mixedAccessor // {
    nodeData =
      id:
      if id == chainId2 then
        chainDecls2
      else if id == chainId1 then
        chainDecls1
      else
        mixedAccessor.nodeData id;
  };
  chainDoubleOracle = build {
    accessor = mixedAccessorDouble;
    recompute = mixedRecompute;
    hashOf = mixedHashOf;
    fixpoint = mixedFixpoint;
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

    # === restabilize ========================================================

    # 1. THE soundness gate: fixed-point-equality over 120 random cyclic graphs.
    # restabilize's incremental cyclic solve == a from-scratch fixpoint build over
    # the changed topology, for every seed (no failing seeds).
    test-restab-sound-120 = {
      expr = restabFailing;
      expected = [ ];
    };

    # 2. acyclic-regression: when the cone touches NO SCC, restabilize reduces to
    # the v1 override splice — byte-identical stores (and pinned).
    test-restab-acyclic-eq-override = {
      expr = chainRestab.store == chainOverride.store;
      expected = true;
    };
    test-restab-acyclic-store-pinned = {
      expr = chainRestab.store;
      expected = chainExpectedStore;
    };

    # 3. missing-per-member-lattice: a built cyclic ctx with a cyclic node's
    # lattice dropped ⇒ restabilize's own precheck throws a catchable blame.
    test-restab-missing-lattice-throws = {
      expr =
        (builtins.tryEval (
          builtins.deepSeq (restabilize mixedCtxMissingLattice mixedChangedId mixedNewDecls) true
        )).success;
      expected = false;
    };

    # 4. requires-fixpoint: restabilize on a v1-built ctx (no fixpoint key) throws.
    test-restab-requires-fixpoint-throws = {
      expr =
        (builtins.tryEval (builtins.deepSeq (restabilize chainCtxV1 chainChangedId chainNewDecls) true))
        .success;
      expected = false;
    };

    # 5. mixed-strata bottom-up: change producer p; restabilize re-solves the full
    # p-cone (SCC {x,y} + consumer c) == oracle build over the changed accessor.
    test-restab-mixed-strata-eq-oracle = {
      expr = mixedRestab.store == mixedOracle.store;
      expected = true;
    };

    # 6. chaining: restabilize ∘ restabilize stays cyclic-capable (fixpoint
    # threaded) and == oracle build over the twice-changed accessor.
    test-restab-chaining-eq-oracle = {
      expr = chainDouble.store == chainDoubleOracle.store;
      expected = true;
    };
    test-restab-chaining-threads-fixpoint = {
      expr = chainDouble ? fixpoint && chainDouble.fixpoint == mixedFixpoint;
      expected = true;
    };
  };
}
