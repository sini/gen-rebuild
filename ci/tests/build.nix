{
  lib,
  genRebuild,
  graph,
  ...
}:
let
  inherit (genRebuild) build override;

  # a depends on b depends on c (edges a=["b"], b=["c"], c=[]) — consumer→producer.
  accessor = graph.mkGraph {
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
        v = 1;
      };
      b = {
        v = 10;
      };
      c = {
        v = 100;
      };
    };
  };

  # node value = own v + sum of dep values (read from the store-being-built `s`).
  recompute =
    acc: s: id:
    let
      data = acc.nodeData id;
      deps = acc.edges id;
    in
    data.v + lib.foldl' (sum: d: sum + s.${d}) 0 deps;

  hashOf = v: builtins.hashString "sha256" (builtins.toJSON v);

  ctx = build { inherit accessor recompute hashOf; };

  # Nodes whose result carries a function: hashOf is partial (not toJSON-able), so
  # the trace hash must be null (always-dirty), not an eval error. `f` has the
  # function at depth 1; `g` buries it in attrs + lists, to exercise the full
  # recursive walk of the hash guard (lib/hash.nix).
  lambdaAccessor = graph.mkGraph {
    nodeData = {
      f = { };
      g = { };
    };
  };
  lambdaCtx = build {
    accessor = lambdaAccessor;
    recompute =
      _acc: _s: id:
      if id == "f" then
        { fn = x: x + 1; }
      else
        {
          wrap = {
            deep = [ { fn = y: y * 2; } ];
          };
        };
    inherit hashOf;
  };

  # --- override THROUGH a function-bearing node (hash = null ⇒ always-dirty) ---
  # `fnode`'s value carries a function ⇒ trace hash = null. `consumer` depends on
  # fnode but derives an INTEGER from fnode's hashable `tag` field (function thunks
  # never compare ==, so soundness is asserted on the hashable projection). The
  # null-hash dep means `consumer` is ALWAYS-DIRTY in the cone — the only path that
  # exercises the null-hash guard inside override's needsEval gate. Overriding fnode
  # must stay sound (the consumer is recomputed, never false-clean reused).
  fnAccessor = graph.mkGraph {
    edges = [
      {
        from = "consumer";
        to = "fnode";
      }
    ];
    nodeData = {
      fnode = {
        tag = 1;
      };
      consumer = { };
    };
  };
  fnRecompute =
    acc: s: id:
    if id == "fnode" then
      {
        # value carries a function ⇒ hash = null (always-dirty).
        fn = x: x + (acc.nodeData "fnode").tag;
        tag = (acc.nodeData "fnode").tag;
      }
    else
      # consumer reads the hashable `tag` of its function-bearing dep.
      100 + s.fnode.tag;
  fnCtx = build {
    accessor = fnAccessor;
    recompute = fnRecompute;
    inherit hashOf;
  };
  # override fnode's tag := 5. cone = {fnode, consumer}; both recomputed.
  fnOverridden = override fnCtx "fnode" { tag = 5; };
  # ground truth: a full rebuild with fnode's tag replaced.
  fnAcc' = fnAccessor // {
    nodeData = id: if id == "fnode" then { tag = 5; } else fnAccessor.nodeData id;
  };
  fnOracle = build {
    accessor = fnAcc';
    recompute = fnRecompute;
    inherit hashOf;
  };

  # a <-> b cycle: build must throw a located blame (catchable), never loop.
  cyclic = graph.mkGraph {
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
        v = 1;
      };
      b = {
        v = 2;
      };
    };
  };
in
{
  flake.tests.build = {
    # --- store: hand-computed independent pins (NOT oracle-derived) ---
    # c = 100; b = 10 + c = 110; a = 1 + b = 111.
    test-store-a = {
      expr = ctx.store.a;
      expected = 111;
    };
    test-store-b = {
      expr = ctx.store.b;
      expected = 110;
    };
    test-store-c = {
      expr = ctx.store.c;
      expected = 100;
    };

    # --- trace: per-key deps (= accessor.edges) + content hash ---
    test-trace-deps-a = {
      expr = ctx.trace.a.deps;
      expected = [ "b" ];
    };
    test-trace-deps-c = {
      expr = ctx.trace.c.deps;
      expected = [ ];
    };
    test-trace-hash-a = {
      expr = ctx.trace.a.hash;
      expected = hashOf 111;
    };

    # --- BuiltCtx threads accessor/recompute/hashOf for override ---
    test-ctx-threads-accessor = {
      expr = ctx.accessor.nodes == accessor.nodes;
      expected = true;
    };

    # --- hashOf partial on function-bearing values -> hash = null ---
    test-trace-hash-null-on-function = {
      expr = lambdaCtx.trace.f.hash;
      expected = null;
    };
    # function buried in attrs + lists is still detected (recursive walk).
    test-trace-hash-null-on-nested-function = {
      expr = lambdaCtx.trace.g.hash;
      expected = null;
    };

    # --- located cycle: catchable throw, not Nix infinite recursion ---
    test-cycle-throws-catchable = {
      expr =
        (builtins.tryEval (build {
          accessor = cyclic;
          inherit recompute hashOf;
        })).success;
      expected = false;
    };

    # --- override THROUGH a function-bearing node stays sound (null-hash guard) ---
    # consumer (always-dirty via its null-hash dep) is recomputed; its hashable
    # projection matches a from-scratch rebuild.
    test-override-through-fnode-consumer = {
      expr = fnOverridden.store.consumer == fnOracle.store.consumer;
      expected = true;
    };
    # the consumer's recomputed value reflects the override (100 + 5 = 105).
    test-override-through-fnode-value = {
      expr = fnOverridden.store.consumer;
      expected = 105;
    };
    # the function-bearing node's trace hash stays null after override (always-dirty).
    test-override-fnode-hash-null = {
      expr = fnOverridden.trace.fnode.hash;
      expected = null;
    };
  };
}
