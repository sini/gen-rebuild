{
  lib,
  genRebuild,
  graph,
  mkCase,
  ...
}:
let
  inherit (genRebuild) build override;

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
  };
}
