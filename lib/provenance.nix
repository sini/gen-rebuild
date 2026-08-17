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
#     Θ( Σ_{u ∈ reach id} (1 + outdeg u) ) verdict fast path — reducing to the
#     cone's size only at BOUNDED out-degree, Θ(n²) on a complete DAG, since the
#     operator re-reads `edges` at every visit (forward edges — NOT transposed:
#     dependentsOf/canReach already traverse consumer→producer directly).
#     `graph.pathsBetween` (exponential worst case) is reserved for explain-mode +
#     the cutoff overlay.
#
#   whyNot : the negative operator query — null when recomputed, else the reason.
#
#   whyFor / whyNotFor : the AMORTIZED DUALS, curried on `changedId`. The membership
#     decision is loop-invariant across the ids of one change, so a caller asking it
#     of many ids binds the cone once (Arntzenius 2016 Datafun reverse reachability,
#     via `dirtySet`) and spends it, instead of issuing one forward query per id.
#     `why`/`whyNot` are UNCHANGED and keep the point query — the amortization is a
#     decision the CALLER makes, never a cost imposed on the caller asking once.
#
# Edge convention: accessor.edges id = ids `id` depends on (consumer→producer); an
# override of `changedId` recomputes its dependent cone, i.e. every `id` that can
# REACH `changedId` over forward edges.
{ prelude, graph, ... }@args:
let
  sort = builtins.sort builtins.lessThan;

  # The cone operator, imported directly rather than reached through the library
  # value: one definition of the dependent cone, shared by the dual below.
  inherit (import ./dirtySet.nix args) dirtySet;

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

  # _verdict : BuiltCtx -> { changedId; cutoffs } -> (id -> bool) -> id -> WhyResult
  #   WhyResult = { verdict = "unaffected"; }
  #             | { verdict = "recomputed"; paths :: [[id]]; }   (paths only in explain/overlay)
  #             | { verdict = "cutoff"; cutNodes :: [id]; paths :: [[id]]; }
  #
  # THE VERDICT, WITH THE l∈C DECISION AS ITS ONLY PARAMETER. Acar 2002 §7 read-rule:
  # l∈C → recomputed, cmp-unchanged → cutoff, l∉C → unaffected — the rule is the same
  # whoever decides membership. The entry points below hand it different oracles (a
  # forward point query, or a cone bound once) and differ in NOTHING else; a second
  # copy of these three branches would make the two answers agree by coincidence
  # rather than by construction.
  _verdict =
    ctx:
    { changedId, cutoffs }:
    member: id:
    if !(member id) then
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
        # THE ORIGIN'S SELF-PATH IS THE SINGLETON, AND ITS INTERIOR IS EMPTY BY THE
        # DEFINITION ABOVE, not by a carve-out: `pathsBetween x x` is [ x ], whose endpoints
        # coincide, so no node lies strictly between them. `tail` leaves [ ] and `init [ ]`
        # refuses — a prelude list primitive naming neither the origin nor the query — so
        # the guard is what makes `interior` total on the paths `pathsBetween` actually
        # returns. It changes no other answer: every path of length ≥ 2 takes the same
        # `init (tail p)` it always did, and an empty interior cuts nothing, which is the
        # rule the origin already had ("changedId is NEVER an interior node").
        interior = p: if builtins.length p < 2 then [ ] else prelude.init (prelude.tail p);
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

  # why : BuiltCtx -> { id; changedId; cutoffs ? {} } -> WhyResult
  # The verdict fast path (canReach) answers unaffected/recomputed in
  # Θ( Σ_{u ∈ reach id} (1 + outdeg u) ) — reducing to the cone's size only at
  # BOUNDED out-degree — and carries NO paths key when `cutoffs == {}`;
  # paths/cutNodes are materialized only under a non-empty cutoff overlay (or
  # explain mode).
  why =
    ctx:
    {
      id,
      changedId,
      cutoffs ? { },
    }:
    # l∈C : `id` is in changedId's recompute cone iff it can reach changedId over
    # forward edges (or IS changedId — the change origin, always recomputed). No
    # transpose: canReach already walks consumer→producer.
    _verdict ctx { inherit changedId cutoffs; } (
      i: i == changedId || graph.canReach ctx.accessor i changedId
    ) id;

  # whyFor : BuiltCtx -> { changedId; cutoffs ? {} } -> id -> WhyResult
  #
  # THE AMORTIZED DUAL OF `why`, CURRIED ON THE CHANGE. Membership in changedId's
  # recompute cone is loop-invariant across the ids of one change, exactly as a
  # traversal's per-visit edge wrapping is loop-invariant across the traversals of
  # one accessor — and it is resolved the same way the graph layer resolves that
  # one: a SEPARATE operator the caller binds once and spends, rather than a change
  # to the per-call form. A caller asking about one id must not be made to pay for a
  # whole reverse index, so `why` keeps its contract and the amortization stays a
  # decision the CALLER takes by reaching for this function.
  #
  # The cone is Arntzenius 2016 Datafun single-target reverse reachability (`dirtySet`
  # over `graph.dependentsOf`), so the bound is that operator's, paid ONCE per
  # `changedId` rather than once per id: Θ(n + E) to build the reverse index — it reads
  # EVERY node's out-edges, reachable or not — then a BFS over that index costing
  #   Θ( Σ_{u ∈ reach⁻ changedId} (1 + indeg u) )
  # → reducing to the cone's size only where in-degree is BOUNDED, and never falling
  # below the Θ(n + E) the index build pays whatever the cone's size. Membership is
  # then a lookup: the cone is INDEXED with genAttrs, never scanned as a list — a
  # closed-over list would trade a query per id for a scan per id.
  #
  # ONLY THE MEMBERSHIP DECISION IS AMORTIZED. Under a non-empty cutoff overlay the
  # verdict still enumerates paths per id through `graph.pathsBetween` (exponential
  # worst case), identically to `why`: the cone decides who is in the cone, never
  # which paths are cut. No claim is made here about the overlay path's cost.
  whyFor =
    ctx:
    {
      changedId,
      cutoffs ? { },
    }:
    let
      # Bound HERE — once per (ctx, changedId), whatever the caller spends it on.
      cone = prelude.genAttrs (dirtySet ctx [ changedId ]) (_: true);
    in
    _verdict ctx { inherit changedId cutoffs; } (i: cone ? ${i});

  # whyNot : the negative wrapper — null when `id` WAS recomputed (no "why not"),
  # else a reason record naming the verdict (and the cut witnesses for a cutoff).
  # The mapping is defined ONCE so the dual below wraps the same contract rather
  # than a second transcription of it.
  _reason =
    r:
    if r.verdict == "recomputed" then
      null
    else if r.verdict == "cutoff" then
      {
        reason = "cutoff";
        at = r.cutNodes;
      }
    else
      { reason = "unaffected"; };

  whyNot = ctx: args: _reason (why ctx args);

  # whyNotFor : `whyFor`'s cone with `whyNot`'s record — the amortized dual of the
  # negative query, wrapping `whyFor` exactly as `whyNot` wraps `why`. A caller
  # looping the negative query has the same loop-invariant to hoist as one looping
  # the positive, and leaving it out would amortize half of a uniform surface.
  whyNotFor =
    ctx: args:
    let
      verdictFor = whyFor ctx args;
    in
    id: _reason (verdictFor id);
in
{
  inherit
    support
    supportDirect
    why
    whyFor
    whyNot
    whyNotFor
    ;
}
