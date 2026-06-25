# Unit pins for propagateEager — the cut-heavy fast path (v3 V-push, PARTIAL).
#
# Two soundness pins (chain leaf-change + diamond) assert the eager store is
# BYTE-IDENTICAL to a from-scratch build over the changed accessor — exactly the
# property override's 120-seed test proves, but for the rank-ordered eager push.
# A third, DECISIVE pin builds a saturating deep-cut chain whose cumulative sum
# pins to a cap within a couple of nodes: a tiny upstream bump dies early, so the
# nodes PAST the cut — though they sit IN the over-approx cone — must NEVER be
# recomputed. We make that observable with a POISON recompute that THROWS on the
# post-cut nodes: the eager build succeeds (deepSeq) BECAUSE it cuts them off,
# while a from-scratch build over the same poison hits the throw. recompute ⊊ cone.
{
  lib,
  genRebuild,
  graph,
  mkCase,
  ...
}:
let
  inherit (genRebuild) build propagateEager dirtySet;

  hashOf = v: builtins.hashString "sha256" (builtins.toJSON v);

  # ctxOf: build a BuiltCtx from a fixture-shaped { accessor; recompute; hashOf; }.
  ctxOf =
    fx:
    build {
      accessor = fx.accessor;
      inherit (fx) recompute hashOf;
    };

  # withChange: accessor' overlaying new nodeData; edges (topology) fixed.
  withChange =
    acc: changes:
    acc
    // {
      nodeData = id: if changes ? ${id} then changes.${id} else acc.nodeData id;
    };

  # oracle: from-scratch ground truth store for the CHANGED accessor.
  oracle =
    fx: changes:
    (build {
      accessor = withChange fx.accessor changes;
      inherit (fx) recompute hashOf;
    }).store;

  # `weight + Σdeps` recompute (additive; never collides — every move propagates).
  sumRecompute =
    a: s: id:
    (a.nodeData id).weight + lib.foldl' (acc: dep: acc + s.${dep}) 0 (a.edges id);

  # --- Pin 1: leaf change on a chain a -> b -> c (a depends on b depends on c) ---
  # cone = {a,b,c}; changing the leaf c moves the whole chain.
  chainAcc = graph.mkGraph {
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
      a.weight = 1;
      b.weight = 10;
      c.weight = 100;
    };
  };
  chainFx = {
    accessor = chainAcc;
    recompute = sumRecompute;
    inherit hashOf;
  };
  chainCtx = ctxOf chainFx;
  # ctx.store: c=100, b=110, a=111. Change leaf c := 200 ⇒ c=200, b=210, a=211.
  chainChanges = {
    c.weight = 200;
  };
  chainEager = propagateEager chainCtx chainChanges;

  # --- Pin 2: diamond  d -> {b,c} -> a (d depends on b,c; b,c depend on a) ---
  # change the root a; both arms then the apex d move (whole cone).
  diamondAcc = graph.mkGraph {
    edges = [
      {
        from = "b";
        to = "a";
      }
      {
        from = "c";
        to = "a";
      }
      {
        from = "d";
        to = "b";
      }
      {
        from = "d";
        to = "c";
      }
    ];
    nodeData = {
      a.weight = 1;
      b.weight = 10;
      c.weight = 100;
      d.weight = 1000;
    };
  };
  diamondFx = {
    accessor = diamondAcc;
    recompute = sumRecompute;
    inherit hashOf;
  };
  diamondCtx = ctxOf diamondFx;
  # a=1, b=11, c=101, d=1000+11+101=1112. Change a := 5 ⇒ b=15, c=105, d=1120.
  diamondChanges = {
    a.weight = 5;
  };
  diamondEager = propagateEager diamondCtx diamondChanges;

  # --- Pin 3: saturating deep-cut — recompute STRICTLY sub-cone ----------------
  # A long chain n0 <- n1 <- ... <- n7 where n(i) depends on n(i-1). Value flows
  # n0 -> n7 via a SATURATING sum: once the cumulative raw exceeds the cap it pins
  # to the cap, so a tiny bump at n0 dies within a couple of nodes (no-move cutoff).
  cap = 100;
  rawOf =
    a: s: id:
    (a.nodeData id).weight + lib.foldl' (acc: dep: acc + s.${dep}) 0 (a.edges id);
  satRecompute =
    a: s: id:
    let
      raw = rawOf a s id;
    in
    if raw > cap then cap else raw;

  deepN = 8;
  deepIds = map (i: "n${toString i}") (lib.range 0 (deepN - 1));
  deepAcc = graph.mkGraph {
    edges = map (i: {
      from = "n${toString i}";
      to = "n${toString (i - 1)}";
    }) (lib.range 1 (deepN - 1));
    # n0..n3 weighted so cumulative sum crosses cap=100 by ~n3; n4..n7 then SAT.
    nodeData = lib.listToAttrs (
      map (i: lib.nameValuePair "n${toString i}" { weight = 40; }) (lib.range 0 (deepN - 1))
    );
  };
  deepFx = {
    accessor = deepAcc;
    recompute = satRecompute;
    inherit hashOf;
  };
  deepCtx = ctxOf deepFx;
  # Change the producer n0's weight 40 -> 41. The sum saturates at 100 within a
  # couple of nodes, so the tail n_k.. never moves: cutoff long before the chain end.
  deepChanges = {
    n0.weight = 41;
  };
  deepEager = propagateEager deepCtx deepChanges;
  deepOracleStore = oracle deepFx deepChanges;
  # Over-approx cone of the change = n0 + all its dependents = the WHOLE chain.
  deepCone = dirtySet deepCtx [ "n0" ];

  # The decisive observation: which cone nodes still MOVE under the cut. We compute
  # the affected set (eager store vs prior store) and assert it is a STRICT subset
  # of the cone — the saturated tail is cut off (recompute never reaches it).
  deepMoved = builtins.filter (id: deepEager.store.${id} != deepCtx.store.${id}) deepIds;

  # POISON proof that the cut nodes are NEVER recomputed (not merely unchanged):
  # the tail nodes are already saturated at the cap, so under a small n0 bump they
  # do not move ⇒ eager cuts them off ⇒ poisonTail (throw on the tail) never fires.
  # A from-scratch build over the same poison DOES recompute the tail and throws.
  tailCut = [
    "n5"
    "n6"
    "n7"
  ];
  poisonTail =
    a: s: id:
    if builtins.elem id tailCut then
      throw "POISON: ${id} recomputed (must be cut off)"
    else
      satRecompute a s id;
  # Build the clean ctx, then swap in the poison recompute for the eager push.
  poisonCtx = deepCtx // {
    recompute = poisonTail;
  };
  poisonEager = propagateEager poisonCtx deepChanges;
  eagerCutsOffPoison = (builtins.tryEval (builtins.deepSeq poisonEager.store true)).success;
  # the poison is real: a from-scratch build recomputes the tail and hits it.
  poisonIsReal =
    !(builtins.tryEval (
      builtins.deepSeq
        (build {
          accessor = withChange deepAcc deepChanges;
          recompute = poisonTail;
          inherit hashOf;
        }).store
        true
    )).success;

  # --- chained soundness: two eager pushes vs a from-scratch build -------------
  chainEager2 = propagateEager chainEager { c.weight = 300; };
  chainOracle300 = oracle chainFx { c.weight = 300; };

  # --- multi-seed: change two nodes at once on the diamond ----------------------
  diamondMultiEager = propagateEager diamondCtx {
    b.weight = 20;
    c.weight = 200;
  };
  diamondMultiOracle = oracle diamondFx {
    b.weight = 20;
    c.weight = 200;
  };

  # ===========================================================================
  # SOUNDNESS GATE (Task 3) — the production proof for the eager fast path.
  # ===========================================================================

  # --- 120-seed byte-identity property (mirrors override.nix:16-33) ------------
  # For each seeded random DAG, `propagateEager ctx { ${changedId} = newDecls; }`
  # must produce a store BYTE-IDENTICAL to a from-scratch build over the changed
  # accessor (c.acc'). mkCase's recompute is ADDITIVE (`weight + Σdeps`), so it
  # NEVER cuts off — every cone node moves, the worst case for an eager push: the
  # whole cone is reconstructed, and it must still match the oracle node-for-node.
  seeds = lib.range 1 120;
  isSound =
    seed:
    let
      c = mkCase seed;
      ctx = build {
        accessor = c.acc;
        inherit (c) recompute hashOf;
      };
      eager = propagateEager ctx {
        ${c.changedId} = c.newDecls;
      };
      oracleStore =
        (build {
          accessor = c.acc';
          inherit (c) recompute hashOf;
        }).store;
    in
    eager.store == oracleStore;
  failingSeeds = builtins.filter (seed: !(isSound seed)) seeds;

  # --- cutoff-join §4(B): Q is in-cone but NEVER enqueued (priorStore carry) ----
  # The decisive soundness case the single-id 120-seed can't reach. Edges are
  # consumer→producer; recompute = satRecompute 100. Change A's weight 10→20:
  #   A []      10→20  : 10→20                       moves (the seed)
  #   M [A]     5       : min(100,15)=15 → 25         moves ⇒ enqueues J
  #   P [A]     95      : min(100,105)=100 → 100      COLLIDES ⇒ CUTOFF (no enqueue)
  #   Q [P]     3       : min(100,103)=100 → 100      in-cone but NEVER enqueued
  #   J [M,Q]   1       : min(100,116)=100 → 100      enqueued by M, collides
  # cone(A) = {A,M,P,Q,J}; AFFECTED = {A,M}. Q sits in the cone yet is never
  # enqueued (its sole enqueuer P cut off), so its value must be CARRIED from the
  # prior store via `ctx.store // settled` — not recomputed. This is the §4(B) carry.
  joinCap = 100;
  joinSat =
    a: s: id:
    let
      raw = (a.nodeData id).weight + lib.foldl' (acc: dep: acc + s.${dep}) 0 (a.edges id);
    in
    if raw > joinCap then joinCap else raw;
  joinAcc = graph.mkGraph {
    edges = [
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
    nodeData = {
      A.weight = 10;
      M.weight = 5;
      P.weight = 95;
      Q.weight = 3;
      J.weight = 1;
    };
  };
  joinFx = {
    accessor = joinAcc;
    recompute = joinSat;
    inherit hashOf;
  };
  joinCtx = ctxOf joinFx;
  joinChanges = {
    A.weight = 20;
  };
  joinEager = propagateEager joinCtx joinChanges;
  joinOracleStore = oracle joinFx joinChanges;
  # Q's in-cone-but-cut-off value: equal to the PRIOR store (unmoved) AND the oracle.
  joinCone = dirtySet joinCtx [ "A" ];
  # POISON proof that Q is CARRIED, never recomputed (a RIGHT-REASON proof: the
  # value pins above only show store.Q == prior == oracle == 100, which a buggy op
  # that DID recompute Q would also satisfy). P collides ⇒ cuts off ⇒ Q's sole
  # enqueuer is dead ⇒ eager never recomputes Q, so joinPoison (throw on Q) never
  # fires. A from-scratch build DOES recompute Q and throws — parallel to the
  # deep-cut poison pair above, but for the re-convergent join shape §4(B) needs.
  joinPoison =
    a: s: id:
    if id == "Q" then
      throw "POISON: Q recomputed (must be carried from priorStore)"
    else
      joinSat a s id;
  joinPoisonCtx = joinCtx // {
    recompute = joinPoison;
  };
  joinEagerCarriesQ =
    (builtins.tryEval (builtins.deepSeq (propagateEager joinPoisonCtx joinChanges).store true)).success;
  joinPoisonIsReal =
    !(builtins.tryEval (
      builtins.deepSeq
        (build {
          accessor = withChange joinAcc joinChanges;
          recompute = joinPoison;
          inherit hashOf;
        }).store
        true
    )).success;
