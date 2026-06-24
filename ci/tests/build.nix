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

  # --- fixpoint-present (Task 2) fixtures ---

  # The acyclic chain reused as the v1-regression oracle: with the standard
  # sum-recompute the store is c=100, b=110, a=111 (see the store pins above).
  acyclicAcc = accessor;

  # 2-SCC graph: consumer-SCC-A {a1,a2} reads producer-SCC-B {b1,b2} (a1 -> b1).
  #   b1 -> [b2], b2 -> [b1]            (SCC-B, a 2-cycle)
  #   a1 -> [a2, b1], a2 -> [a1]        (SCC-A, a 2-cycle; a1 also reads b1 of B)
  # self weights: b1=1, b2=2, a1=10, a2=3.
  twoSccAcc = graph.mkGraph {
    edges = [
      {
        from = "b1";
        to = "b2";
      }
      {
        from = "b2";
        to = "b1";
      }
      {
        from = "a1";
        to = "a2";
      }
      {
        from = "a1";
        to = "b1";
      }
      {
        from = "a2";
        to = "a1";
      }
    ];
    nodeData = {
      b1 = {
        weight = 1;
      };
      b2 = {
        weight = 2;
      };
      a1 = {
        weight = 10;
      };
      a2 = {
        weight = 3;
      };
    };
  };

  # Max-agreement recompute (LOCAL to this fixture — differs from the standard
  # sum-recompute): each node's value is the max of its own weight and its deps'
  # values. Monotone + bounded by the max weight, so it stabilizes. The lfp:
  # SCC-B agrees on max(1,2) = 2 (b1 = b2 = 2); SCC-A agrees on max(10,3,b1=2) =
  # 10 (a1 = a2 = 10).
  maxRecompute =
    acc: s: m:
    lib.foldl' lib.max (acc.nodeData m).weight (map (d: s.${d}) (acc.edges m));

  # Overwrite "lattice" per node: bottom = 0, join keeps the new iterate, eq is
  # structural ==. Not a semilattice join (no ⊑ order); naive iterate-to-
  # stabilization, which converges because maxRecompute is monotone + bounded.
  maxLattices = {
    lattices = lib.genAttrs [ "b1" "b2" "a1" "a2" ] (_: {
      bottom = 0;
      join = _prev: v: v;
      eq = a: b: a == b;
    });
  };

  twoSccCtx = build {
    accessor = twoSccAcc;
    recompute = maxRecompute;
    inherit hashOf;
    fixpoint = maxLattices;
  };

  # Self-loop x -> [x]: x is cyclic but has no declared lattice ⇒ the relaxed
  # precheck must throw an undeclared-cyclic-node blame (catchable).
  selfLoopAcc = graph.mkGraph {
    edges = [
      {
        from = "x";
        to = "x";
      }
    ];
    nodeData = {
      x = {
        weight = 7;
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

    # --- fixpoint param (Task 2) ---

    # 1. ABSENT fixpoint field is the real v1 path: hand-computed chain store.
    test-fixpoint-absent-is-v1-store = {
      expr =
        (build {
          accessor = acyclicAcc;
          inherit recompute hashOf;
        }).store;
      expected = {
        a = 111;
        b = 110;
        c = 100;
      };
    };

    # 2. Empty lattices degenerates to v1 byte-identically on an acyclic graph
    #    (relaxed precheck passes: cycles == [] ⊆ {}).
    test-fixpoint-empty-lattices-equals-v1 = {
      expr =
        (build {
          accessor = acyclicAcc;
          inherit recompute hashOf;
          fixpoint = {
            lattices = { };
          };
        }).store == (build {
          accessor = acyclicAcc;
          inherit recompute hashOf;
        }).store;
      expected = true;
    };

    # 3. fixpoint = null (absent) still throws a catchable blame on a cycle.
    #    (Preserved from v1; renamed-equivalent of test-cycle-throws-catchable.)
    test-fixpoint-null-still-throws-on-cycle = {
      expr =
        (builtins.tryEval (
          builtins.deepSeq (build {
            accessor = cyclic;
            inherit recompute hashOf;
          }) true
        )).success;
      expected = false;
    };

    # 4. 2-SCC stratified solve, hand-pinned lfp: SCC-B = max(1,2) = 2,
    #    SCC-A = max(10,3,b1) = 10.
    test-fixpoint-2scc-b1 = {
      expr = twoSccCtx.store.b1;
      expected = 2;
    };
    test-fixpoint-2scc-b2 = {
      expr = twoSccCtx.store.b2;
      expected = 2;
    };
    test-fixpoint-2scc-a1 = {
      expr = twoSccCtx.store.a1;
      expected = 10;
    };
    test-fixpoint-2scc-a2 = {
      expr = twoSccCtx.store.a2;
      expected = 10;
    };

    # 5. build-domain-restriction ORDERING gate: the condensation places
    #    producer-SCC-B BEFORE consumer-SCC-A in bottomUp. This producers-first
    #    invariant is what lets each stratum read already-converged lower strata
    #    (the domain restriction that the stratified solve depends on). We assert
    #    the ORDERING, never evaluate a bare-fix (its divergence is a self-
    #    referential thunk black-hole that escapes builtins.tryEval).
    test-fixpoint-condensation-producer-before-consumer = {
      expr =
        let
          cond = graph.condensation twoSccAcc;
          bu = cond.bottomUp;
          iB = lib.lists.findFirstIndex (t: t == cond.sccOf "b1") (-1) bu;
          iA = lib.lists.findFirstIndex (t: t == cond.sccOf "a1") (-1) bu;
        in
        iB < iA;
      expected = true;
    };

    # 6. undeclared-cyclic-node throw: a cyclic node lacking a lattice ⇒ the
    #    relaxed precheck throws a catchable blame.
    test-fixpoint-undeclared-cyclic-throws = {
      expr =
        (builtins.tryEval (
          builtins.deepSeq (build {
            accessor = selfLoopAcc;
            recompute = maxRecompute;
            inherit hashOf;
            fixpoint = {
              lattices = { };
            };
          }) true
        )).success;
      expected = false;
    };
  };
}
