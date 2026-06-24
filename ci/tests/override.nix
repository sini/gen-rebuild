{
  lib,
  genRebuild,
  graph,
  mkCase,
  ...
}:
let
  inherit (genRebuild)
    build
    override
    dirtySet
    affectedSet
    ;

  # --- soundness property: override == from-scratch rebuild, over many seeds ---
  seeds = lib.range 1 120;
  isSound =
    seed:
    let
      c = mkCase seed;
      ctx = build {
        accessor = c.acc;
        inherit (c) recompute hashOf;
      };
      overridden = override ctx c.changedId c.newDecls;
      oracle = build {
        accessor = c.acc';
        inherit (c) recompute hashOf;
      };
    in
    overridden.store == oracle.store;
  failingSeeds = builtins.filter (seed: !(isSound seed)) seeds;

  # --- NEW property: AFFECTED ⊆ over-approx cone, over the same 120 seeds ---
  # The exact AFFECTED set (post-filtered from hashes) can only ever be a subset of
  # the over-approx reachable cone (dirtySet). It is never larger.
  affectedSubsetCone =
    seed:
    let
      c = mkCase seed;
      ctx = build {
        accessor = c.acc;
        inherit (c) recompute hashOf;
      };
      cone = dirtySet ctx [ c.changedId ];
      aff =
        (affectedSet ctx {
          accessor' = c.acc';
          changedIds = [ c.changedId ];
        }).affected;
    in
    builtins.all (id: builtins.elem id cone) aff;
  affectedSupersetSeeds = builtins.filter (seed: !(affectedSubsetCone seed)) seeds;

  # --- value-collision recompute: abs(weight - 50) so distinct weights collide ---
  # weight 30 and weight 70 BOTH yield 20. A leaf override to a colliding value
  # recomputes the leaf to its OLD value ⇒ its hash does not move ⇒ AFFECTED is
  # empty (RTD: value unchanged ⇒ not affected) and the store is byte-identical to
  # ctx.store. (`weight + Σdeps` can never collide; this recompute can.)
  absRecompute =
    a: _s: id:
    let
      x = (a.nodeData id).weight - 50;
    in
    if x < 0 then -x else x;
  absHashOf = v: builtins.hashString "sha256" (builtins.toJSON v);
  # single isolated leaf "l" (no deps, no dependents) keeps the collision local.
  collisionAcc = graph.mkGraph {
    nodeData = {
      l = {
        weight = 30;
      };
    };
  };
  collisionCtx = build {
    accessor = collisionAcc;
    recompute = absRecompute;
    hashOf = absHashOf;
  };
  # ctx.store.l = |30 - 50| = 20. Override to weight 70 ⇒ |70 - 50| = 20 (collision).
  ovCollision = override collisionCtx "l" { weight = 70; };
  collisionAffected =
    (affectedSet collisionCtx {
      accessor' = collisionAcc // {
        nodeData = id: if id == "l" then { weight = 70; } else collisionAcc.nodeData id;
      };
      changedIds = [ "l" ];
    }).affected;

  # --- needsEval-skip via a POISON recompute on a REUSED-but-in-cone node ---
  # collision chain: a -> b -> c, abs(weight) recompute. Override c to a colliding
  # value: c is in the cone but recomputes to its OLD value, so c's hash does NOT
  # move ⇒ b and a (also in the cone) have no moved-hash dep ⇒ needsEval gates them
  # to REUSE. A recompute that THROWS on b/a must therefore NEVER fire. With the v1
  # whole-cone splice this would throw (it recomputed every cone node); the
  # needsEval gate makes the override succeed. The asymmetry is the proof.
  collisionChainAcc = graph.mkGraph {
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
        weight = 30;
      };
      b = {
        weight = 30;
      };
      c = {
        weight = 30;
      };
    };
  };
  # recompute reads NO deps (pure abs of own weight) so c's revalue can't move b/a's
  # input — b/a stay clean and the gate must reuse them.
  collisionChainCtx = build {
    accessor = collisionChainAcc;
    recompute = absRecompute;
    hashOf = absHashOf;
  };
  # poison: throw if b or a is recomputed (they must be reused, not evaluated).
  poisonUpper =
    a: s: id:
    if id == "a" || id == "b" then
      throw "POISON: ${id} recomputed (should reuse)"
    else
      absRecompute a s id;
  poisonedChainCtx = collisionChainCtx // {
    recompute = poisonUpper;
  };
  # override c := 70 (|70-50| = 20 == old |30-50| = 20 ⇒ c's hash does NOT move).
  ovPoison = override poisonedChainCtx "c" { weight = 70; };
  needsEvalSkipsPoison = (builtins.tryEval (builtins.deepSeq ovPoison.store true)).success;
  # the poison is real: a from-scratch build DOES recompute a/b and hits it.
  poisonChainIsReal =
    !(builtins.tryEval (
      builtins.deepSeq
        (build {
          accessor = collisionChainAcc;
          recompute = poisonUpper;
          hashOf = absHashOf;
        }).store
        true
    )).success;

  # --- trace of a REUSED cone node stays byte-identical to the prior trace ---
  # Override c to a colliding value: b is in the cone but REUSED (not affected), so
  # b's trace entry must be the SAME record as ctx.trace.b (re-hash only AFFECTED).
  ovCollisionChain = override collisionChainCtx "c" { weight = 70; };

  # --- hand-computed pins (NOT oracle-derived): chain a->b->c ---
  pinRecompute =
    a: s: id:
    (a.nodeData id).weight + lib.foldl' (sum: dep: sum + s.${dep}) 0 (a.edges id);
  pinHashOf = v: builtins.hashString "sha256" (builtins.toJSON v);
  pinAcc = graph.mkGraph {
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
        weight = 1;
      };
      b = {
        weight = 10;
      };
      c = {
        weight = 100;
      };
    };
  };
  pinCtx = build {
    accessor = pinAcc;
    recompute = pinRecompute;
    hashOf = pinHashOf;
  };
  # pinCtx.store: c=100, b=10+100=110, a=1+110=111.

  # override the leaf "c" := 200. cone = {c} ∪ dependents(c) = {a,b,c}.
  # c=200, b=10+200=210, a=1+210=211.
  ovC = override pinCtx "c" { weight = 200; };

  # override the root "a" := 5. cone = {a} (nothing depends on a). b,c reused.
  # a = 5 + b(110) = 115.
  ovA = override pinCtx "a" { weight = 5; };

  # chained: c:=200 then c:=300, vs a from-scratch build with c=300.
  ovCC = override ovC "c" { weight = 300; };
  oracle300 = build {
    accessor = pinAcc // {
      nodeData = id: if id == "c" then { weight = 300; } else pinAcc.nodeData id;
    };
    recompute = pinRecompute;
    hashOf = pinHashOf;
  };

  # --- authoritative splice form: a recomputed node with a NON-cone dep ---
  # d depends on c AND e; override c. cone = {c, d}. e is NOT in the cone, so d's
  # recompute must read e from ctx.store (via ctx.store // s). Bare `s` would miss
  # e entirely. build: c=1, e=2, d=10+1+2=13. After c:=100: d=10+100+2=112.
  fanAcc = graph.mkGraph {
    edges = [
      {
        from = "d";
        to = "c";
      }
      {
        from = "d";
        to = "e";
      }
    ];
    nodeData = {
      c = {
        weight = 1;
      };
      e = {
        weight = 2;
      };
      d = {
        weight = 10;
      };
    };
  };
  fanCtx = build {
    accessor = fanAcc;
    recompute = pinRecompute;
    hashOf = pinHashOf;
  };
  ovFan = override fanCtx "c" { weight = 100; };

  # --- fixed adversarial shapes (complement the 120 random DAGs) ---
  # soundOn: does a data-change override of `changedId` match a full rebuild?
  soundOn =
    accessor: changedId: newDecls:
    let
      c = build {
        inherit accessor;
        recompute = pinRecompute;
        hashOf = pinHashOf;
      };
      ov = override c changedId newDecls;
      acc' = accessor // {
        nodeData = id: if id == changedId then newDecls else accessor.nodeData id;
      };
      oracle = build {
        accessor = acc';
        recompute = pinRecompute;
        hashOf = pinHashOf;
      };
    in
    ov.store == oracle.store;

  # wide diamond: top fans out to m1..m4, all fan in to a shared base.
  wideDiamond = graph.mkGraph {
    edges =
      builtins.concatMap
        (m: [
          {
            from = "top";
            to = m;
          }
          {
            from = m;
            to = "base";
          }
        ])
        [
          "m1"
          "m2"
          "m3"
          "m4"
        ];
    nodeData = {
      top = {
        weight = 1;
      };
      m1 = {
        weight = 2;
      };
      m2 = {
        weight = 3;
      };
      m3 = {
        weight = 4;
      };
      m4 = {
        weight = 5;
      };
      base = {
        weight = 10;
      };
    };
  };
  wideDiamondCtx = build {
    accessor = wideDiamond;
    recompute = pinRecompute;
    hashOf = pinHashOf;
  };

  # deep chain n0 -> n1 -> ... -> n5 (n0 depends on n1 … n4 depends on n5).
  deepChain = graph.mkGraph {
    edges =
      map
        (i: {
          from = "n${toString i}";
          to = "n${toString (i + 1)}";
        })
        [
          0
          1
          2
          3
          4
        ];
    nodeData = builtins.listToAttrs (
      map
        (i: {
          name = "n${toString i}";
          value = {
            weight = i + 1;
          };
        })
        [
          0
          1
          2
          3
          4
          5
        ]
    );
  };
