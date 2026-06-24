# Acceptance tests for Task 8: the RACE harness — the §5 counted-forces table, the
# §8 r_x / r_t ratios, and the per-cell §7 gate.
#
# This is the spike's head-to-head: for every (variant × fixture × seed) cell it
# RUNS the variant on identical inputs, GATES the result against the from-scratch
# oracle (§7 soundness), and COLLECTS the counted forces + exact-rational ratios
# into one structured `table`. Task 9's verdict reads that table via
# `nix eval --json …#tests.race.test-table.expr`.
#
# What the table SHOWS (proven piecewise in Tasks 2/5/6/7, re-collected here):
#   - BASELINE: rx = rt = 1/1 on every fixture (it does cone-many forces by
#     construction — the O(|cone|) reference).
#   - V-PUSH: rx < 1 (STRICT) on the cut-heavy fixtures (deep-cut, sparse-affected)
#     — the per-node early cutoff drives the expensive axis sub-cone. THE go signal.
#   - V-SUMMARY: SOUND (byte-identical) but `summaryForces > cone` on full-propagation
#     shapes — the O(|cone|²) region-member re-reads have no amortization and no
#     per-node cutoff below the region boundary. Per spec §5/§8 this is its OWN
#     dedicated axis (NOT folded into r_t, which stays expensive+precompute+sweep);
#     V-summary's NO-GO trigger is `|summary-forces| > |cone|` directly. A NO-GO on
#     COST, never on soundness.
#
# THE GATE (§7): all three variants are SOUND. allByteIdentical must be true across
# every cell — V-summary included. V-summary's NO-GO is its r_t cost, not a gate
# break, so there is deliberately NO test expecting it to diverge.
#
# Seed sample (bounded for eval cost; the 120-seed soundness floor is Task 6's):
#   7 pins + 6 family kinds × seeds {1,2,3} = 25 fixtures × 3 variants = 75 cells.
{
  lib,
  graph,
  spike,
  genRebuild,
  ...
}:
let
  inherit (spike) instrument;
  fx = spike.fixtures;

  variants = {
    baseline = spike.baseline;
    vpush = spike.vpush;
    vsummary = spike.vsummary;
  };

  # ctxOf :: a BuiltCtx for a fixture (build over the PRIOR accessor; the variant
  # then splices the change over it). Bound once per fixture below (lazy/cached).
  ctxOf =
    f:
    genRebuild.build {
      accessor = f.accessor;
      inherit (f) recompute hashOf;
    };

  # --- the fixture sample (pins + a bounded family sweep) -------------------
  pinNames = [
    "chain"
    "diamond"
    "wide-fan"
    "deep-cut"
    "collision"
    "cutoff-join"
    "tiny-cone-large-graph"
  ];
  familyKinds = [
    "chain"
    "wide-fan"
    "deep-cut"
    "sparse-affected"
    "batch-multiseed"
    "tiny-cone-large-graph"
  ];
  familySeeds = [
    1
    2
    3
  ];

  # A fixtureSpec carries a stable LABEL (for the table's `fixture` column) and the
  # built fixture. Pins label by name; family cells label `<kind>@<seed>`.
  pinSpecs = map (name: {
    label = name;
    fixture = fx.pin name;
  }) pinNames;
  familySpecs = lib.concatMap (
    kind:
    map (seed: {
      label = "${kind}@${toString seed}";
      fixture = fx.family { inherit kind seed; };
    }) familySeeds
  ) familyKinds;
  fixtureSpecs = pinSpecs ++ familySpecs;

  # --- the race: one row per (variant × fixtureSpec) cell -------------------
  # ctx is bound ONCE per fixtureSpec (shared across the three variants of that
  # cell — same prior store, same oracle).
  rowsFor =
    { label, fixture }:
    let
      ctx = ctxOf fixture;
    in
    lib.mapAttrsToList (
      variantName: variant:
      let
        vr = variant ctx fixture.changes;
        g = instrument.gate {
          inherit ctx fixture;
          variantResult = vr;
        };
        r = instrument.ratios g.metrics;
      in
      {
        variant = variantName;
        inherit (g) byteIdentical;
        fixture = label;
      }
      // g.metrics
      // {
        rx = r.rx;
        rt = r.rt;
      }
    ) variants;

  rows = lib.concatMap rowsFor fixtureSpecs;

  # --- the JSON-evaluable table (plain ints/strings; Task 9 reads this) -----
  # Flattens each row's rx/rt rationals into rxNum/rxDen/rtNum/rtDen so the whole
  # value is `nix eval --json`-friendly (no nested ratio records to special-case).
  table = map (row: {
    inherit (row)
      variant
      fixture
      recomputed
      hashed
      allocated
      precompute
      driveSweep
      summaryForces
      cone
      affected
      byteIdentical
      ;
    rxNum = row.rx.num;
    rxDen = row.rx.den;
    rtNum = row.rt.num;
    rtDen = row.rt.den;
  }) rows;

  # --- selectors over the rows ----------------------------------------------
  rowsOf = variantName: builtins.filter (r: r.variant == variantName) rows;
  rowFor =
    variantName: label:
    let
      hits = builtins.filter (r: r.variant == variantName && r.fixture == label) rows;
    in
    builtins.head hits;

  allByteIdentical = lib.all (r: r.byteIdentical) rows;

  # baseline unity: rx == rt == 1/1 (num == den) on EVERY baseline row.
  baselineUnity = lib.all (r: r.rx.num == r.rx.den && r.rt.num == r.rt.den) (rowsOf "baseline");
