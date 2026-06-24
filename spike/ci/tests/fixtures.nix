# Guard tests for the v3 minimality fixture corpus (spike/fixtures.nix).
#
# These are the LOAD-BEARING acceptance of Task 1: they assert that the
# cut-heavy fixtures ACTUALLY yield their intended AFFECTED/cone ratios. If the
# saturating/modular recomputes did NOT cut off, these fail — and the whole spike
# could not answer its question. All ratio comparisons use EXACT integer
# arithmetic (no floats): `affLen * 10 <= coneLen * 3` is `ratio <= 0.3`.
#
# AFFECTED is computed via genRebuild.affectedSet (the exact hash post-filter over
# the cone); cone via genRebuild.dirtySet (the over-approx reverse-reachable set).
{
  lib,
  genRebuild,
  spike,
  ...
}:
let
  fx = spike.fixtures;

  # AFFECTED for a fixture (the exact moved-hash subset of the cone).
  affectedOf =
    f:
    let
      ctx = genRebuild.build {
        accessor = f.accessor;
        inherit (f) recompute hashOf;
      };
    in
    (genRebuild.affectedSet ctx {
      inherit (f) accessor' changedIds;
    }).affected;

  # cone (over-approx reverse-reachable set of the changed ids).
  coneOf =
    f:
    let
      ctx = genRebuild.build {
        accessor = f.accessor;
        inherit (f) recompute hashOf;
      };
    in
    genRebuild.dirtySet ctx f.changedIds;

  affLen = f: builtins.length (affectedOf f);
  coneLen = f: builtins.length (coneOf f);

  # --- pins ---------------------------------------------------------------
  deepCut = fx.pin "deep-cut";
  collision = fx.pin "collision";
  cutoffJoin = fx.pin "cutoff-join";
  tinyCone = fx.pin "tiny-cone-large-graph";

  # cutoff-join verdict: M moved, Q unmoved (oracle vs prior build).
  cjPrior =
    (genRebuild.build {
      accessor = cutoffJoin.accessor;
      inherit (cutoffJoin) recompute hashOf;
    }).store;
  cjOracle = fx.oracle cutoffJoin;
  cutoffJoinVerdict = {
    mMoved = cjOracle.M != cjPrior.M;
    qUnmoved = cjOracle.Q == cjPrior.Q;
  };

  # --- sparse-affected family mean ratio ----------------------------------
  sparseSeeds = lib.range 1 12;
  sparseCases = map (
    s:
    fx.family {
      kind = "sparse-affected";
      seed = s;
    }
  ) sparseSeeds;
  sparseTotals =
    lib.foldl'
      (acc: f: {
        aff = acc.aff + affLen f;
        cone = acc.cone + coneLen f;
      })
      {
        aff = 0;
        cone = 0;
      }
      sparseCases;

  # --- deep-cut family (seeded) mean ratio --------------------------------
  deepCutSeeds = lib.range 1 8;
  deepCutCases = map (
    s:
    fx.family {
      kind = "deep-cut";
      seed = s;
    }
  ) deepCutSeeds;
  deepCutTotals =
    lib.foldl'
      (acc: f: {
        aff = acc.aff + affLen f;
        cone = acc.cone + coneLen f;
      })
      {
        aff = 0;
        cone = 0;
      }
      deepCutCases;
in
{
  flake.tests.fixtures = {
    # The corpus exposes the documented surface.
    test-pins-have-contract = {
      expr =
        let
          f = fx.pin "chain";
          keys = builtins.sort builtins.lessThan (builtins.attrNames f);
        in
        keys;
      expected = builtins.sort builtins.lessThan [
        "accessor"
        "accessor'"
        "changes"
        "changedIds"
        "allIds"
        "edgeList"
        "recompute"
        "hashOf"
      ];
    };

    # changedIds is exactly the attrNames of changes (coherent dual representation).
    test-changes-changedids-coherent = {
      expr =
        let
          f = fx.pin "cutoff-join";
        in
        f.changedIds == builtins.attrNames f.changes;
      expected = true;
    };

    # --- the cut-heavy ratio guards (≤ 0.3) ---------------------------------

    # deep-cut PIN: change dies early ⇒ |AFFECTED| / |cone| ≤ 0.3.
    test-deep-cut-pin-ratio = {
      expr = (affLen deepCut) * 10 <= (coneLen deepCut) * 3;
      expected = true;
    };

    # deep-cut FAMILY: mean ratio ≤ 0.3.
    test-deep-cut-family-mean-ratio = {
      expr = deepCutTotals.aff * 10 <= deepCutTotals.cone * 3;
      expected = true;
    };

    # sparse-affected FAMILY: mean ratio ≤ 0.3.
    test-sparse-affected-family-mean-ratio = {
      expr = sparseTotals.aff * 10 <= sparseTotals.cone * 3;
      expected = true;
    };

    # collision PIN: leaf recomputes to its OLD value ⇒ AFFECTED is empty.
    test-collision-affected-empty = {
      expr = affectedOf collision;
      expected = [ ];
    };

    # cutoff-join PIN: M moved AND Q unmoved (§4(B): Q in-cone, never enqueued).
    test-cutoff-join-verdict = {
      expr = cutoffJoinVerdict;
      expected = {
        mMoved = true;
        qUnmoved = true;
      };
    };

    # cutoff-join cone is the full {A,J,M,P,Q}; AFFECTED is the strict subset {A,M}.
    test-cutoff-join-affected-subset = {
      expr = builtins.sort builtins.lessThan (affectedOf cutoffJoin);
      expected = [
        "A"
        "M"
      ];
    };

    # tiny-cone-large-graph PIN: |cone| ≪ |allIds| (one leaf change in a broad forest).
    # Guard: cone is at most a quarter of the whole graph.
    test-tiny-cone-much-smaller = {
      expr = (coneLen tinyCone) * 4 <= builtins.length tinyCone.allIds;
      expected = true;
    };
  };
}
