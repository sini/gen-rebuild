# drivers — Acar change/propagate split: applyDelta / batch / propagate / force.
#
# Locks the de-conflated change-vs-propagate semantics (Acar 2002 §4.3 change,
# §4.5 propagate-to-quiescence) and the fused law (§7 correctness): the chained
# `override` and the `batch |> propagate` agree on the store, and both agree
# with a from-scratch build over the same deltas. `force` is the Hammer 2014
# Adapton demand/pull entry point (full-drain G1: not selective per-edge).
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
    applyDelta
    batch
    propagate
    force
    forceCtx
    ;

  # ----- hand-built chain a -> b -> c (consumer→producer; `a` depends on `b`) --
  # node value = own weight + Σ dep values. ctx.store: c=100, b=110, a=111.
  recompute =
    a: s: id:
    (a.nodeData id).weight + lib.foldl' (sum: dep: sum + s.${dep}) 0 (a.edges id);
  hashOf = v: builtins.hashString "sha256" (builtins.toJSON v);
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

  # ===== applyDelta: data-change records dirtiness, recomputes NOTHING =====
  # Acar §4.3: change is the instantaneous δ ⊕ σ — it mutates the *input* and marks
  # the cone dirty, but performs NO recomputation. The store/trace stay STALE until
  # a propagate drains them. This is the pure set→force split (dirtiness as a value).
  staleC = applyDelta chainCtx "c" { weight = 200; };
  # accessor IS updated (the new data is readable)…
  staleAccessorUpdated = (staleC.accessor.nodeData "c").weight;
  # …but the store is byte-identical to the pre-change store (the stale-read trap).
  staleStoreUnchanged = staleC.store == chainCtx.store;
  staleTraceUnchanged = staleC.trace == chainCtx.trace;
  # the dirty seed is recorded for the eventual drain.
  stalePendingDirty = staleC.pending.dirty;

  # applyDelta is idempotent on its dirty-set (lib.unique): re-marking c once more
  # does not duplicate the seed.
  staleCC = applyDelta staleC "c" { weight = 200; };
  stalePendingUnique = staleCC.pending.dirty;

  # ===== propagate: drain dirty to quiescence, then idempotent / quiescent-noop ==
  # Acar §4.5: propagate replays the affected cone to a fixed point. After drain,
  # pending.dirty == [] (quiescent). c=200, b=210, a=211.
  drainedC = propagate staleC;
  drainedPending = drainedC.pending.dirty;
  # drained store equals the eager fused override store (change then drain == override).
  ovC = override chainCtx "c" { weight = 200; };
  drainEqualsOverride = drainedC.store == ovC.store;

  # propagate on an ALREADY-quiescent ctx is a no-op on store/trace (idempotent).
  # §4.5: a fixed point re-propagated stays put. (Carries pending.dirty = [].)
  reDrained = propagate drainedC;
  propagateIdempotent = reDrained.store == drainedC.store && reDrained.trace == drainedC.trace;
  # propagate on a freshly-built ctx (no `pending`) is a no-op: nothing to drain.
  freshDrained = propagate chainCtx;
  quiescentNoop = freshDrained.store == chainCtx.store && freshDrained.pending.dirty == [ ];

  # ===== batch: fold applyDelta over a list of deltas (Forgy N-token batch) =====
  # batch marks BOTH seeds dirty (still recomputes nothing); one propagate drains
  # the union region. Targets b and c here (b's cone overlaps c's at a).
  batched = batch chainCtx [
    {
      id = "c";
      newDecls = {
        weight = 200;
      };
    }
    {
      id = "b";
      newDecls = {
        weight = 20;
      };
    }
  ];
  batchStaleStore = batched.store == chainCtx.store; # still stale (recompute nothing)
  batchDirtySeeds = builtins.sort builtins.lessThan batched.pending.dirty;
  batchDrained = propagate batched;
  # c=200, b=20+200=220, a=1+220=221.
  batchDrainC = batchDrained.store.c;
  batchDrainB = batchDrained.store.b;
  batchDrainA = batchDrained.store.a;

  # ===== fusion law (120-seed, DATA-CHANGE): batch|>propagate == chained override ==
  # == from-scratch build over BOTH deltas. Acar §7: change/propagate is correct iff
  # it agrees with the reference (full) evaluator; §4.5 single-pass multi-seed drain
  # reaches the same fixed point as the chained per-delta drains (deltas commute,
  # edges fixed). Each seed picks a SECOND distinct node to change (rotate by +1),
  # so two cones (often overlapping) are exercised per seed.
  # index of changedId within ids (ids are "n0".."n{k}"; changedId is one of them).
  indexOf =
    xs: x:
    let
      pairs = lib.imap0 (i: v: { inherit i v; }) xs;
    in
    (lib.findFirst (p: p.v == x) { i = 0; } pairs).i;
  secondId =
    c:
    let
      n = builtins.length c.ids;
      i = indexOf c.ids c.changedId;
    in
    builtins.elemAt c.ids (lib.mod (i + 1) n);
  secondDecls = seed: {
    weight = 1 + lib.mod (seed * 37 + 11) 100;
  };
  fusionSound =
    seed:
    let
      c = mkCase seed;
      ctx = build {
        accessor = c.acc;
        inherit (c) recompute hashOf;
      };
      id2 = secondId c;
      d2 = secondDecls seed;
      # batch path: both deltas marked, one drain.
      batchPath = propagate (
        batch ctx [
          {
            id = c.changedId;
            newDecls = c.newDecls;
          }
          {
            id = id2;
            newDecls = d2;
          }
        ]
      );
      # chained path: override twice (each = propagate ∘ applyDelta).
      chainPath = override (override ctx c.changedId c.newDecls) id2 d2;
      # oracle: a from-scratch build over BOTH data-changes.
      acc'' = c.acc // {
        nodeData =
          id:
          if id == c.changedId then
            c.newDecls
          else if id == id2 then
            d2
          else
            c.acc.nodeData id;
      };
      oracle = build {
        accessor = acc'';
        inherit (c) recompute hashOf;
      };
    in
    batchPath.store == chainPath.store && chainPath.store == oracle.store;
  fusionFailingSeeds = builtins.filter (seed: !(fusionSound seed)) (lib.range 1 120);

  # ===== overlapping-cones equivalence (single union-cone fix == oracle) =====
  # Two deltas whose dependent cones OVERLAP. wide diamond: top → m1..m4 → base.
  # Change base (cone = everything) AND m2 (cone = {m2, top}) in one batch. The
  # single union-cone lib.fix must reach the same fixed point as a full rebuild —
  # the overlap at `top` is visited ONCE (lib.unique), not double-recomputed.
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
  diamondCtx = build {
    accessor = wideDiamond;
    inherit recompute hashOf;
  };
  overlapBatch = propagate (
    batch diamondCtx [
      {
        id = "base";
        newDecls = {
          weight = 99;
        };
      }
      {
        id = "m2";
        newDecls = {
          weight = 88;
        };
      }
    ]
  );
  overlapOracle = build {
    accessor = wideDiamond // {
      nodeData =
        id:
        if id == "base" then
          { weight = 99; }
        else if id == "m2" then
          { weight = 88; }
        else
          wideDiamond.nodeData id;
    };
    inherit recompute hashOf;
  };
  overlapEquiv = overlapBatch.store == overlapOracle.store;

  # ===== force / forceCtx: Adapton demand (Hammer 2014) =====
  # On a QUIESCENT ctx, force is a plain store read (no work). force chainCtx "a" = 111.
  forceQuiescent = force chainCtx "a";
  # On a PENDING ctx (stale-after-applyDelta), force DRAINS the cone then reads.
  # staleC marked c:=200 but recomputed nothing; force "a" must yield the drained
  # 211, NOT the stale 111. This is the full-drain demand (G1: not selective).
  forcePending = force staleC "a";
  # forceCtx returns { value; ctx; } with the QUIESCENT ctx for loop reuse:
  # value is the drained read AND the returned ctx is quiescent (pending.dirty == []).
  fcPending = forceCtx staleC "a";
  forceCtxValue = fcPending.value;
  forceCtxQuiescent = fcPending.ctx.pending.dirty;
  # the returned ctx is genuinely drained: re-reading c off it is the new value.
  forceCtxDrainedStore = fcPending.ctx.store.c;
