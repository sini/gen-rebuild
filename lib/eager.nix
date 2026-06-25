# propagateEager — the cut-heavy fast path for incremental rebuild (eager-push V-push).
#
# Rank-ordered eager-push propagate: recompute ONLY enqueued nodes in producers-first rank
# order; on a moved node enqueue its DIRECT in-cone dependents; cut off on no-move.
# store = ctx.store // settled (the §4(B) carry: unmoved + non-cone deps come from priorStore).
# BYTE-IDENTICAL to propagate/build (RTD 1983 §4.3/§5 eager topological push).
#
# WHEN TO USE: localized (cut-heavy) edits — it constructs only O(|AFFECTED|+frontier) nodes
# vs propagate's O(|cone|). Opt-in: `propagate` stays the general default.
#
# Honest envelope (preconditions; out-of-envelope ⇒ use propagate):
#   - DATA-change only: `changes` replaces nodeData; EDGES ARE FIXED (cone over accessor' ==
#     cone over ctx.accessor), exactly like override.
#   - ACYCLIC cone: graph.coneRank requires it (a cyclic cone makes its lib.fix recurrence
#     self-referential ⇒ uncatchable infinite recursion). Cyclic stays in restabilize/runScc.
#   - COST: a constant-factor win on the EXPENSIVE axis (recompute/hash/alloc) for cut-heavy
#     edits; it still pays O(|cone|) cheap drive bookkeeping (rank + sweep), so it is NOT a
#     total-work O(|AFFECTED|) bound (v3 minimality spike verdict: PARTIAL — sub-cone on
#     cut-heavy, no asymptotic minimality in pure substrate).
{ lib, graph, ... }:
let
  inherit (import ./hash.nix { }) hashGuarded hashMoved;
in
{
  propagateEager =
    ctx: changes:
    let
      changedIds = builtins.attrNames changes;
      accessor' = ctx.accessor // {
        nodeData = id: changes.${id} or (ctx.accessor.nodeData id);
      };
      cone = lib.unique (changedIds ++ lib.concatMap (graph.dependentsOf accessor') changedIds);
      coneSet = lib.genAttrs cone (_: true);
      rank = graph.coneRank accessor' cone;
      revAll = graph.directDependents accessor'; # FULL direct reverse-adjacency map
      # Restrict to cone: a moved node enqueues only its IN-CONE direct dependents. gen-graph
      # publishes the full map (the cone restriction is the caller's job); do NOT drop the
      # filter to `revAll.${id}` — out-of-cone dependents would be recomputed + wrongly re-hashed.
      ddCone = id: builtins.filter (c: coneSet ? ${c}) (revAll.${id} or [ ]);
      step =
        st: id:
        if !(st.enqueued ? ${id}) then
          st
        else
          let
            v = ctx.recompute accessor' (ctx.store // st.settled) id; # §4(B) carry
            # null-safe move test (unhashable ⇒ always-dirty, lib/hash.nix); do NOT collapse to `!=`.
            moved = hashMoved (hashGuarded ctx.hashOf v) (ctx.trace.${id}.hash or null);
          in
          st
          // {
            settled = st.settled // {
              ${id} = v;
            };
            enqueued = if moved then st.enqueued // lib.genAttrs (ddCone id) (_: true) else st.enqueued;
            affected = if moved then st.affected ++ [ id ] else st.affected;
          };
      final = lib.foldl' step {
        enqueued = lib.genAttrs changedIds (_: true);
        settled = { };
        affected = [ ];
      } rank.order;
      store = ctx.store // final.settled;
      trace' =
        ctx.trace
        // lib.genAttrs final.affected (id: {
          deps = accessor'.edges id;
          hash = hashGuarded ctx.hashOf store.${id};
        });
    in
    {
      inherit store;
      trace = trace';
      accessor = accessor';
      inherit (ctx) recompute hashOf;
    };
}
