# structural — topology-changing deltas: retract + applyEdgeDelta.
#
# The edge-VARYING analogue of override.nix's data-change suite. Locks the two
# structural soundness gates (edge-varying 120-seed, retract 120-seed), the
# located cycle recheck (a new edge that closes a cycle is a catchable thrown
# blame, never Nix infinite recursion), the lib.unique newEdges dedup, the
# new-producer sub-build, the trace.deps rewrite for edge-touched nodes, and
# chaining across structural + data deltas.
{
  lib,
  genRebuild,
  graph,
  mkStructuralCase,
  ...
}:
let
  inherit (genRebuild)
    build
    override
    retract
    applyEdgeDelta
    ;

  recompute =
    a: s: id:
    (a.nodeData id).weight + lib.foldl' (sum: dep: sum + s.${dep}) 0 (a.edges id);
  hashOf = v: builtins.hashString "sha256" (builtins.toJSON v);

  # ----- hand-built chain a -> b -> c (a deps b, b deps c) --------------------
  # ctx.store: c=100, b=10+100=110, a=1+110=111.
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
  chainCtx = build {
    accessor = chainAcc;
    inherit recompute hashOf;
  };

  # ===== applyEdgeDelta: repoint a's edges from [b] to [c] =====================
  # a now reads c directly (not b). a = 1 + c(100) = 101. b,c unchanged.
  # cone(a) = {a} (nothing depends on a), so b/c are reused.
  edgeRepointed = applyEdgeDelta chainCtx "a" [ "c" ];

  # ===== dedup newEdges: [b c c] must NOT double-count c ======================
  # a's edges := lib.unique [b c c] = [b c]. a = 1 + b(110) + c(100) = 211.
  # WITHOUT the dedup the recompute fold double-counts c ⇒ a = 311 (the known bug).
  edgeDedup = applyEdgeDelta chainCtx "a" [
    "b"
    "c"
    "c"
  ];

  # ===== new-producer sub-build ===============================================
  # A base accessor whose `nodes` is just [a] but whose nodeData/edges ALSO define
  # z (weight 50, z→w) and w (weight 7, no edges) — z,w are KNOWN but not yet in
  # the node set (no one reads them). applyEdgeDelta a := [z] makes a read z; the
  # new producers {z,w} (forward-reachable from [z], minus prior nodes {a}) must be
  # SUB-BUILT before the reverse-cone fix, else `recompute a` throws "z missing".
  # w=7, z=50+7=57, a=1+57=58.
  npNodeData = {
    a = {
      weight = 1;
    };
    z = {
      weight = 50;
    };
    w = {
      weight = 7;
    };
  };
  npEdgesOf = id: if id == "z" then [ "w" ] else [ ];
  npAccessor = {
    nodes = [ "a" ]; # only a is live initially
    edges = npEdgesOf;
    nodeData = id: npNodeData.${id} or { };
    parent = _id: null;
  };
  npCtx = build {
    accessor = npAccessor;
    inherit recompute hashOf;
  };
  npDelta = applyEdgeDelta npCtx "a" [ "z" ];
  # a fresh dep target is built, not an "attribute missing" throw:
  npSucceeds = (builtins.tryEval (builtins.deepSeq npDelta.store true)).success;

  # ===== located cycle recheck ================================================
  # applyEdgeDelta c := [a] closes a→b→c→a. reCycleCheck (seeded at touched=[c])
  # must throw a LOCATED, tryEval-catchable blame — never Nix infinite recursion.
  cycleDelta = applyEdgeDelta chainCtx "c" [ "a" ];
  cycleIsCaught = !(builtins.tryEval (builtins.deepSeq cycleDelta true)).success;
  # the blame is LOCATED (carries the offending cycle), not a bare throw: we assert
  # the eval fails (above) — the located record is constructed in lib/structural.nix
  # and is the same shape build.nix throws (why="cycle"; cycle=[…]).

  # a NON-cycle-closing edge delta does NOT trip the recheck (sanity): repoint a to
  # read c — acyclic — succeeds.
  noCycleSucceeds = (builtins.tryEval (builtins.deepSeq edgeRepointed.store true)).success;

  # ===== trace.deps rewritten for edge-touched nodes ==========================
  # a's edge-set moved [b] → [c]; trace.a.deps MUST be the FRESH [c], not stale [b]
  # (else verify/support read stale deps — a soundness bug, §3.2).
  edgeTraceDeps = edgeRepointed.trace.a.deps;

  # ===== retract (recompute-without): delete c, splice out of b ===============
  # deadId=c. c removed from store+trace; b's edge [c] dropped (b→[]); reverse cone
  # {a,b} re-folded sans c. b=10, a=1+10=11. store has no c.
  retractC = retract chainCtx "c" "recompute-without";
  retractStoreA = retractC.store.a;
  retractStoreB = retractC.store.b;
  retractCremoved = !(retractC.store ? c);
  retractTraceCremoved = !(retractC.trace ? c);
  # b's trace.deps no longer names c (edge-touched node rewrite).
  retractTraceDepsB = retractC.trace.b.deps;

  # ===== retract error policy =================================================
  # default "error" (passed as null ⇒ error): c has a declared in-edge (b reads c)
  # ⇒ located blame, caught.
  retractErrorCaught =
    !(builtins.tryEval (builtins.deepSeq (retract chainCtx "c" null) true)).success;
  # retracting a node with NO declared in-edges (a — nothing reads a) under the
  # default error policy SUCCEEDS (and removes a + its now-dangling effects).
  retractRoot = retract chainCtx "a" null; # default error; a has no in-edges
  retractRootSucceeds = (builtins.tryEval (builtins.deepSeq retractRoot.store true)).success;
  retractRootAremoved = !(retractRoot.store ? a);

  # ===== chaining: applyEdgeDelta ∘ retract ∘ override ========================
  # Start chain a→b→c (1/10/100). Three edits, then compare to a from-scratch build
  # of the thrice-edited topology.
  #   (1) override c := 200   (data change)      ⇒ c=200, b=210, a=211
  #   (2) retract a           (node delete, error-ok: nothing reads a)
  #   (3) applyEdgeDelta b := [] (b stops reading c)
  # Final topology: nodes {b,c}, edges b→[] , c→[]; data c=200, b=10.
  #   b=10, c=200.
  chainStep1 = override chainCtx "c" { weight = 200; };
  chainStep2 = retract chainStep1 "a" null; # default error; a has no in-edges
  chainStep3 = applyEdgeDelta chainStep2 "b" [ ];
  # oracle: the thrice-edited from-scratch build.
  chainOracleAcc = graph.mkGraph {
    edges = [ ]; # a deleted, b no longer reads c, c is a leaf ⇒ no edges
    nodeData = {
      b = {
        weight = 10;
      };
      c = {
        weight = 200;
      };
    };
  };
  chainOracle = build {
    accessor = chainOracleAcc;
    inherit recompute hashOf;
  };
  chainEquiv = chainStep3.store == chainOracle.store;

  # ===== edge-varying 120-seed soundness ======================================
  # applyEdgeDelta-store == from-scratch build over the NEW topology accessor.
  # (Generator's accEdge keeps newEdges acyclic so the oracle can build.)
  edgeVarying =
    seed:
    let
      c = mkStructuralCase seed;
      ctx = build {
        accessor = c.acc;
        inherit (c) recompute hashOf;
      };
      delta = applyEdgeDelta ctx c.changedId c.newEdges;
      oracle = build {
        accessor = c.accEdge;
        inherit (c) recompute hashOf;
      };
    in
    delta.store == oracle.store;
  edgeVaryingFailing = builtins.filter (seed: !(edgeVarying seed)) (lib.range 1 120);

  # ===== retract 120-seed soundness (recompute-without) =======================
  # retract-store == build over the node-removed accessor.
  retractSound =
    seed:
    let
      c = mkStructuralCase seed;
      ctx = build {
        accessor = c.acc;
        inherit (c) recompute hashOf;
      };
      r = retract ctx c.deadId "recompute-without";
      oracle = build {
        accessor = c.accRetract;
        inherit (c) recompute hashOf;
      };
    in
    r.store == oracle.store;
  retractFailing = builtins.filter (seed: !(retractSound seed)) (lib.range 1 120);