in
{
  flake.tests.override = {
    # ===== the thesis: sound intra-eval incremental override =====
    test-soundness-120-seeds = {
      expr = failingSeeds;
      expected = [ ];
    };

    # ===== hand-computed pins =====
    test-pin-override-c-a = {
      expr = ovC.store.a;
      expected = 211;
    };
    test-pin-override-c-b = {
      expr = ovC.store.b;
      expected = 210;
    };
    test-pin-override-c-c = {
      expr = ovC.store.c;
      expected = 200;
    };
    test-pin-override-a = {
      expr = ovA.store.a;
      expected = 115;
    };

    # ===== non-cone nodes byte-identical to ctx.store (reuse) =====
    test-reuse-b-identical = {
      expr = ovA.store.b == pinCtx.store.b;
      expected = true;
    };
    test-reuse-c-identical = {
      expr = ovA.store.c == pinCtx.store.c;
      expected = true;
    };

    # ===== authoritative splice form (ctx.store // s, not bare s) =====
    test-splice-noncone-dep = {
      expr = ovFan.store.d;
      expected = 112;
    };
    test-splice-noncone-reused = {
      expr = ovFan.store.e;
      expected = 2;
    };

    # ===== trace re-hashed for the recomputed cone =====
    test-trace-rehash-c = {
      expr = ovC.trace.c.hash;
      expected = pinHashOf 200;
    };
    test-trace-deps-preserved = {
      expr = ovC.trace.a.deps;
      expected = [ "b" ];
    };

    # ===== updated accessor threaded into the returned ctx =====
    test-ctx-accessor-updated = {
      expr = (ovC.accessor.nodeData "c").weight;
      expected = 200;
    };

    # ===== chained overrides stay sound =====
    test-chained-sound = {
      expr = ovCC.store == oracle300.store;
      expected = true;
    };
    test-chained-c = {
      expr = ovCC.store.c;
      expected = 300;
    };

    # ===== fixed adversarial shapes — sound for root / middle / leaf changes =====
    # wide diamond: leaf (whole cone), middle (small cone), root (cone = {root}).
    test-sound-wide-diamond-leaf = {
      expr = soundOn wideDiamond "base" { weight = 99; };
      expected = true;
    };
    test-sound-wide-diamond-middle = {
      expr = soundOn wideDiamond "m2" { weight = 99; };
      expected = true;
    };
    test-sound-wide-diamond-root = {
      expr = soundOn wideDiamond "top" { weight = 99; };
      expected = true;
    };
    # deep chain: leaf (all ancestors), middle, root (cone = {root}).
    test-sound-deep-chain-leaf = {
      expr = soundOn deepChain "n5" { weight = 99; };
      expected = true;
    };
    test-sound-deep-chain-middle = {
      expr = soundOn deepChain "n3" { weight = 99; };
      expected = true;
    };
    test-sound-deep-chain-root = {
      expr = soundOn deepChain "n0" { weight = 99; };
      expected = true;
    };
    # cone-shape sanity: the fixtures are NOT trivially all-cone — a middle change
    # touches a strict subset, proving the splice genuinely reuses non-cone nodes.
    test-cone-wide-diamond-middle = {
      expr = builtins.sort builtins.lessThan (dirtySet wideDiamondCtx [ "m2" ]);
      expected = [
        "m2"
        "top"
      ];
    };
    test-cone-wide-diamond-root = {
      expr = dirtySet wideDiamondCtx [ "top" ];
      expected = [ "top" ];
    };

    # ===== NEW (P2): exact AFFECTED ⊆ over-approx cone over 120 seeds =====
    test-affected-subset-cone-120 = {
      expr = affectedSupersetSeeds;
      expected = [ ];
    };

    # ===== NEW (P2): value-collision ⇒ AFFECTED == [] AND store == ctx.store =====
    # leaf recomputes to its OLD value (collision) ⇒ nothing is affected.
    test-affected-empty-on-collision = {
      expr = collisionAffected;
      expected = [ ];
    };
    test-collision-store-unchanged = {
      expr = ovCollision.store == collisionCtx.store;
      expected = true;
    };

    # ===== NEW (P2): needsEval gates a REUSED-but-in-cone node (poison skip) =====
    # poison throws if a/b are recomputed; the gate reuses them ⇒ override succeeds.
    test-needsEval-skip-poison = {
      expr = needsEvalSkipsPoison;
      expected = true;
    };
    # the poison is real: a from-scratch build recomputes a/b and hits it.
    test-needsEval-poison-is-real = {
      expr = poisonChainIsReal;
      expected = true;
    };

    # ===== NEW (P2): a REUSED cone node keeps its prior trace byte-identical =====
    test-trace-reused-byte-identical = {
      expr = ovCollisionChain.trace.b == collisionChainCtx.trace.b;
      expected = true;
    };
    # and the reused node's store value is byte-identical too.
    test-store-reused-byte-identical = {
      expr = ovCollisionChain.store.b == collisionChainCtx.store.b;
      expected = true;
    };
  };
}
