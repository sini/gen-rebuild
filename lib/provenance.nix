# provenance — the pure read layer over the verifying trace + adg reachability.
#
# Zero recompute, zero force-order observation: support/why/whyNot answer
# "what justifies this value" and "would an override touch this node" purely from
# ctx.trace + gen-graph queries over ctx.accessor.
#
#   support : the transitive declared PRODUCERS of a node — Acar 2002 adg (§4.4)
#     read in the IN-EDGE / BACKWARD direction (the adg itself is forward
#     source→target; support is the dual of `affected`). Reads the trace SNAPSHOT
#     deps so it stays consistent with the committed override. Only NAME-faithful
#     to Radul 2009 §6.1 support-set (no TMS, no merge-lattice, no worldviews —
#     ours is the structural declared-edge producer set, not a minimal-premise set
#     after a lattice merge).
#
#   why : the verdict an override of `changedId` would produce for `id`. Acar 2002
#     §7 read-rule, reframed: l∈C → recomputed, cmp-unchanged → cutoff, l∉C →
#     unaffected. `graph.canReach ctx.accessor id changedId` is the single
#     O(reachable) verdict fast path (forward edges — NOT transposed: dependentsOf/
#     canReach already traverse consumer→producer directly). `graph.pathsBetween`
#     (exponential worst case) is reserved for explain-mode + the cutoff overlay.
#
#   whyNot : the negative operator query — null when recomputed, else the reason.
#
# Edge convention: accessor.edges id = ids `id` depends on (consumer→producer); an
# override of `changedId` recomputes its dependent cone, i.e. every `id` that can
# REACH `changedId` over forward edges.
{ prelude, graph, ... }:
let
  sort = builtins.sort builtins.lessThan;

  # support : BuiltCtx -> id -> [id]
  # Transitive declared producers of `id`, sorted, `id` excluded. Edges are read
  # from the trace snapshot (falling back to the live accessor for any id the
  # trace has no entry for) so support is consistent with the committed override.
  # reachableFrom already excludes the start node.
  support =
    ctx: id:
    sort (
      graph.reachableFrom {
        edges = id': ctx.trace.${id'}.deps or (ctx.accessor.edges id');
      } id
    );

  # supportDirect : the depth-1 declared producers (sorted) — the immediate
  # in-edges from the trace snapshot, without the transitive closure.
  supportDirect = ctx: id: sort (ctx.trace.${id}.deps or (ctx.accessor.edges id));

  # why : BuiltCtx -> { id; changedId; cutoffs ? {} } -> WhyResult
  #   WhyResult = { verdict = "unaffected"; }
  #             | { verdict = "recomputed"; paths :: [[id]]; }   (paths only in explain/overlay)
  #             | { verdict = "cutoff"; cutNodes :: [id]; paths :: [[id]]; }
  # The verdict fast path (canReach) answers unaffected/recomputed in O(reachable)
  # and carries NO paths key when `cutoffs == {}`; paths/cutNodes are materialized
  # only under a non-empty cutoff overlay (or explain mode).
  why =
    ctx:
    {
      id,
      changedId,
      cutoffs ? { },
    }:
    let
      # l∈C : `id` is in changedId's recompute cone iff it can reach changedId over
      # forward edges (or IS changedId — the change origin, always recomputed). No
      # transpose: canReach already walks consumer→producer.
      reachable = id == changedId || graph.canReach ctx.accessor id changedId;
    in
    if !reachable then
      # l∉C — no forward path id → changedId.
      { verdict = "unaffected"; }
    else if cutoffs == { } then
      # Verdict-only fast path: in the cone with no cutoff overlay ⇒ recomputed,
      # never synthesize an unwitnessed cutoff (a missing/absent overlay is pure
      # topological why).
      { verdict = "recomputed"; }
    else
      # Explain / cutoff-overlay mode: enumerate the acyclic paths id → changedId.
      # A path's INTERIOR (RTD-style cmp-unchanged cut points) is the nodes strictly
      # between id and changedId; changedId is NEVER an interior node (you cannot cut
      # the change origin). interior p = prelude.init (prelude.tail p): tail drops `id`, init
      # drops `changedId` — a direct edge [id, changedId] has interior [].
      let
        paths = graph.pathsBetween ctx.accessor id changedId;
        interior = p: prelude.init (prelude.tail p);
        # A node cuts a path iff the overlay marks it true AND it is hashable: a
        # null-hash node is always-dirty and can NEVER be a cutoff (missing overlay
        # key reads false via `or false`).
        isCut = n: (cutoffs.${n} or false) && (ctx.trace.${n}.hash or null) != null;
        # Per-path witness: the first interior cut node, or null if the path is LIVE.
        cutWitness =
          p:
          let
            cuts = builtins.filter isCut (interior p);
          in
          if cuts == [ ] then null else builtins.head cuts;
        witnesses = map cutWitness paths;
        # Every path blocked ⇒ cutoff; cutNodes = the deduped sorted SET of witnesses
        # (one per blocked path — when different paths are cut by different nodes
        # there is no single common cutAt). A live path (null witness) ⇒ recomputed.
        allBlocked = builtins.all (w: w != null) witnesses;
        cutNodes = sort (prelude.unique (builtins.filter (w: w != null) witnesses));
      in
      if allBlocked then
        {
          verdict = "cutoff";
          inherit cutNodes paths;
        }
      else
        {
          verdict = "recomputed";
          inherit paths;
        };

  # whyNot : the negative wrapper — null when `id` WAS recomputed (no "why not"),
  # else a reason record naming the verdict (and the cut witnesses for a cutoff).
  whyNot =
    ctx: args:
    let
      r = why ctx args;
    in
    if r.verdict == "recomputed" then
      null
    else if r.verdict == "cutoff" then
      {
        reason = "cutoff";
        at = r.cutNodes;
      }
    else
      { reason = "unaffected"; };
in
{
  inherit
    support
    supportDirect
    why
    whyNot
    ;
}