in
{
  flake.tests.structural = {
    # ===== the structural soundness gates =====
    test-edge-varying-120-seeds = {
      expr = edgeVaryingFailing;
      expected = [ ];
    };
    test-retract-120-seeds = {
      expr = retractFailing;
      expected = [ ];
    };

    # ===== applyEdgeDelta hand pins =====
    test-edge-repoint-a = {
      expr = edgeRepointed.store.a;
      expected = 101;
    };
    test-edge-repoint-b-reused = {
      expr = edgeRepointed.store.b;
      expected = 110;
    };
    test-edge-repoint-c-reused = {
      expr = edgeRepointed.store.c;
      expected = 100;
    };

    # ===== dedup newEdges ([b c c] must not double-count) =====
    test-edge-dedup-a = {
      expr = edgeDedup.store.a;
      expected = 211;
    };

    # ===== new-producer sub-build (fresh dep target is built) =====
    test-new-producer-builds = {
      expr = npSucceeds;
      expected = true;
    };
    test-new-producer-a = {
      expr = npDelta.store.a;
      expected = 58;
    };
    test-new-producer-z = {
      expr = npDelta.store.z;
      expected = 57;
    };
    test-new-producer-w = {
      expr = npDelta.store.w;
      expected = 7;
    };

    # ===== located cycle recheck (caught, not infinite recursion) =====
    test-cycle-recheck-caught = {
      expr = cycleIsCaught;
      expected = true;
    };
    test-no-cycle-succeeds = {
      expr = noCycleSucceeds;
      expected = true;
    };

    # ===== trace.deps rewritten for edge-touched nodes =====
    test-edge-trace-deps-rewritten = {
      expr = edgeTraceDeps;
      expected = [ "c" ];
    };

    # ===== retract (recompute-without) hand pins =====
    test-retract-a = {
      expr = retractStoreA;
      expected = 11;
    };
    test-retract-b = {
      expr = retractStoreB;
      expected = 10;
    };
    test-retract-c-removed-store = {
      expr = retractCremoved;
      expected = true;
    };
    test-retract-c-removed-trace = {
      expr = retractTraceCremoved;
      expected = true;
    };
    test-retract-trace-deps-rewritten = {
      expr = retractTraceDepsB;
      expected = [ ];
    };

    # ===== retract error policy =====
    test-retract-error-blames-in-edges = {
      expr = retractErrorCaught;
      expected = true;
    };
    test-retract-error-root-ok = {
      expr = retractRootSucceeds;
      expected = true;
    };
    test-retract-root-removed = {
      expr = retractRootAremoved;
      expected = true;
    };

    # ===== chaining (structural ∘ structural ∘ data) == thrice-edited rebuild =====
    test-chain-structural-equiv = {
      expr = chainEquiv;
      expected = true;
    };
  };
}