in
{
  flake.tests.drivers = {
    # ===== applyDelta: change without recompute (stale-read trap) =====
    test-applyDelta-accessor-updated = {
      expr = staleAccessorUpdated;
      expected = 200;
    };
    test-applyDelta-store-stale = {
      expr = staleStoreUnchanged;
      expected = true;
    };
    test-applyDelta-trace-stale = {
      expr = staleTraceUnchanged;
      expected = true;
    };
    test-applyDelta-records-dirty = {
      expr = stalePendingDirty;
      expected = [ "c" ];
    };
    test-applyDelta-dirty-unique = {
      expr = stalePendingUnique;
      expected = [ "c" ];
    };

    # ===== propagate: drain to quiescence, idempotent, quiescent-noop =====
    test-propagate-resets-pending = {
      expr = drainedPending;
      expected = [ ];
    };
    test-propagate-equals-override = {
      expr = drainEqualsOverride;
      expected = true;
    };
    test-propagate-idempotent = {
      expr = propagateIdempotent;
      expected = true;
    };
    test-propagate-quiescent-noop = {
      expr = quiescentNoop;
      expected = true;
    };

    # ===== batch: N-token, still stale until one drain =====
    test-batch-store-stale = {
      expr = batchStaleStore;
      expected = true;
    };
    test-batch-records-both-seeds = {
      expr = batchDirtySeeds;
      expected = [
        "b"
        "c"
      ];
    };
    test-batch-drain-c = {
      expr = batchDrainC;
      expected = 200;
    };
    test-batch-drain-b = {
      expr = batchDrainB;
      expected = 220;
    };
    test-batch-drain-a = {
      expr = batchDrainA;
      expected = 221;
    };

    # ===== fusion law (120-seed): batch == chained override == full rebuild =====
    test-fusion-law-120-seeds = {
      expr = fusionFailingSeeds;
      expected = [ ];
    };

    # ===== overlapping cones: single union-cone fix == oracle =====
    test-overlapping-cones-equiv = {
      expr = overlapEquiv;
      expected = true;
    };

    # ===== force / forceCtx (Adapton demand) =====
    test-force-quiescent = {
      expr = forceQuiescent;
      expected = 111;
    };
    test-force-pending-drains = {
      expr = forcePending;
      expected = 211;
    };
    test-forceCtx-value = {
      expr = forceCtxValue;
      expected = 211;
    };
    test-forceCtx-returns-quiescent = {
      expr = forceCtxQuiescent;
      expected = [ ];
    };
    test-forceCtx-store-drained = {
      expr = forceCtxDrainedStore;
      expected = 200;
    };
  };
}
