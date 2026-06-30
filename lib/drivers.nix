# drivers — Acar change/propagate split: applyDelta + propagate + force
#
# De-conflates Acar's change (δ ⊕ σ, instantaneous data-change) from propagate
# (drain dirty-set to quiescence over the dependency cone). `override` is the
# fused convenience: `override = propagate ∘ applyDelta`.
#
# Theory citations:
#   - Acar 2002 §4.3 (change), §4.5 (propagate algorithm), §7 (correctness)
#   - Forgy 1982 (token vocabulary: Acar's δ ⊕ σ is Forgy's `+` change token)
#   - Hammer 2014 (Adapton force/demand; note: our force is full-drain, not
#     Adapton's selective per-edge repair — dropped S6)
#
# Honest gaps (load-bearing; stated in code):
#   - (G1) FORCE NOT SELECTIVE: full cone/frontier drain vs Adapton's demand-
#     ordered per-edge cutoff (needs mutable dirty flags + order — the dropped S6;
#     impure, and the v3 minimality spike confirmed it is unreachable in pure eval).
#   - (G2) FLAT REVERSE-CONE FRONTIER: O(|cone|) worst-case here. The cut-heavy
#     expensive-axis win (construct only O(|AFFECTED|+frontier) on localized edits)
#     SHIPPED as `propagateEager` (lib/eager.nix). True total-work O(|AFFECTED|) (RTD
#     S7 characteristic-graph cutoff edges) is NOT reachable in pure single-eval (v3
#     spike verdict: PARTIAL) — it needs the deferred cross-eval substrate
#     (gen-specs/gen-rebuild/FUTURE_WORK.md), not a pure v3 component.
#   - (G3) FUSED-LAW specialized to no-fresh-ids (stable contract ids) —
#     data-change only, edges fixed.
#
{ prelude, graph, ... }:
let
  inherit (import ./hash.nix { }) hashGuarded hashMoved;
  inherit (import ./strategies.nix { }) needsEval;