in
{
  flake.tests.eager = {
    # ===== Pin 1: chain leaf-change == from-scratch build (byte-identical) =====
    test-chain-leaf-store-eq-oracle = {
      expr = chainEager.store == oracle chainFx chainChanges;
      expected = true;
    };
    test-chain-leaf-a = {
      expr = chainEager.store.a;
      expected = 211;
    };
    test-chain-leaf-b = {
      expr = chainEager.store.b;
      expected = 210;
    };
    test-chain-leaf-c = {
      expr = chainEager.store.c;
      expected = 200;
    };

    # ===== Pin 2: diamond root-change == from-scratch build =====
    test-diamond-store-eq-oracle = {
      expr = diamondEager.store == oracle diamondFx diamondChanges;
      expected = true;
    };
    test-diamond-d = {
      expr = diamondEager.store.d;
      expected = 1120;
    };

    # ===== chains soundly (returns a BuiltCtx) =====
    test-chained-eager-eq-oracle = {
      expr = chainEager2.store == chainOracle300;
      expected = true;
    };
    test-chained-eager-c = {
      expr = chainEager2.store.c;
      expected = 300;
    };

    # ===== multi-seed (changes :: { <id> = newDecls; }) =====
    test-multiseed-eq-oracle = {
      expr = diamondMultiEager.store == diamondMultiOracle;
      expected = true;
    };

    # ===== BuiltCtx shape: same surface as override/propagate (chains) =====
    test-returns-store = {
      expr = chainEager ? store;
      expected = true;
    };
    test-returns-trace = {
      expr = chainEager ? trace;
      expected = true;
    };
    test-returns-accessor = {
      expr = chainEager ? accessor;
      expected = true;
    };
    test-returns-recompute = {
      expr = chainEager ? recompute;
      expected = true;
    };
    test-returns-hashOf = {
      expr = chainEager ? hashOf;
      expected = true;
    };
    # accessor' overlays the change (threaded for chaining).
    test-accessor-overlays-change = {
      expr = (chainEager.accessor.nodeData "c").weight;
      expected = 200;
    };
    # trace re-hashes ONLY moved nodes; a moved node's entry matches the new value.
    test-trace-rehash-moved-c = {
      expr = chainEager.trace.c.hash;
      expected = hashOf 200;
    };

    # ===== Pin 3: deep-cut saturating — store is sound AND recompute sub-cone =====
    test-deep-store-eq-oracle = {
      expr = deepEager.store == deepOracleStore;
      expected = true;
    };
    # the cone is the WHOLE chain (over-approx via reverse-reachability)...
    test-deep-cone-is-whole-chain = {
      expr = builtins.sort builtins.lessThan deepCone;
      expected = builtins.sort builtins.lessThan deepIds;
    };
    # ...but only a STRICT subset actually moves (the saturated tail is cut off).
    test-deep-moved-strict-subset = {
      expr = (builtins.length deepMoved < builtins.length deepCone) && (builtins.length deepMoved > 0);
      expected = true;
    };
    # the saturated tail nodes are byte-identical to the prior store (cut off).
    test-deep-tail-n7-unchanged = {
      expr = deepEager.store.n7 == deepCtx.store.n7;
      expected = true;
    };
    # DECISIVE: a poison that throws on the tail NEVER fires under eager (cut off)...
    test-deep-poison-cut-off = {
      expr = eagerCutsOffPoison;
      expected = true;
    };
    # ...and the poison is real: a from-scratch build recomputes the tail and throws.
    test-deep-poison-is-real = {
      expr = poisonIsReal;
      expected = true;
    };

    # ===== SOUNDNESS GATE: 120-seed byte-identity (mirrors override.nix) =====
    # The thesis for the eager fast path: over 120 random DAGs, the eager push is
    # byte-identical to a from-scratch build over the changed accessor. mkCase is
    # additive ⇒ full-cone propagation, so this is the worst-case (everything moves)
    # store-equality proof. failingSeeds MUST be empty.
    test-soundness-120-seeds = {
      expr = failingSeeds;
      expected = [ ];
    };

    # ===== SOUNDNESS GATE: cutoff-join §4(B) — Q carried from priorStore =====
    # store is byte-identical to the from-scratch oracle...
    test-join-store-eq-oracle = {
      expr = joinEager.store == joinOracleStore;
      expected = true;
    };
    # ...the cone is the full {A,M,P,Q,J} (over-approx reverse-reachability)...
    test-join-cone-is-whole = {
      expr = builtins.sort builtins.lessThan joinCone;
      expected = [
        "A"
        "J"
        "M"
        "P"
        "Q"
      ];
    };
    # ...and Q (in-cone but never enqueued — its enqueuer P cut off) is CARRIED from
    # the prior store: equal to ctx.store.Q (unmoved) AND to the oracle's Q.
    test-join-Q-carried-from-prior = {
      expr = joinEager.store.Q == joinCtx.store.Q;
      expected = true;
    };
    test-join-Q-eq-oracle = {
      expr = joinEager.store.Q == joinOracleStore.Q;
      expected = true;
    };
    # decisive sanity: A and M moved (the affected pair), P/Q/J collide at the cap.
    test-join-A-moved = {
      expr = joinEager.store.A;
      expected = 20;
    };
    test-join-M-moved = {
      expr = joinEager.store.M;
      expected = 25;
    };
    # RIGHT-REASON carry proof: eager never recomputes Q (poison on Q never fires),
    # while a from-scratch build does (poison is real).
    test-join-poison-Q-carried = {
      expr = joinEagerCarriesQ;
      expected = true;
    };
    test-join-poison-is-real = {
      expr = joinPoisonIsReal;
      expected = true;
    };
  };
}
