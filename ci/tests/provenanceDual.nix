# Tests for the amortized provenance duals — whyFor / whyNotFor.
#
# The dual is accepted by DIFFERENTIAL EQUIVALENCE against the per-call form it
# amortizes: for every node of every one of the same 120 random seeds the soundness
# anchor runs, `whyFor ctx { changedId } id` must equal `why ctx { id; changedId }` —
# the WHOLE record, verdict and payload — and the negative pair must agree the same
# way. Two entry points that share one verdict body can still diverge in the oracle
# they hand it, and the oracle is the only thing they do not share.
#
# ★ THE SOUNDNESS ANCHOR IS DELIBERATELY NOT ROUTED THROUGH THE CONE, AND THAT IS WHAT
# LEAVES THIS COMPARISON WITH ANYTHING TO SAY. `provenance.nix` asserts
# (why … != "unaffected") ⟺ id ∈ dirtySet, and its force comes entirely from the two
# sides being computed by INDEPENDENT ROUTES — a forward point query on one side, a
# reverse cone on the other. Route `why` through the cone and that assertion becomes
# `id ∈ cone ⟺ id ∈ cone`: a tautology no defect can falsify, still green, still
# reading exactly as it reads today. So `why` keeps the point query, and the cone is
# compared against it HERE rather than substituted for it THERE.
#
# ★★ EVERY EMPTY-LIST CELL BELOW HAS A LIVE CONTROL IN THE SAME RUN, because an empty
# mismatch list is also what a comparison that cannot fire returns. Two WRONG duals are
# modelled beside the real one and pushed through the same differential:
#   · originOmitted — the cone without the change origin. `dirtySet` unions the changed
#     ids INTO the cone; a dual reaching for `dependentsOf` alone drops exactly the
#     `id == changedId` cell, one per seed, and nothing else.
#   · transposed — the cone taken in the producer direction. The origin is present, so
#     this arm isolates the direction and nothing else.
# Both are asserted NON-empty. The compared-cell count is pinned besides, because a
# filter over no cells is empty for a reason that has nothing to do with the subject.
{
  lib,
  genRebuild,
  graph,
  mkCase,
  ...
}:
let
  inherit (genRebuild)
    build
    why
    whyFor
    whyNot
    whyNotFor
    ;

  hashOf = v: builtins.hashString "sha256" (builtins.toJSON v);
  mkCtx =
    accessor:
    build {
      inherit accessor;
      recompute =
        _a: _s: id:
        id;
      inherit hashOf;
    };

  # chain a->b->c->d : edges a=[b], b=[c], c=[d], d=[] (consumer→producer).
  chainCtx = mkCtx graph.fixtures.chain;
  # diamond a->{b,c}->d : edges a=[b,c], b=[d], c=[d], d=[].
  diamondCtx = mkCtx graph.fixtures.diamond;

  # ===== the differential corpus: the anchor's own 120 seeds =====
  seeds = lib.range 1 120;
  cases = map (
    seed:
    let
      c = mkCase seed;
    in
    {
      inherit seed c;
      ctx = build {
        accessor = c.acc;
        inherit (c) recompute hashOf;
      };
    }
  ) seeds;

  # One cell per (seed, id). Flattened so the comparison is element-wise over cells
  # rather than a per-seed boolean that a single agreeing node could carry.
  cells = lib.concatMap (
    k:
    map (id: {
      inherit (k) seed c ctx;
      inherit id;
    }) k.c.ids
  ) cases;

  # Mismatching cells, named by (seed, id) so a failure says which cell, not how many.
  mismatchesBy =
    cmp: map (cell: { inherit (cell) seed id; }) (builtins.filter (cell: !(cmp cell)) cells);

  # The overlay arm's cutoffs: every node marked cut. mkCase's values are integers, so
  # every node hashes and the overlay actually bites — an overlay of unhashable nodes
  # would take the same branch and cut nothing, which is a fast path wearing a costume.
  overlayOf = cell: lib.genAttrs cell.c.ids (_: true);

  # ★ THE OVERLAY CELLS SPLIT IN TWO, AND THE SPLIT IS THE PER-CALL FORM'S OWN BEHAVIOUR
  # RATHER THAN AN EXEMPTION CARVED FOR THE DUAL. At `id == changedId` the path set is the
  # single one-node path [id], whose INTERIOR is empty — the endpoints coincide, so nothing
  # lies strictly between them, and the change origin has never been cuttable. These 120
  # cells USED TO RAISE: `interior` reached `init [ ]` and gen-prelude refused, so the query
  # answered with a list primitive's error rather than a verdict. `_verdict` now guards the
  # singleton, and BOTH routes move together because both are that one function — which is
  # what these cells check. They are kept separate from the 540 not because they are exempt
  # but because their count is the pinned reading: one origin cell per seed.
  isOrigin = cell: cell.id == cell.c.changedId;
  overlayValueCells = builtins.filter (cell: !(isOrigin cell)) cells;
  overlayOriginCells = builtins.filter isOrigin cells;

  # ===== the four differential arms =====
  # The call shape a caller writes: no cutoffs key at all, one id at a time.
  mismatchWhyFast = mismatchesBy (
    cell:
    why cell.ctx {
      inherit (cell) id;
      inherit (cell.c) changedId;
    } == whyFor cell.ctx { inherit (cell.c) changedId; } cell.id
  );

  # The overlay differential, over the cells that have a value. Same element-wise shape as
  # the fast-path arm; the cell list is the one narrowed above, and its size is pinned.
  mismatchesOver =
    xs: cmp: map (cell: { inherit (cell) seed id; }) (builtins.filter (cell: !(cmp cell)) xs);

  mismatchWhyOverlay = mismatchesOver overlayValueCells (
    cell:
    why cell.ctx {
      inherit (cell) id;
      inherit (cell.c) changedId;
      cutoffs = overlayOf cell;
    } == whyFor cell.ctx {
      inherit (cell.c) changedId;
      cutoffs = overlayOf cell;
    } cell.id
  );

  # The origin cells, as whole records: both routes must RETURN, and return the same thing.
  # The record comparison is the same one the 540 get — the split is in the cell list, never
  # in the predicate.
  mismatchWhyOverlayOrigin = mismatchesOver overlayOriginCells (
    cell:
    why cell.ctx {
      inherit (cell) id;
      inherit (cell.c) changedId;
      cutoffs = overlayOf cell;
    } == whyFor cell.ctx {
      inherit (cell.c) changedId;
      cutoffs = overlayOf cell;
    } cell.id
  );

  # Equality alone would be satisfied by two routes that refuse identically, which is
  # precisely the state these cells were in before the singleton guard. `deepSeq` because a
  # refusal lives inside the returned record's fields and a `tryEval` over an unforced
  # attrset reports success for a value nobody looked at.
  survives = e: (builtins.tryEval (builtins.deepSeq e true)).success;
  overlayOriginParity = map (cell: {
    inherit (cell) seed id;
    perCall = survives (
      why cell.ctx {
        inherit (cell) id;
        inherit (cell.c) changedId;
        cutoffs = overlayOf cell;
      }
    );
    dual = survives (
      whyFor cell.ctx {
        inherit (cell.c) changedId;
        cutoffs = overlayOf cell;
      } cell.id
    );
  }) overlayOriginCells;
  overlayOriginDisagreements = builtins.filter (r: r.perCall != r.dual) overlayOriginParity;
  overlayOriginBothReturn = builtins.filter (r: r.perCall && r.dual) overlayOriginParity;

  # The verdict every origin cell must carry: the origin is always recomputed, and under an
  # overlay it carries its own singleton path. Read off the corpus rather than asserted for
  # one fixture, so a guard that returned some OTHER total answer would still be caught.
  overlayOriginWrongVerdict = map (cell: { inherit (cell) seed id; }) (
    builtins.filter (
      cell:
      why cell.ctx {
        inherit (cell) id;
        inherit (cell.c) changedId;
        cutoffs = overlayOf cell;
      } != {
        verdict = "recomputed";
        paths = [ [ cell.id ] ];
      }
    ) overlayOriginCells
  );

  mismatchWhyNotFast = mismatchesBy (
    cell:
    whyNot cell.ctx {
      inherit (cell) id;
      inherit (cell.c) changedId;
    } == whyNotFor cell.ctx { inherit (cell.c) changedId; } cell.id
  );

  mismatchWhyNotOverlay = mismatchesOver overlayValueCells (
    cell:
    whyNot cell.ctx {
      inherit (cell) id;
      inherit (cell.c) changedId;
      cutoffs = overlayOf cell;
    } == whyNotFor cell.ctx {
      inherit (cell.c) changedId;
      cutoffs = overlayOf cell;
    } cell.id
  );

  # ===== the USAGE shape: bound once per change, spent over every id =====
  # The arms above re-apply the dual per cell, which is the differential's shape and not
  # a caller's. This one binds ONE dual per case and spends it across that case's whole
  # id set — the thing the construction exists for — and compares every answer.
  mismatchBoundOnce = lib.concatMap (
    k:
    let
      verdictFor = whyFor k.ctx { inherit (k.c) changedId; };
    in
    map
      (id: {
        inherit (k) seed;
        inherit id;
      })
      (
        builtins.filter (
          id:
          verdictFor id != why k.ctx {
            inherit id;
            inherit (k.c) changedId;
          }
        ) k.c.ids
      )
  ) cases;

  # ===== the armed controls: two duals that are WRONG, through the same differential =====
  # The fast-path answer a dual built on `coneSet` would give. Only the cone differs from
  # the subject's; everything the differential does to it is what it does to the subject.
  wrongDual =
    coneSet: id: if coneSet ? ${id} then { verdict = "recomputed"; } else { verdict = "unaffected"; };

  originOmittedCone =
    cell: lib.genAttrs (graph.dependentsOf cell.ctx.accessor cell.c.changedId) (_: true);
  transposedCone =
    cell:
    lib.genAttrs ([ cell.c.changedId ] ++ graph.reachableFrom cell.ctx.accessor cell.c.changedId) (
      _: true
    );

  controlMismatches =
    coneOf:
    map (cell: { inherit (cell) seed id; }) (
      builtins.filter (
        cell:
        wrongDual (coneOf cell) cell.id != why cell.ctx {
          inherit (cell) id;
          inherit (cell.c) changedId;
        }
      ) cells
    );

  originOmittedFires = controlMismatches originOmittedCone;
  transposedFires = controlMismatches transposedCone;
