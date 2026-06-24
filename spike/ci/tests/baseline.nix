# Acceptance tests for Task 2: the counted-forces instrument, the flat-cone
# baseline variant, and the byte-identity gate.
#
# The baseline recomputes EVERY cone node (|touched| = |cone|, O(|cone|)) — the
# reference the cheaper variants must beat on the expensive axis. These tests
# prove (a) the baseline store is byte-identical to the from-scratch oracle on
# every pin + a sweep of family seeds; (b) the gate threads the oracle-derived
# |AFFECTED| (no variant produces it); (c) for SINGLE-id pins the baseline store
# equals the shipped genRebuild.override store (cross-check vs the lib); and
# (d) the baseline ratios are 1/1 (it does cone-many forces, by construction).
{
  lib,
  graph,
  spike,
  genRebuild,
  ...
}:
let
  inherit (spike) instrument baseline;
  fx = spike.fixtures;

  # ctx :: a BuiltCtx for a fixture (build over the PRIOR accessor; the variant
  # then splices the change over it).
  ctxOf =
    f:
    genRebuild.build {
      accessor = f.accessor;
      inherit (f) recompute hashOf;
    };

  # gateOf :: run the baseline on a fixture and gate it against the oracle.
  gateOf =
    f:
    let
      ctx = ctxOf f;
    in
    instrument.gate {
      inherit ctx;
      fixture = f;
      variantResult = baseline ctx f.changes;
    };

  # --- pins -----------------------------------------------------------------
  pinNames = [
    "chain"
    "diamond"
    "wide-fan"
    "deep-cut"
    "collision"
    "cutoff-join"
    "tiny-cone-large-graph"
    "summary-collision"
  ];
  pinFixtures = map fx.pin pinNames;

  # Single-id pins: cross-checkable against genRebuild.override (single-id only).
  singleIdPins = builtins.filter (f: builtins.length f.changedIds == 1) pinFixtures;

  # --- family seeds (multi-seed sweep; batch-multiseed is multi-id) ---------
  familySpecs =
    (map (s: {
      kind = "chain";
      seed = s;
    }) (lib.range 1 4))
    ++ (map (s: {
      kind = "deep-cut";
      seed = s;
    }) (lib.range 1 4))
    ++ (map (s: {
      kind = "sparse-affected";
      seed = s;
    }) (lib.range 1 4))
    ++ (map (s: {
      kind = "batch-multiseed";
      seed = s;
    }) (lib.range 1 4));
  familyFixtures = map fx.family familySpecs;

  allFixtures = pinFixtures ++ familyFixtures;

  # cross-check the baseline store against the shipped single-id override.
  overrideMatches =
    f:
    let
      ctx = ctxOf f;
      id = builtins.head f.changedIds;
    in
    (baseline ctx f.changes).store == (genRebuild.override ctx id f.changes.${id}).store;

  cutoffJoin = fx.pin "cutoff-join";
  deepCut = fx.pin "deep-cut";
in
{
  flake.tests.baseline = {
    # --- byte-identity gate: baseline == oracle on every pin + family seed ---
    test-baseline-byte-identical-all = {
      expr = lib.all (f: (gateOf f).byteIdentical) allFixtures;
      expected = true;
    };

    # --- the gate threads the oracle-derived |AFFECTED| into metrics ---------
    # cutoff-join: AFFECTED = {A,M} ⇒ affected count == 2 (the §4(B) instance).
    test-gate-affected-cutoff-join = {
      expr = (gateOf cutoffJoin).metrics.affected;
      expected = 2;
    };

    # affected is populated (non-degenerate) on a moving fixture (chain pin).
    test-gate-affected-populated = {
      expr = (gateOf (fx.pin "chain")).metrics.affected >= 1;
      expected = true;
    };

    # --- cross-check vs the shipped single-id override -----------------------
    test-baseline-matches-override-single-id = {
      expr = lib.all overrideMatches singleIdPins;
      expected = true;
    };

    # --- ratios: the baseline does cone-many forces ⇒ rx == rt == 1/1 --------
    test-baseline-ratios-unity = {
      expr =
        let
          m = (gateOf deepCut).metrics;
          r = instrument.ratios m;
        in
        {
          rxUnity =
            instrument.rle r.rx {
              num = 1;
              den = 1;
            }
            && instrument.rle {
              num = 1;
              den = 1;
            } r.rx;
          rtUnity =
            instrument.rle r.rt {
              num = 1;
              den = 1;
            }
            && instrument.rle {
              num = 1;
              den = 1;
            } r.rt;
        };
      expected = {
        rxUnity = true;
        rtUnity = true;
      };
    };

    # --- metrics shape: baseline is |cone| on every counted axis -------------
    test-baseline-metrics-shape = {
      expr =
        let
          f = fx.pin "deep-cut";
          ctx = ctxOf f;
          m = (baseline ctx f.changes).metrics;
          n = builtins.length (genRebuild.dirtySet ctx f.changedIds);
        in
        {
          recomputed = m.recomputed == n;
          hashed = m.hashed == n;
          allocated = m.allocated == n;
          cone = m.cone == n;
          precompute = m.precompute == 0;
          driveSweep = m.driveSweep == 0;
          summaryForces = m.summaryForces == 0;
        };
      expected = {
        recomputed = true;
        hashed = true;
        allocated = true;
        cone = true;
        precompute = true;
        driveSweep = true;
        summaryForces = true;
      };
    };

    # --- rle is an exact-rational ≤ comparator (no floats) -------------------
    test-rle-exact = {
      expr = {
        # 1/3 <= 1/2
        a =
          instrument.rle
            {
              num = 1;
              den = 3;
            }
            {
              num = 1;
              den = 2;
            };
        # 1/2 <= 1/3 is false
        b =
          instrument.rle
            {
              num = 1;
              den = 2;
            }
            {
              num = 1;
              den = 3;
            };
        # equal: 2/4 <= 1/2
        c =
          instrument.rle
            {
              num = 2;
              den = 4;
            }
            {
              num = 1;
              den = 2;
            };
      };
      expected = {
        a = true;
        b = false;
        c = true;
      };
    };

    # --- ratios picks the MAX of the recompute/hash/alloc axes for rx.num ----
    test-ratios-rx-is-max = {
      expr =
        let
          m = instrument.mkMetrics {
            recomputed = 3;
            hashed = 7;
            allocated = 5;
            precompute = 2;
            driveSweep = 4;
            cone = 10;
          };
          r = instrument.ratios m;
        in
        {
          rxNum = r.rx.num; # max(3,7,5) = 7
          rxDen = r.rx.den; # 10
          rtNum = r.rt.num; # 7 + 2 + 4 = 13
          rtDen = r.rt.den; # 10
        };
      expected = {
        rxNum = 7;
        rxDen = 10;
        rtNum = 13;
        rtDen = 10;
      };
    };

    # --- mkMetrics fills defaults for omitted counters -----------------------
    test-mkmetrics-defaults = {
      expr = instrument.mkMetrics { recomputed = 5; };
      expected = {
        recomputed = 5;
        hashed = 0;
        allocated = 0;
        precompute = 0;
        driveSweep = 0;
        summaryForces = 0;
        cone = 0;
        affected = 0;
      };
    };
  };
}
