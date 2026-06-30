# restabilize — per-member semi-naive SCC solver (runScc).
#
# Solves ONE strongly-connected component to its least fixed point by iterating
# each member's lattice from ⊥ (bottom) until per-member equality (quiescence).
# In-SCC deps read the CURRENT iterate; external (lower-stratum) deps read the
# fixed `store`/`higherStrata` — exactly what the merged `store // higherStrata
# // prev` provides to `recompute`.
#
# Theory citations:
#   - Arntzenius 2016 (Datafun Lemma 4): for a GENUINE-join (union/powerset, or
#     any finite-height bounded semilattice) lattice, iterate-from-⊥ ascends a
#     finite chain ⊥ ⊑ f(⊥) ⊑ f²(⊥) ⊑ … and converges at the lfp, detected by
#     eq-stabilization (prev == next). The reachability fixture is the ascent
#     witness: ⊥ = {} ⊑ {self} ⊑ {a,b}.
#   - Sloane 2010 §2.2 / Magnusson–Hedin (circular reference attributes): for an
#     OVERWRITE / no-op "join" (e.g. `join = _prev: v: v`) — which is NOT a
#     semilattice join, has no ⊑ order and no ascent witness — this is naive
#     iterate-to-stabilization: keep recomputing until the values stop moving.
#     Such fixtures converge by peer-agreement, NOT by lattice ascent.
#
# Honest gaps (load-bearing; consumer obligations, NOT checked here):
#   - MONOTONICITY of `recompute`/`join` is UNCHECKED. A non-monotone step can
#     oscillate forever (no Kleene/Arntzenius termination guarantee).
#   - FINITE HEIGHT of the lattice is UNCHECKED. An infinite-ascending chain
#     never quiesces.
#   - The ONLY divergence guard is per-member `maxIter`: on overrun, runScc
#     throws a LOCATED, tryEval-CATCHABLE blame (never Nix's uncatchable infinite
#     recursion). `widen` (applied after join, per-member) is the consumer's tool
#     to force finite ascent on tall/infinite lattices.
#   - This is OUTSIDE the rebuilder's acyclic envelope (build.nix prechecks
#     acyclicity and forbids cycles); runScc is the cyclic-stratum solver that
#     the acyclic build cannot express.
#
# `graph`/`scope` are threaded for sibling ops (restabilize lands beside this);
# runScc itself takes its topology via the `accessor` field.
{ prelude, graph, ... }:
let
  inherit (import ./hash.nix { }) hashGuarded hashMoved;

  # runScc — solve one SCC to its least fixed point (per-member iterate-from-⊥).
  #
  # runScc :: {
  #   accessor,            # any object exposing .edges / .nodeData (topology oracle)
  #   store,               # externals map (lower-stratum / fixed inputs)
  #   recompute,           # accessor -> store -> id -> value (the node-eval)
  #   scc,                 # [id] — the SCC member ids (M)
  #   higherStrata,        # { <id> = value } — already-solved lower-stratum results
  #   lattices,            # per-NODE { bottom; join; eq ? (==); widen ? null; maxIter ? 100; }
  # } -> { <id> = value }   # the fixed-point iterate for each SCC member
  runScc =
    {
      accessor,
      store,
      recompute,
      scc,
      higherStrata,
      lattices,
    }:
    let
      M = scc;
      # Per-member equality, defaulting to structural `==` when the lattice omits eq.
      eqOf = m: lattices.${m}.eq or (a: b: a == b);

      go =
        iter: prev:
        let
          # In-SCC deps read the current iterate (prev); externals read store /
          # higherStrata. The // merge gives `recompute` the unified view.
          cur = prelude.genAttrs M (m: recompute accessor (store // higherStrata // prev) m);
          # PINNED DETAIL 1: widen applies AFTER join, per-member.
          next = prelude.mapAttrs (
            m: _v:
            let
              j = lattices.${m}.join prev.${m} cur.${m};
            in
            if (lattices.${m}.widen or null) != null then lattices.${m}.widen prev.${m} j else j
          ) cur;
          maxI = prelude.foldl' (acc: m: prelude.max acc (lattices.${m}.maxIter or 100)) 0 M;
          # PINNED DETAIL 2: lastDelta = the still-moving members' prev/next pairs.
          moving = prelude.filter (m: !(eqOf m prev.${m} next.${m})) M;
          blame = {
            why = "fixpoint-diverged";
            scc = M;
            iters = iter;
            lastDelta = prelude.genAttrs moving (m: {
              prev = prev.${m};
              next = next.${m};
            });
          };
        in
        # maxIter-blame guard: a tryEval-CATCHABLE thrown blame, never Nix
        # infinite recursion.
        if iter >= maxI then
          throw "gen-rebuild: fixpoint did not converge: ${builtins.toJSON blame}"
        # Per-MEMBER eq: each node's OWN eq predicate drives its quiescence.
        else if prelude.all (m: eqOf m prev.${m} next.${m}) M then
          next
        else
          go (iter + 1) next;
    in
    # Per-member ⊥ seed (Arntzenius iterate-from-bottom).
    go 0 (prelude.genAttrs M (m: lattices.${m}.bottom));

  # restabilize — the CYCLIC-CAPABLE analogue of `override`.
  #
  # `restabilize ctx changedId newDecls` replaces changedId's nodeData, then
  # re-solves ONLY the dependent cone of changedId — acyclic cone strata by
  # recompute-and-splice (== override), cyclic cone strata by `runScc` (per-SCC
  # least fixed point) — reading every non-cone node out of the prior store
  # (held fixed). Requires `ctx.fixpoint != null` (build with a fixpoint first).
  # Returns an updated cyclic-capable BuiltCtx: `accessor` is the NEW topology
  # and `fixpoint` is threaded forward UNCHANGED, so restabilize ∘ restabilize
  # stays cyclic-capable.
  #
  # SOUNDNESS (read precisely — restabilize makes NO optimality claim):
  #   - Non-cone node n: n ∉ dependentsOf(changedId) ⇒ n does not transitively
  #     read changedId ⇒ its value is unchanged from ctx.store, which equals a
  #     from-scratch build over accessor' (Acar 2002 §4.5/§7 change propagation:
  #     only the cone re-evaluates; change propagation "yields essentially the
  #     same result as a complete re-execution on the changed inputs"). So the
  #     fold is SEEDED at ctx.store and non-cone strata are simply skipped.
  #   - ACYCLIC cone node: recomputed reading already-solved lower strata as
  #     externals ⇒ BYTE-IDENTICAL to a full rebuild's value. This is exactly
  #     v1 `override`'s guarantee, retained in full.
  #   - CYCLIC cone SCC (whole-SCC, because mutual reachability ⇒ all-or-none in
  #     the cone): `runScc` ascends to its lfp on the SAME finite-height
  #     semilattices with the SAME externals as a from-scratch build over
  #     accessor'. On a finite-height bounded semilattice the lfp is UNIQUE
  #     (Arntzenius 2016 Datafun Lemma 4), so restabilize's incremental cyclic
  #     solve and the full build coincide: FIXED-POINT-EQUALITY. This is NOT the
  #     v1 byte-identical-to-the-acyclic-fix property — it is equality of two
  #     fixpoint computations to the same unique lfp.
  #   - Under a NON-MONOTONE recompute the only guarantee is runScc's per-member
  #     maxIter located blame (a catchable throw, never Nix infinite recursion).
  #
  # EXPLICITLY OUTSIDE RTD 1983's acyclic envelope: RTD requires noncircularity,
  # and BOTH its O(|AFFECTED|) optimality bound and its never-assign-a-
  # non-final-value invariant break on cycles. restabilize claims neither — its
  # cost is O(height · |SCC| · recompute) per cyclic stratum (Arntzenius-grounded
  # Kleene ascent), RTD-disclaimed. The AFFECTED post-filter below is reused only
  # as a trace-pruning convenience (re-hash the cone nodes that actually moved),
  # NOT as an optimality claim.
  restabilize =
    ctx: changedId: newDecls:
    let
      fixpoint = ctx.fixpoint or null;

      # accessor' : prior topology with changedId's nodeData replaced. Edges fall
      # through to ctx.accessor (unchanged) ⇒ same cyclic set, same condensation.
      accessor' = ctx.accessor // {
        nodeData = id: if id == changedId then newDecls else ctx.accessor.nodeData id;
      };

      # Relaxed precheck on the new topology (edges fixed ⇒ same cyclic set, but
      # computed fresh to mirror build). A cyclic node lacking a lattice is a
      # LOCATED blame — restabilize's own check (build would have rejected the
      # fixpoint up front, but a post-build mutation can drop one).
      cyclic = graph.cycles accessor';
      missing = builtins.filter (id: !(fixpoint.lattices ? ${id})) cyclic;
      undeclaredBlame = {
        why = "undeclared-cyclic-node";
        nodes = missing;
        cycle = cyclic;
      };

      cond = graph.condensation accessor';
      cyclicSet = prelude.genAttrs cyclic (_: true);

      # Dependent cone of changedId (reverse reachability; valid on cyclic
      # graphs — Arntzenius 2016 reverse reachability).
      cone = prelude.unique ([ changedId ] ++ graph.dependentsOf accessor' changedId);
      coneSet = prelude.genAttrs cone (_: true);

      # Bottom-up fold (producers-first over the condensation), accumulator SEEDED
      # at ctx.store: non-cone strata are skipped (their ctx.store values are
      # unaffected by a data change to changedId and stay), cone strata are
      # re-solved reading acc (already-solved lower strata) as externals.
      solved = prelude.foldl' (
        acc: tag:
        let
          members = cond.members tag;
          coneMembers = builtins.filter (m: coneSet ? ${m}) members;
          isCyclicStratum = builtins.any (m: cyclicSet ? ${m}) members;
        in
        if coneMembers == [ ] then
          # Stratum untouched by the cone: keep its ctx.store values verbatim.
          acc
        else if isCyclicStratum then
          # Whole SCC is in the cone (mutual reachability ⇒ all-or-none); re-solve
          # the component once to its lfp, reading acc (lower strata) as externals.
          acc
          // runScc {
            inherit recompute;
            accessor = accessor';
            store = { };
            scc = members;
            higherStrata = acc;
            lattices = fixpoint.lattices;
          }
        else
          # Acyclic cone singleton: recompute reading acc (lower strata) as
          # externals. Byte-identical to a full rebuild's value (== override).
          acc // prelude.genAttrs coneMembers (m: recompute accessor' acc m)
      ) ctx.store cond.bottomUp;

      store = solved;
      newHashOf = id: hashGuarded hashOf store.${id};
      # AFFECTED = the cone nodes whose hash actually moved (RTD §4.3 post-filter,
      # null-safe). Reused/unaffected cone nodes keep their prior trace entry.
      affected = builtins.filter (id: hashMoved (newHashOf id) (ctx.trace.${id}.hash or null)) cone;
      trace' =
        ctx.trace
        // prelude.genAttrs affected (id: {
          deps = accessor'.edges id;
          hash = newHashOf id;
        });

      # recompute / hashOf come from ctx; fixpoint is threaded forward unchanged.
      inherit (ctx) recompute hashOf;
    in
    if fixpoint == null then
      throw "gen-rebuild: restabilize requires ctx.fixpoint (build with a fixpoint param first)"
    else if missing != [ ] then
      throw "gen-rebuild: undeclared cyclic node: ${builtins.toJSON undeclaredBlame}"
    else
      {
        store = store;
        trace = trace';
        accessor = accessor';
        inherit recompute hashOf fixpoint;
      };
in
{
  inherit runScc restabilize;
}