in
{
  flake.tests."provenanceDual" = {
    # ===== differential equivalence over the anchor's corpus =====
    test-whyFor-equals-why-fastpath = {
      expr = mismatchWhyFast;
      expected = [ ];
    };
    test-whyFor-equals-why-under-overlay = {
      expr = mismatchWhyOverlay;
      expected = [ ];
    };
    test-whyNotFor-equals-whyNot-fastpath = {
      expr = mismatchWhyNotFast;
      expected = [ ];
    };
    test-whyNotFor-equals-whyNot-under-overlay = {
      expr = mismatchWhyNotOverlay;
      expected = [ ];
    };
    test-whyFor-bound-once-equals-why = {
      expr = mismatchBoundOnce;
      expected = [ ];
    };

    # THE CELL COUNTS, pinned. An empty mismatch list says nothing about a corpus that
    # turned out to be empty; these are the arms that make the empties a reading. 660 = the
    # seeds' node counts summed (120 seeds, 4-7 nodes each), and it splits 540 + 120 at the
    # overlay: one origin cell per seed, since every seed's changedId is one of its ids.
    test-differential-cell-count = {
      expr = builtins.length cells;
      expected = 660;
    };
    test-overlay-cell-split = {
      expr = {
        value = builtins.length overlayValueCells;
        origin = builtins.length overlayOriginCells;
      };
      expected = {
        value = 540;
        origin = 120;
      };
    };

    # ===== the overlay's origin cells: both routes return, and return the same verdict =====
    # ★ THESE CELLS USED TO ASSERT A SHARED REFUSAL, and that was answer preservation over a
    # defect: `why` raised at `id == changedId` under any non-empty overlay, the dual
    # reproduced it, and the suite pinned the pair. The singleton guard in `_verdict` fixes
    # both routes at once, because both ARE `_verdict`, and these four cells are what holds
    # them to moving together. Equality is asserted separately from survival on purpose: two
    # routes that refuse identically satisfy equality, which is exactly the state this pair
    # was in before, so the survival count is what makes the empty mismatch list a reading.
    test-overlay-origin-routes-agree = {
      expr = overlayOriginDisagreements;
      expected = [ ];
    };
    test-overlay-origin-records-agree = {
      expr = mismatchWhyOverlayOrigin;
      expected = [ ];
    };
    test-overlay-origin-both-return-count = {
      expr = builtins.length overlayOriginBothReturn;
      expected = 120;
    };
    # The origin is always recomputed and can never be cut — there is no interior to cut —
    # and under an overlay it carries its own one-node path as the witness. Every one of the
    # 120, not one fixture.
    test-overlay-origin-verdict-is-recomputed = {
      expr = overlayOriginWrongVerdict;
      expected = [ ];
    };

    # ===== the controls, fired in the same run as the arms they certify =====
    # A cone without the change origin misses exactly the id == changedId cell, in every
    # seed: 120 cells, 120 seeds. The count and the seed coverage are both pinned, because
    # a control that fired on one seed would certify nothing about the other 119.
    test-control-origin-omitted-mismatch-count = {
      expr = builtins.length originOmittedFires;
      expected = 120;
    };
    test-control-origin-omitted-covers-every-seed = {
      expr = builtins.length (lib.unique (map (m: m.seed) originOmittedFires));
      expected = 120;
    };
    # The producer-direction cone: the same query asked of the transposed graph. It fires
    # broadly rather than at one cell, and it is the arm that would catch a dual that
    # reached for the forward closure because the name read like one.
    test-control-transposed-cone-fires = {
      expr = builtins.length transposedFires > 0;
      expected = true;
    };

    # ===== fixed fixtures: the same verdicts, read by hand =====
    test-whyFor-chain-recomputed = {
      expr = (whyFor chainCtx { changedId = "d"; } "a").verdict;
      expected = "recomputed";
    };
    # DIRECTION: an override of the root `a` does not touch the leaf `d`. The dual does not
    # transpose the accessor either — `dependentsOf` already walks consumer→producer.
    test-whyFor-chain-unaffected-direction = {
      expr = (whyFor chainCtx { changedId = "a"; } "d").verdict;
      expected = "unaffected";
    };
    # The change origin is in its own cone: `dirtySet` unions the changed ids in, which is
    # the cell the origin-omitting control flips.
    test-whyFor-trivial-origin = {
      expr = (whyFor chainCtx { changedId = "d"; } "d").verdict;
      expected = "recomputed";
    };
    # The fast path carries NO paths key, exactly as `why`'s does.
    test-whyFor-fastpath-no-paths = {
      expr = (whyFor chainCtx { changedId = "d"; } "a") ? paths;
      expected = false;
    };
    # ONE dual, spent over four ids: the shape the construction exists for, and the answers
    # differ across the ids, so a dual that ignored its argument would not read like this.
    test-whyFor-one-cone-many-ids = {
      expr =
        let
          verdictFor = whyFor chainCtx { changedId = "c"; };
        in
        map (id: (verdictFor id).verdict) [
          "a"
          "b"
          "c"
          "d"
        ];
      expected = [
        "recomputed"
        "recomputed"
        "recomputed"
        "unaffected"
      ];
    };
    # The overlay path is reached through the dual unchanged: both diamond branches cut ⇒
    # cutoff, with both witnesses.
    test-whyFor-cutoff-overlay = {
      expr =
        let
          r = whyFor diamondCtx {
            changedId = "d";
            cutoffs = {
              b = true;
              c = true;
            };
          } "a";
        in
        {
          inherit (r) verdict;
          cutNodes = builtins.sort builtins.lessThan r.cutNodes;
          nPaths = builtins.length r.paths;
        };
      expected = {
        verdict = "cutoff";
        cutNodes = [
          "b"
          "c"
        ];
        nPaths = 2;
      };
    };

    # ===== whyNotFor mirrors THIS library's whyNot, stated rather than only differenced =====
    # ★ THE CONTRACT IS THIS LIBRARY'S, AND IT IS NOT THE PLANE'S. Here `whyNot` answers
    # `null` for a recomputed id — there is no "why not" when the node was recomputed — so
    # the dual answers `null` there too. Stating it as its own cell rather than leaving it
    # to the differential is what keeps a later reconciliation of the two contracts from
    # passing here by inheriting the wrong one.
    test-whyNotFor-recomputed-null = {
      expr = whyNotFor chainCtx { changedId = "d"; } "a";
      expected = null;
    };
    test-whyNotFor-unaffected-record = {
      expr = whyNotFor chainCtx { changedId = "a"; } "d";
      expected = {
        reason = "unaffected";
      };
    };
    test-whyNotFor-cutoff-record = {
      expr = whyNotFor diamondCtx {
        changedId = "d";
        cutoffs = {
          b = true;
          c = true;
        };
      } "a";
      expected = {
        reason = "cutoff";
        at = [
          "b"
          "c"
        ];
      };
    };
  };
}
