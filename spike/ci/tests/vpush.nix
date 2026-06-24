# Unit pins for Task 5: the V-push rank-ordered eager-push variant (spike/vpush.nix).
#
# V-push is the PRIMARY minimality variant: a single rank-ascending pass over the
# cone that recomputes only ENQUEUED nodes, enqueues a moved node's DIRECT
# dependents, and CUTS OFF (enqueues nothing) on no-move. Result store =
# priorStore // settled. It must be byte-identical to a from-scratch build while
# recomputing far fewer than |cone| nodes on cut-heavy fixtures.
#
# Task 5 added the UNIT-PIN gate (the four pins below). Task 6 ADDS to it: the
# corpus×seed byte-identity gate, the hand-pin byte-identity asserts, and the
# cutoff-join negative control.
#
# The four (Task 5) pins:
#   - test-chain-leaf: a chain pin, change the leaf, store == from-scratch oracle.
#   - test-diamond:    diamond pin, store == oracle.
#   - test-deep-cut-subcone: |recomputed| < |cone| (recompute is STRICTLY sub-cone).
#   - test-settled-exposed: the result exposes `settled` (Task 6's negative control
#     reads it, so it must be present).
#
# Task 6 — the V-push correctness gate:
#   (1) PER-SEED BYTE-IDENTITY (mirrors ci/tests/override.nix's failingSeeds): for
#       seeds 1..120 over the families chain/wide-fan/deep-cut/sparse-affected/
#       batch-multiseed/tiny-cone-large-graph, (vpush (ctxOf fx) fx.changes).store
#       == oracle fx. failingSeeds must be [ ].
#   (2) HAND-PIN BYTE-IDENTITY for cutoff-join/collision/diamond/chain/wide-fan/
#       deep-cut.
#   (3) NEGATIVE CONTROL on the §4(B) invariant. The CORRECT store is `.store`
#       (= ctx.store // settled, carrying the priorStore base); the BROKEN store is
#       the EXPOSED `.settled` (settled-only, NO priorStore carry). On cutoff-join
#       Q is in-cone-but-cut-off ⇒ never written to settled ⇒ broken store LACKS Q
#       ⇒ DIVERGES from oracle. On the diamond every cone node is enqueued and moves
#       ⇒ settled holds the whole cone ⇒ broken store == correct store ⇒ the diamond
#       CANNOT catch the bug. That asymmetry is the proof the diamond is too weak and
#       cutoff-join is the decisive fixture.
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
  # pushes the change over it). Mirrors baseline.nix's / Task 5's ctxOf.
  ctxOf =
    f:
    genRebuild.build {
      accessor = f.accessor;
      inherit (f) recompute hashOf;
    };

  # oracleOf :: the from-scratch ground-truth store for a fixture.
  oracleOf = f: fx.oracle f;

  # brokenVpushStore :: the SETTLED-only store (drops the `ctx.store //` priorStore
  # carry). Reuses the EXPOSED `.settled` — NOT a reimplemented vpush. This is the
  # §4(B) negative control: on cutoff-join it lacks the cut-off-but-in-cone node Q.
  brokenVpushStore = f: (vpush (ctxOf f) f.changes).settled;

  # vpushStore :: the CORRECT store (priorStore carry intact).
  vpushStore = f: (vpush (ctxOf f) f.changes).store;

  chain = fx.pin "chain";
  diamond = fx.pin "diamond";
  deepCut = fx.pin "deep-cut";

  # --- (1) per-seed byte-identity over every family kind, seeds 1..120 ---------
  seeds = lib.range 1 120;
  familyKinds = [
    "chain"
    "wide-fan"
    "deep-cut"
    "sparse-affected"
    "batch-multiseed"
    "tiny-cone-large-graph"
  ];
  # A single combined failingSeeds across every (kind, seed): the seed diverges if
  # ANY family kind's V-push store ≠ its from-scratch oracle. (`seed` is salted
  # distinctly per kind by the LCG, so reusing the same seed index across kinds is
  # fine — they are independent shapes.)
  vpushSoundFor =
    kind: seed:
    let
      f = fx.family {
        inherit kind seed;
      };
    in
    vpushStore f == oracleOf f;
  isSound = seed: builtins.all (kind: vpushSoundFor kind seed) familyKinds;
  failingSeeds = builtins.filter (seed: !(isSound seed)) seeds;

  cj = fx.pin "cutoff-join";
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

    # ===== Task 6 (1): per-seed byte-identity over the seed families =====
    # 120 seeds × 6 family kinds: V-push store == from-scratch oracle everywhere.
    test-vpush-sound-120-seeds = {
      expr = failingSeeds;
      expected = [ ];
    };

    # ===== Task 6 (2): hand-pin byte-identity (every pin == oracle) =====
    test-pin-cutoff-join = {
      expr = vpushStore cj == oracleOf cj;
      expected = true;
    };
    test-pin-collision = {
      expr =
        let
          f = fx.pin "collision";
        in
        vpushStore f == oracleOf f;
      expected = true;
    };
    test-pin-diamond = {
      expr = vpushStore diamond == oracleOf diamond;
      expected = true;
    };
    test-pin-chain = {
      expr = vpushStore chain == oracleOf chain;
      expected = true;
    };
    test-pin-wide-fan = {
      expr =
        let
          f = fx.pin "wide-fan";
        in
        vpushStore f == oracleOf f;
      expected = true;
    };
    test-pin-deep-cut = {
      expr = vpushStore deepCut == oracleOf deepCut;
      expected = true;
    };

    # ===== Task 6 (3): cutoff-join negative control (the §4(B) invariant) =====
    # CORRECT store (priorStore carry intact) is byte-identical to the oracle: Q is
    # carried from ctx.store even though it was cut off from enqueue.
    test-cutoffjoin-sound = {
      expr = vpushStore cj == oracleOf cj;
      expected = true;
    };
    # The BROKEN settled-only store DIVERGES on cutoff-join: Q is in-cone but cut off
    # (its only enqueuer P collided), so it is never written to settled ⇒ the
    # settled-only store LACKS Q ⇒ ≠ oracle. This is the bug the carry prevents.
    test-cutoffjoin-catches-bug = {
      expr = brokenVpushStore cj == oracleOf cj;
      expected = false;
    };
    # The diamond CANNOT catch that bug: every cone node is enqueued and moves, so
    # settled holds the entire cone ⇒ settled-only store == correct store == oracle.
    # Proving the plain diamond is too weak — cutoff-join is the decisive fixture.
    test-diamond-misses-bug = {
      expr = brokenVpushStore diamond == oracleOf diamond;
      expected = true;
    };
  };
}
