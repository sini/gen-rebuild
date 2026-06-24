# spike/vpush.nix — the PRIMARY minimality variant: rank-ordered eager-push.
#
# V-push drains the cone in ONE rank-ascending pass (producers before consumers,
# via spike/topo.nix's coneRank). It recomputes ONLY enqueued nodes; a moved node
# enqueues its DIRECT dependents (spike/revadj.nix); a no-move node CUTS OFF
# (enqueues nothing). Result store = priorStore // settled.
#
# WHY IT IS BYTE-IDENTICAL TO A FROM-SCRATCH BUILD (the two-clause soundness):
#   (A) every node that ACTUALLY MOVES is enqueued — its lowest-rank moved dep
#       enqueues it (rank order guarantees that dep is recomputed first, so its
#       move is observed before the consumer's slot). The seed enqueues the
#       changed ids; thereafter each move fans out to direct dependents.
#   (B) `settled` never holds a stale value (a node is written only when its turn
#       comes AND it is enqueued), and `priorStore` (= ctx.store) carries EVERY
#       unmoved node — including in-cone nodes that were cut off from enqueue. So
#       `ctx.store // settled` is final everywhere.
#
# The §4(B) carry: recompute reads `ctx.store // st.settled`, NOT bare
# `st.settled` — a recomputed node's deps may be NON-CONE (only in priorStore) or
# in-cone-but-unmoved (cut off, never written to settled). Bare settled would miss
# both ⇒ unsound. The `ctx.store //` base supplies them.
#
# Edge convention (gen-rebuild): `accessor.edges id = [producers]` (consumer→
# producer). directDependents.${id} is id's immediate reverse neighbours; a sink
# has no key ⇒ `or [ ]`.
#
# `changes :: { <id> = newDecls; }` is the multi-seed variant calling convention
# (== fixture.changes). Edges are FIXED (data-change envelope), so the cone over
# the changed accessor equals the cone over the prior accessor.
{
  lib,
  graph,
  genRebuild,
  topo,
  revadj,
  instrument,
}:
let
  inherit (import ../lib/hash.nix { }) hashGuarded hashMoved;
in
{
  vpush =
    ctx: changes:
    let
      changedIds = builtins.attrNames changes;

      # accessor' : prior topology with the changed nodeData overlaid. Edges fall
      # through to ctx.accessor (unchanged) ⇒ the prior cone stays valid.
      accessor' = ctx.accessor // {
        nodeData = id: changes.${id} or (ctx.accessor.nodeData id);
      };

      # Over-approx cone of ALL changed ids (multi-seed).
      cone = lib.unique (changedIds ++ lib.concatMap (graph.dependentsOf accessor') changedIds);

      # Cone-local producers-first rank (order + precompute) and the DIRECT
      # reverse-adjacency restricted to the cone.
      r = topo.coneRank accessor' cone;
      dd = revadj.directDependents accessor' cone;

      # Seed the worklist with the changed ids (they are the only roots that move
      # without an upstream push).
      seed0 = lib.genAttrs changedIds (_: true);

      # Per-node step over the rank-ascending order. Carries:
      #   enqueued   — set of ids scheduled for recompute (the worklist).
      #   settled    — { <id> = freshValue; } for recomputed nodes.
      #   recomputed — the recomputed ids, in order (the work metric).
      #   sweep      — drive-sweep force count (one per visited node).
      step =
        st: id:
        if !(st.enqueued ? ${id}) then
          # Not enqueued ⇒ cut off: skip the recompute, just advance the sweep.
          st // { sweep = st.sweep + 1; }
        else
          let
            # §4(B) carry: read non-cone + unmoved-in-cone deps from priorStore.
            v = ctx.recompute accessor' (ctx.store // st.settled) id;
            # Null-safe move test (unhashable ⇒ always-dirty, see lib/hash.nix): do NOT
            # collapse to `hash != prior` — null == null is true ⇒ false-clean ⇒ unsound.
            moved = hashMoved (hashGuarded ctx.hashOf v) (ctx.trace.${id}.hash or null);
          in
          st
          // {
            sweep = st.sweep + 1;
            settled = st.settled // {
              ${id} = v;
            };
            recomputed = st.recomputed ++ [ id ];
            # A move fans out to direct dependents; a no-move enqueues nothing.
            enqueued = if moved then st.enqueued // lib.genAttrs (dd.${id} or [ ]) (_: true) else st.enqueued;
          };

      final = lib.foldl' step {
        enqueued = seed0;
        settled = { };
        recomputed = [ ];
        sweep = 0;
      } r.order;

      n = builtins.length final.recomputed;
    in
    {
      store = ctx.store // final.settled;
      # EXPOSED: Task 6's negative control (cutoff-join) reads `settled` directly.
      settled = final.settled;
      metrics = instrument.mkMetrics {
        recomputed = n;
        hashed = n;
        allocated = n;
        precompute = r.precompute;
        driveSweep = final.sweep;
        cone = builtins.length cone;
      };
    };
}