in
rec {
  # applyDelta — data-change only; return stale-pending ctx.
  # Rewrites changedId's nodeData, appends changedId to pending.dirty,
  # recomputes NOTHING. The store/trace are out-of-sync until propagate.
  # This is the pure set/force split: dirtiness as a VALUE, not a mutated flag.
  applyDelta =
    ctx: changedId: newDecls:
    let
      accessor' = ctx.accessor // {
        nodeData = id: if id == changedId then newDecls else ctx.accessor.nodeData id;
      };
      pendingDirty = (ctx.pending.dirty or [ ]) ++ [ changedId ];
      pendingClean = prelude.unique pendingDirty;
    in
    {
      store = ctx.store;
      trace = ctx.trace;
      accessor = accessor';
      inherit (ctx) recompute hashOf;
      pending = {
        dirty = pendingClean;
      };
    };

  # batch — fold applyDelta over a list of deltas.
  # Acar Forgy N-token batch: one applyDelta per delta, then one propagate
  # drains the union region.
  batch = ctx: deltas: prelude.foldl' (acc: delta: applyDelta acc delta.id delta.newDecls) ctx deltas;

  # propagate — drain pending.dirty to quiescence via union-cone fix.
  # Acar §4.3 drain-to-quiescence. The seeds are `pending.dirty`; we compute
  # the union-cone (all dependents reachable via forward deps), then splice it
  # via prelude.fix with needsEval-gated recompute (exactly like P2 override but
  # over a multi-seed union-cone instead of per-override cone). Re-hash ONLY
  # affected nodes (post-filter from hashes).
  #
  # SOUNDNESS GUARD (asserted here): edges are FIXED. A hash-equal node under
  # fixed edges yields hash-equal dependents, so any early-cutoff is sound.
  # Structural deltas (edge changes) break this guard; they are handled
  # separately (lib/structural.nix).
  propagate =
    ctx:
    let
      pending = ctx.pending or { dirty = [ ]; };
      seeds = pending.dirty;
      # No-op on quiescent (empty pending).
      hasWork = seeds != [ ];
    in
    if !hasWork then
      ctx
      // {
        pending = {
          dirty = [ ];
        };
      }
    else
      let
        inherit (ctx)
          recompute
          hashOf
          trace
          accessor
          ;
        accessor' = ctx.accessor; # edges fixed

        # Union-cone: seeds + their dependents (entire affected region).
        unionCone = prelude.unique (seeds ++ prelude.concatMap (graph.dependentsOf accessor') seeds);
        unionSet = prelude.genAttrs unionCone (_: true);
        seedSet = prelude.genAttrs seeds (_: true);
        newHashOf = id: hashGuarded hashOf builtStore.${id};

        # Multi-seed splice: single prelude.fix over the union-cone.
        # Reuse nodes with no moved-hash deps; recompute those that do (or are changed).
        builtStore =
          ctx.store
          // prelude.fix (
            s:
            prelude.genAttrs unionCone (
              id:
              let
                spliced = ctx.store // s;
                # EVERY seed is a forced recompute, not just the first. needsEval's
                # `id == changedId` clause fires for a SINGLE changed input; a batch
                # has N changed inputs (Acar §4.3: each δ ⊕ σ dirties its own node),
                # so a seed whose OWN data changed must recompute even when its dep
                # hashes did not move (its value comes from the new nodeData, not from
                # a moved dependency). Gating on only `prelude.head seeds` would reuse the
                # other seeds' STALE values — an unsound early-cutoff (RTD §5.3 only
                # licenses reuse for nodes whose inputs are ALL unchanged).
                isSeed = seedSet ? ${id};
                # The dependents (non-seed cone nodes) still ride the hash-moved gate,
                # seeded at the head — they recompute iff a cone dep's hash moved.
                seedForPredicate = prelude.head seeds;
                mustEval =
                  isSeed
                  || needsEval {
                    inherit trace;
                    coneSet = unionSet;
                    inherit newHashOf accessor';
                  } seedForPredicate id;
              in
              if mustEval then recompute accessor' spliced id else ctx.store.${id}
            )
          );

        # Re-hash ONLY affected nodes (post-filter from hashes).
        # Reused nodes keep their prior trace entry byte-identical.
        affectedInUnion = builtins.filter (
          id: hashMoved (newHashOf id) (ctx.trace.${id}.hash or null)
        ) unionCone;

        trace' =
          ctx.trace
          // prelude.genAttrs affectedInUnion (id: {
            deps = accessor'.edges id;
            hash = newHashOf id;
          });
      in
      {
        store = builtStore;
        trace = trace';
        accessor = accessor';
        inherit recompute hashOf;
        pending = {
          dirty = [ ];
        };
      };

  # force — pull-semantics entry point: quiescent → value; pending → drain + read.
  # Adapton demand/pull interface. On a pending ctx, forces the full cone drain,
  # then reads the value. This is crude full-drain semantics (G1 gap: not
  # selective per-edge repair).
  force =
    ctx: id:
    let
      quiescent = propagate ctx;
    in
    quiescent.store.${id};

  # forceCtx — pull-semantics returning quiescent ctx (loop-safe).
  # Drain once, reuse the quiescent ctx for efficiency.
  forceCtx =
    ctx: id:
    let
      quiescent = propagate ctx;
    in
    {
      value = quiescent.store.${id};
      ctx = quiescent;
    };

  # override — FUSED convenience: propagate ∘ applyDelta.
  # Byte-identical to v1 override on .store/.trace for data-change (edges fixed).
  # Additionally carries pending.dirty = [] (quiescent).
  #
  # FUSION LAW (data-change, edges fixed):
  #   override (override ctx a x) b y == propagate (applyDelta (applyDelta ctx a x) b y)
  # — deltas commute when targets disjoint; single union-cone fix reaches same
  # fixed point as chained fixes.
  override =
    ctx: changedId: newDecls:
    propagate (applyDelta ctx changedId newDecls);
}
