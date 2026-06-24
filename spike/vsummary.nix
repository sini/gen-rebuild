# spike/vsummary.nix — the SECONDARY minimality variant: summary-hash region reuse.
#
# V-summary is an EXPECTED NO-GO, raced only to EMIT the no-go evidence (Mokhov
# 2018 §4.2.4: a deep CONSTRUCTIVE trace "cannot support early cutoff … other than
# at n levels of dependencies"). It is DELIBERATELY MINIMAL — it exists to be
# MEASURED, not optimised. Do not add a clever region scheme; the straightforward
# deep-constructive-trace summary below is exactly enough to show (a) soundness,
# (b) the quadratic summaryForces, (c) the no-early-cutoff.
#
# REGION MODEL (the simplest sound one). A node's REGION = its transitive-dependency
# subtree: the node itself plus everything it transitively depends on (following
# accessor.edges, producer-ward). region(id) = { id } ∪ reachableFrom(edges, id).
# On a chain n0←n1←…←n(k) (edge n_i depends on n_{i-1}) the regions NEST: region(n_i)
# = {n_i,…,n0}, size i+1.
#
# SUMMARY HASH = a deterministic Merkle fold over the region members' OUTPUT hashes
# (Mokhov §4.2.4 deep constructive trace). Collision-freedom reduces to hashOf's
# (injective inputs ⇒ injective digest). A region whose CURRENT summary (over the
# new store) matches its PRIOR summary (over ctx.store) is reused EN MASSE — its
# members are not recomputed.
#
# THE NO-GO, made visible by the metric. Computing a region's current summary FORCES
# every transitive-member hash — counted in `summaryForces` with MULTIPLICITY: a
# member hashed under k ancestor regions counts k times (NOT a deduped set — a set
# caps at |cone| and the whole O(|cone|²) blow-up would be invisible). On the nesting
# chain Σ_{c∈cone} |region(c)| = 1+2+…+|cone| = |cone|(|cone|+1)/2 ≫ |cone|.
#
# WHY IT CANNOT CUT LIKE V-PUSH. A region summary moves iff ANY member moved. A deep
# leaf change moves that leaf, and the leaf sits in EVERY ancestor region's subtree,
# so every cone region's summary moves ⇒ every cone node is recomputed
# (recomputed ≈ |cone|). The cut happens only at region BOUNDARIES, never per-node
# below them — exactly Mokhov's "only at n levels" ceiling.
#
# SOUNDNESS (non-negotiable, even though minimality is not expected). The result
# store is the SAME full-cone fixpoint the baseline computes (lib.fix over the cone,
# reading non-cone deps from ctx.store), so it is byte-identical to a from-scratch
# build. The summary machinery drives the METRICS (the no-go evidence); it never
# changes the store. A region whose summary matched would be reused, but here every
# region that the change reaches has moved, so reuse fires only on regions the cone
# does not touch — which are not in the cone and not recomputed anyway.
#
# Edge convention: accessor.edges id = [producers] (consumer→producer). A node's
# region walks edges; its cone (dependents) walks the reverse.
{
  lib,
  graph,
  genRebuild,
  instrument,
}:
let
  inherit (import ../lib/hash.nix { }) hashGuarded;
in
{
  vsummary =
    ctx: changes:
    let
      changedIds = builtins.attrNames changes;

      # accessor' : prior topology with the changed nodeData overlaid (data-change
      # envelope; edges fixed ⇒ the prior cone stays valid).
      accessor' = ctx.accessor // {
        nodeData = id: changes.${id} or (ctx.accessor.nodeData id);
      };

      # Over-approx cone of ALL changed ids (the region heads to summarise).
      cone = lib.unique (changedIds ++ lib.concatMap (graph.dependentsOf accessor') changedIds);

      # region(id) = { id } ∪ transitive deps of id (sorted, deterministic).
      regionOf =
        id:
        builtins.sort builtins.lessThan (
          lib.unique ([ id ] ++ graph.reachableFrom { inherit (accessor') edges; } id)
        );

      # --- SOUND store: the full-cone fixpoint (identical to baseline) ---------
      # A cone-internal dep reads its fresh value from `s`; a non-cone dep falls
      # through to ctx.store via `ctx.store // s` (KEPT — bare `s` misses non-cone
      # deps ⇒ unsound). Byte-identical to a from-scratch build over accessor'.
      newStore =
        ctx.store // lib.fix (s: lib.genAttrs cone (id: ctx.recompute accessor' (ctx.store // s) id));

      # --- summary hashes (the deep constructive trace) ------------------------
      # summaryHash store id = Merkle fold over region members' output hashes.
      summaryHashOf = store: id: ctx.hashOf (map (m: hashGuarded ctx.hashOf store.${m}) (regionOf id));

      # For each region head in the cone: does its CURRENT summary differ from its
      # PRIOR summary? If it matches, the region is reused en masse (no recompute);
      # else its members recompute. `summaryForces` accumulates |region| per head —
      # MULTIPLICITY (the O(|cone|²) re-reads).
      summaryStep =
        st: id:
        let
          members = regionOf id;
          curSummary = summaryHashOf newStore id;
          priSummary = summaryHashOf ctx.store id;
          moved = curSummary != priSummary;
        in
        st
        // {
          # multiplicity (NOT a deduped set — see header): every region forces all
          # its members. Count |region| per head; the prior+current summaries both
          # walk the region (a constant 2× that doesn't change the O(|cone|²) shape),
          # so counting |region| keeps the super-linear Σ exactly |cone|(|cone|+1)/2
          # on a chain.
          summaryForces = st.summaryForces + builtins.length members;
          # Reuse fires only on a region whose summary matched (NOT cut-heavy);
          # otherwise every member recomputes (region-boundary cut only).
          recomputedSet = if moved then st.recomputedSet ++ members else st.recomputedSet;
        };

      final = lib.foldl' summaryStep {
        summaryForces = 0;
        recomputedSet = [ ];
      } cone;

      # |recomputed| = the (deduped) union of members of every MOVED region. On a
      # cut-heavy chain every cone region moved ⇒ this is the whole cone (no early
      # cutoff below the region boundary). On a no-change region it would be fewer.
      recomputed = lib.unique final.recomputedSet;
      nRecomp = builtins.length recomputed;
    in
    {
      store = newStore;
      metrics = instrument.mkMetrics {
        # Expensive axis: members of moved regions (≈ |cone| on cut-heavy — the
        # point: no per-node cut below the region boundary).
        recomputed = nRecomp;
        hashed = nRecomp;
        allocated = nRecomp;
        # Cheap axis (V-summary): the MULTIPLICITY transitive-hash re-reads — the
        # O(|cone|²) blow-up the no-go rests on.
        summaryForces = final.summaryForces;
        cone = builtins.length cone;
      };
    };
}
