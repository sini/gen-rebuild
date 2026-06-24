# Unit pins for Task 5: the V-push rank-ordered eager-push variant (spike/vpush.nix).
#
# V-push is the PRIMARY minimality variant: a single rank-ascending pass over the
# cone that recomputes only ENQUEUED nodes, enqueues a moved node's DIRECT
# dependents, and CUTS OFF (enqueues nothing) on no-move. Result store =
# priorStore // settled. It must be byte-identical to a from-scratch build while
# recomputing far fewer than |cone| nodes on cut-heavy fixtures.
#
# This file is the UNIT-PIN gate ONLY (per Task 5). The corpus×seed soundness
# gate + the cutoff-join negative control are Task 6; they are NOT here.
#
# The four pins:
#   - test-chain-leaf: a chain pin, change the leaf, store == from-scratch oracle.
#   - test-diamond:    diamond pin, store == oracle.
#   - test-deep-cut-subcone: |recomputed| < |cone| (recompute is STRICTLY sub-cone).
#   - test-settled-exposed: the result exposes `settled` (Task 6's negative control
#     reads it, so it must be present).
{
  lib,
  graph,
  spike,
  genRebuild,
  ...
}:
let
  inherit (spike) vpush;
  fx = spike.fixtures;

  # ctxOf :: a BuiltCtx for a fixture (build over the PRIOR accessor; vpush then
  # pushes the change over it). Mirrors baseline.nix's ctxOf.
  ctxOf =
    f:
    genRebuild.build {
      accessor = f.accessor;
      inherit (f) recompute hashOf;
    };

  chain = fx.pin "chain";
  diamond = fx.pin "diamond";
  deepCut = fx.pin "deep-cut";
in
{
  flake.tests.vpush = {
    # --- byte-identity: chain leaf-change store == from-scratch oracle --------
    test-chain-leaf = {
      expr = (vpush (ctxOf chain) chain.changes).store == fx.oracle chain;
      expected = true;
    };

    # --- byte-identity: diamond store == oracle -------------------------------
    test-diamond = {
      expr = (vpush (ctxOf diamond) diamond.changes).store == fx.oracle diamond;
      expected = true;
    };

    # --- minimality: deep-cut recompute is STRICTLY sub-cone ------------------
    # The saturating chain dies within a few nodes ⇒ |recomputed| < |cone|.
    test-deep-cut-subcone = {
      expr =
        let
          m = (vpush (ctxOf deepCut) deepCut.changes).metrics;
        in
        m.recomputed < m.cone;
      expected = true;
    };

    # --- settled is EXPOSED (Task 6's negative control reads it) --------------
    test-settled-exposed = {
      expr = (vpush (ctxOf chain) chain.changes) ? settled;
      expected = true;
    };
  };
}
