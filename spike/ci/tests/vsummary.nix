# Acceptance tests for Task 7: the V-summary SECONDARY variant (spike/vsummary.nix).
#
# V-summary is an EXPECTED NO-GO (Mokhov 2018 §4.2.4: a deep constructive trace
# "cannot support early cutoff … other than at n levels of dependencies"). Its job
# in the spike is to EMIT THE NO-GO EVIDENCE, not to win:
#
#   - A per-region SUMMARY HASH = a Merkle fold over the region members' output
#     hashes (collision-freedom reduces to hashOf's). A region's region = the
#     transitive-dependency subtree of a node (the node + everything it transitively
#     depends on). A region whose summary matches its prior value is reused en masse.
#   - Computing a region's current summary forces every transitive-member hash —
#     counted in `summaryForces` with MULTIPLICITY (a node hashed under k ancestor
#     regions counts k times). This is the O(|cone|²) blow-up the metric exposes.
#   - On cut-heavy fixtures it does NOT achieve V-push's per-node cutoff (it cuts
#     only at region boundaries).
#
# The four tests below pin exactly that NO-GO shape plus soundness:
#   - test-summary-collision-differ : WHITE-BOX. The summary-collision pin's two
#     structurally-similar regions' summaryHash genuinely DIFFER ⇒ en-masse reuse
#     correctly does NOT fire (a deep-leaf change ⇒ the L-region summary moves).
#   - test-chain-superlinear        : on a chain (n ≥ 6), summaryForces > cone — the
#     super-linear O(|cone|²) blow-up.
#   - test-no-early-cutoff          : on deep-cut (a cut-heavy chain), V-summary does
#     NOT achieve V-push's sub-cone cut — recomputed >= cone (no early cutoff below
#     the region boundary). The expected NO-GO shape.
#   - test-vsummary-sound           : byte-identity — vsummary store == oracle on a
#     couple of fixtures (it must still be SOUND, just not minimal).
{
  lib,
  graph,
  spike,
  genRebuild,
  ...
}:
let
  inherit (spike) vsummary;
  fx = spike.fixtures;

  inherit (import ../../../lib/hash.nix { }) hashGuarded;

  # ctxOf :: a BuiltCtx for a fixture (build over the PRIOR accessor; vsummary then
  # splices the change over it). Mirrors vpush.nix / baseline.nix.
  ctxOf =
    f:
    genRebuild.build {
      accessor = f.accessor;
      inherit (f) recompute hashOf;
    };

  oracleOf = f: fx.oracle f;
  vsummaryStore = f: (vsummary (ctxOf f) f.changes).store;
  vsummaryMetrics = f: (vsummary (ctxOf f) f.changes).metrics;

  # --- white-box summary-hash recompute (the summary-collision regions) --------
  # The region of a node = the node + its transitive-dependency subtree (everything
  # it transitively depends on, following accessor.edges). summaryHash folds the
  # region members' output hashes deterministically — same fold vsummary.nix uses,
  # re-derived HERE so the test asserts the regions DIFFER without reaching into
  # vsummary's internals.
  regionOf =
    accessor: id: lib.unique ([ id ] ++ graph.reachableFrom { inherit (accessor) edges; } id);
  summaryHashOf =
    f: store: id:
    let
      members = builtins.sort builtins.lessThan (regionOf f.accessor' id);
    in
    f.hashOf (map (m: hashGuarded f.hashOf store.${m}) members);

  sc = fx.pin "summary-collision";
  scStore = vsummaryStore sc; # the V-summary new store (sound ⇒ == oracle)
  # The two structurally-similar region heads: L2 (subtree L2,L1,L0) and R2
  # (subtree R2,R1,R0). The deep L-leaf change moves L0 ⇒ L2's summary moves; R's
  # does not. White-box: the two regions' summaries DIFFER over the NEW store.
  sumL = summaryHashOf sc scStore "L2";
  sumR = summaryHashOf sc scStore "R2";

  # chain6 :: a chain FAMILY seed whose length is n = 6 (≥ 6, for the super-linear
  # evidence). The chain family uses a high cap ⇒ full propagation (every node
  # moves), so the cone of an n0 change is the whole 6-chain and Σ region sizes =
  # 1+2+…+6 = 21 > 6 = cone. (Seed 2 ⇒ n = 6; computed from the fixtures' LCG.)
  chain6 = fx.family {
    kind = "chain";
    seed = 2;
  };
  deepCut = fx.pin "deep-cut";
in
{
  flake.tests.vsummary = {
    # ===== WHITE-BOX: the two summary-collision regions DIFFER ================
    # Not merely store==oracle (which passes trivially if the cut never fires):
    # the deep-leaf change moves the L-region's summary, so en-masse reuse of the
    # L region correctly does NOT fire. Collision-freedom reduces to hashOf's.
    test-summary-collision-differ = {
      expr = sumL != sumR;
      expected = true;
    };

    # ===== NO-GO: super-linear summaryForces on a chain (O(|cone|²)) ==========
    # n=6 chain: region(n_i) has i+1 members, so Σ region sizes over the cone =
    # 1+2+…+6 = 21 > cone = 6. The MULTIPLICITY count registers the re-reads a
    # deduped set would hide.
    test-chain-superlinear = {
      expr =
        let
          m = vsummaryMetrics chain6;
        in
        m.summaryForces > m.cone;
      expected = true;
    };

    # ===== NO-GO: no early cutoff below the region boundary ===================
    # On deep-cut (a cut-heavy chain where V-push cuts within a few nodes),
    # V-summary does NOT get the per-node cut: it recomputes at least the whole
    # cone (recomputed >= cone), the region-boundary ceiling. Its expensive axis
    # is near baseline — NOT sub-cone the way V-push's is.
    test-no-early-cutoff = {
      expr =
        let
          m = vsummaryMetrics deepCut;
        in
        m.recomputed >= m.cone;
      expected = true;
    };

    # ===== SOUND: byte-identity to the from-scratch oracle ====================
    # V-summary is not minimal, but it MUST be sound: its store equals the oracle
    # on every fixture it is run on.
    test-vsummary-sound = {
      expr = {
        summaryCollision = scStore == oracleOf sc;
        chain6 = vsummaryStore chain6 == oracleOf chain6;
        deepCut = vsummaryStore deepCut == oracleOf deepCut;
        diamond =
          let
            f = fx.pin "diamond";
          in
          vsummaryStore f == oracleOf f;
        cutoffJoin =
          let
            f = fx.pin "cutoff-join";
          in
          vsummaryStore f == oracleOf f;
      };
      expected = {
        summaryCollision = true;
        chain6 = true;
        deepCut = true;
        diamond = true;
        cutoffJoin = true;
      };
    };
  };
}
