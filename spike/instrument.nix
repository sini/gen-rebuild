# spike/instrument.nix — counted-forces metrics + exact-rational ratios + the
# byte-identity gate.
#
# The spike races propagate variants on COUNTED FORCES, not wall-clock — the
# only honest axis for pure-Nix laziness (no allocator, no GC, no clock). Each
# variant returns a `metrics` record; this module is the shared vocabulary:
#
#   - mkMetrics : fill the eight counters with 0 defaults (a variant supplies
#     only the axes it touches). The counters:
#       recomputed   — node-eval forces (recompute applications)
#       hashed       — content-hash forces (hashOf applications)
#       allocated    — store-slot writes (genAttrs cone entries forced)
#       precompute   — forces spent BEFORE the drive sweep (e.g. building a
#                      reverse adjacency / topo order / summary index)
#       driveSweep   — forces spent walking the worklist/queue itself
#       summaryForces— forces spent in summary-aware dedup (vsummary)
#       cone         — |cone| (the over-approx reverse-reachable set), the den.
#       affected     — |AFFECTED| (oracle-derived; threaded by the gate, no
#                      variant produces it — it is the ground-truth lower bound).
#
#   - ratios : the two head-to-head axes as EXACT rationals (no floats — Nix has
#     no rationals either, so a ratio is a {num;den} pair compared cross-wise):
#       rx = expensive-axis  / cone   (recompute/hash/alloc — the max of the three)
#       rt = total-forces    / cone   (rx.num + precompute + driveSweep)
#     den = cone for both. The baseline is rx = rt = 1/1 by construction (it does
#     cone-many forces); the cheaper variants must drive rx (and ideally rt)
#     strictly below 1.
#
#   - rle a b : exact-rational a ≤ b via cross-multiplication (a.num*b.den ≤
#     b.num*a.den). Dens are |cone| ≥ 0; for the spike's small graphs the
#     products stay well inside 64-bit, no overflow.
#
#   - gate : the soundness harness. Builds the from-scratch ORACLE store for the
#     changed accessor (genRebuild.build over fixture.accessor'), declares the
#     variant byte-identical iff its store == the oracle store, and threads the
#     oracle-derived |AFFECTED| (genRebuild.affectedSet — the exact moved-hash
#     subset of the cone) into the returned metrics. byteIdentical is the §7
#     Acar/Mokhov correctness gate every variant must pass before its ratio is
#     even meaningful.
{
  lib,
  graph,
  genRebuild,
}:
{
  mkMetrics =
    m:
    {
      recomputed = 0;
      hashed = 0;
      allocated = 0;
      precompute = 0;
      driveSweep = 0;
      summaryForces = 0;
      cone = 0;
      affected = 0;
    }
    // m;

  ratios =
    m:
    let
      tx = lib.max (lib.max m.recomputed m.hashed) m.allocated;
    in
    {
      rx = {
        num = tx;
        den = m.cone;
      };
      rt = {
        num = tx + m.precompute + m.driveSweep;
        den = m.cone;
      };
    };

  # Exact-rational ≤ : a/b ≤ c/d  ⇔  a·d ≤ c·b  (dens ≥ 0).
  rle = a: b: a.num * b.den <= b.num * a.den;

  gate =
    {
      ctx,
      variantResult,
      fixture,
    }:
    let
      # Oracle: the from-scratch ground-truth store for the CHANGED accessor.
      oracleStore =
        (genRebuild.build {
          accessor = fixture.accessor';
          inherit (fixture) recompute hashOf;
        }).store;

      # Oracle-derived |AFFECTED| (the exact moved-hash subset of the cone). No
      # variant produces this; it is threaded purely for the ratio's den-vs-floor
      # comparison.
      affected =
        builtins.length
          (genRebuild.affectedSet ctx {
            inherit (fixture) accessor' changedIds;
          }).affected;
    in
    {
      byteIdentical = variantResult.store == oracleStore;
      metrics = variantResult.metrics // {
        inherit affected;
      };
    };
}
