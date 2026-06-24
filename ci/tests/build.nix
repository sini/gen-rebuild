{
  lib,
  genRebuild,
  graph,
  ...
}:
let
  inherit (genRebuild) build;

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
  };
}