in
{
  flake.tests.race = {
    # ===== §7 GATE: every cell is byte-identical (all three variants SOUND) ===
    test-all-byte-identical = {
      expr = allByteIdentical;
      expected = true;
    };

    # ===== BASELINE sanity: rx == rt == 1/1 on every fixture ==================
    test-baseline-unity = {
      expr = baselineUnity;
      expected = true;
    };

    # ===== V-PUSH go signal: STRICT sub-cone expensive axis on cut-heavy ======
    # deep-cut: the saturating chain dies within a few nodes ⇒ rx.num < rx.den.
    test-vpush-subcone-deepcut = {
      expr =
        let
          r = (rowFor "vpush" "deep-cut").rx;
        in
        r.num < r.den;
      expected = true;
    };
    # sparse-affected (a seeded cut-heavy chain): same STRICT sub-cone rx.
    test-vpush-subcone-sparse = {
      expr =
        let
          r = (rowFor "vpush" "sparse-affected@1").rx;
        in
        r.num < r.den;
      expected = true;
    };

    # ===== V-SUMMARY NO-GO (cost): summaryForces > cone, but still SOUND =======
    # The spec §8 V-summary NO-GO trigger is its DEDICATED axis: `|summary-forces|`
    # exceeds `|cone|` (the O(|cone|²) region-member re-reads have no amortization).
    # This is a SEPARATE quantity from r_t (which stays spec-conformant: expensive +
    # precompute + drive-sweep, summaryForces NOT folded in). Assert it on an n≥6
    # chain (chain@2: Σ region sizes 1+…+6 = 21 > cone 6) and on the deep-cut pin
    # (Σ 1+…+21 = 231 > cone 21) — both fully-propagating shapes where the cost bites.
    test-vsummary-summaryforces-superlinear = {
      expr =
        let
          chainRow = rowFor "vsummary" "chain@2"; # n≥6 chain
          deepRow = rowFor "vsummary" "deep-cut"; # full-propagation pin
        in
        chainRow.summaryForces > chainRow.cone && deepRow.summaryForces > deepRow.cone;
      expected = true;
    };
    # …and those same cells ARE byte-identical: the NO-GO is cost, not soundness.
    test-vsummary-chain-sound = {
      expr = (rowFor "vsummary" "chain@2").byteIdentical && (rowFor "vsummary" "deep-cut").byteIdentical;
      expected = true;
    };

    # ===== the TABLE is reachable + well-formed (Task 9 reads this) ===========
    test-table-nonempty = {
      expr = builtins.length table;
      expected = 75; # 25 fixtures × 3 variants
    };
    # Every row carries the full flattened schema with plain JSON-friendly values.
    test-table-shape = {
      expr = lib.all (
        row:
        builtins.isString row.variant
        && builtins.isString row.fixture
        && builtins.isInt row.recomputed
        && builtins.isInt row.hashed
        && builtins.isInt row.allocated
        && builtins.isInt row.precompute
        && builtins.isInt row.driveSweep
        && builtins.isInt row.summaryForces
        && builtins.isInt row.cone
        && builtins.isInt row.affected
        && builtins.isInt row.rxNum
        && builtins.isInt row.rxDen
        && builtins.isInt row.rtNum
        && builtins.isInt row.rtDen
        && builtins.isBool row.byteIdentical
      ) table;
      expected = true;
    };
    # THE TABLE itself — Task 9's verdict reads `…#tests.race.test-table.expr`.
    test-table = {
      expr = table;
      expected = table;
    };
  };
}
