# spike/baseline.nix — the flat-cone BASELINE propagate variant.
#
# This is the O(|cone|) reference: it recomputes EVERY node in the over-approx
# dependent cone of the changed ids and splices the result over the prior store.
# It is exactly the v2 multi-id splice with the needsEval gate REMOVED (no
# early-cutoff) — the `|touched| = |cone|` form the cheaper variants must beat on
# the expensive axis. It is, by construction, byte-identical to a from-scratch
# build (lib/affectedSet.nix:45-68 is the gated version of this same fold; with
# the gate forced-true every cone node recomputes ⇒ same store, just more forces).
#
# `ctx` is a BuiltCtx from genRebuild.build (carries store, accessor, recompute,
# hashOf, trace). `changes :: { <id> = newDecls; }` is the variant calling
# convention (== fixture.changes). Edges are FIXED (data-change envelope), so the
# cone over the changed accessor equals the cone over the prior accessor.
#
# Metrics: every counted axis is |cone| (it forces the whole cone — recompute,
# hash, and a store slot each); the worklist/precompute/summary axes are 0
# (there is no worklist — it is a flat genAttrs over the static cone).
{
  lib,
  graph,
  genRebuild,
  instrument,
}:
{
  baseline =
    ctx: changes:
    let
      changedIds = builtins.attrNames changes;

      # accessor' : prior topology with the changed nodeData overlaid. Edges fall
      # through to ctx.accessor (unchanged) ⇒ the prior cone stays valid.
      accessor' = ctx.accessor // {
        nodeData = id: changes.${id} or (ctx.accessor.nodeData id);
      };

      # Over-approx cone of ALL changed ids (multi-seed). genAttrs gives the
      # reverse-topo order via lib.fix below.
      cone = lib.unique (changedIds ++ lib.concatMap (graph.dependentsOf accessor') changedIds);

      # Flat splice: recompute EVERY cone node (no needsEval gate). A cone-internal
      # dep reads its fresh value from `s`; a non-cone dep falls through to
      # ctx.store via the `ctx.store // s` form (KEPT — bare `s` would miss
      # non-cone deps of a recomputed node ⇒ unsound).
      store =
        ctx.store // lib.fix (s: lib.genAttrs cone (id: ctx.recompute accessor' (ctx.store // s) id));

      n = builtins.length cone;
    in
    {
      inherit store;
      metrics = instrument.mkMetrics {
        recomputed = n;
        hashed = n;
        allocated = n;
        cone = n;
      };
    };
}
