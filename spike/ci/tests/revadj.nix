# Guard tests for direct reverse-adjacency (spike/revadj.nix) + the §10 parent-edge negative.
#
# LOAD-BEARING (the whole point of revadj): V-push enqueues a moved node's DIRECT
# dependents — its immediate reverse neighbours — NOT its full transitive reverse
# cone. Using the transitive set (`graph.dependentsOf`) would re-materialise
# O(|cone|) per move and silently defeat the minimality cutoff while STILL passing
# the byte-identity gate, corrupting the work metric with no soundness alarm. So
# `directDependents` must return ONLY immediate reverse neighbours, and the first
# guard pins direct ≠ transitive on a 3-chain.
#
# Edge convention (gen-rebuild): `accessor.edges id = [ids that id DEPENDS ON]`
# (consumer→producer). So the DIRECT dependents of producer `p` = the consumers
# `c` with `p ∈ edges c`.
#
# §10 NEGATIVE (parent-edge falsification): an accessor carries TWO independent edge
# kinds — dataflow I-edges (`edges`, walked by `dependentsOf`) and parent P-edges
# (`parent`, walked by `ancestorsOf`). They point at DIFFERENT sets. The minimality
# cutoff is sound only because it prunes the cone by the DATAFLOW reverse-reach
# (`dependentsOf`). Pruning by the parent chain (`ancestorsOf`) instead recomputes
# the wrong nodes, leaving the genuinely-affected dataflow consumers stale ⇒ the
# spliced store does NOT equal the from-scratch oracle. We assert that `== oracle`
# is `false`, closing the idea that the parent DAG is irrelevant to dataflow cutoff.
{
  lib,
  graph,
  spike,
  genRebuild,
  ...
}:
let
  # --- the A→B→X dataflow chain WITH a divergent parent P-edge (A's parent = Z). --
  # I-edges (consumer→producer): B deps A, X deps B  ⇒ dataflow cone of A = {A,B,X}.
  # P-edge: A's parent = Z (an unrelated node)        ⇒ ancestorsOf A = {Z}, disjoint.
  acc = graph.mkGraph {
    edges = [
      {
        from = "B";
        to = "A";
      }
      {
        from = "X";
        to = "B";
      }
    ];
    parents = [
      {
        from = "A";
        to = "Z";
      }
    ];
    nodeData = {
      A = {
        weight = 10;
      };
      B = {
        weight = 1;
      };
      X = {
        weight = 1;
      };
      Z = {
        weight = 100;
      };
    };
  };

  # Additive recompute (own weight + Σ dep values) — every dataflow consumer MOVES
  # when its producer changes, so the negative cannot be masked by an accidental
  # cutoff: B and X genuinely need recompute when A's weight changes.
  recompute =
    a: s: id:
    (a.nodeData id).weight + lib.foldl' (sum: dep: sum + s.${dep}) 0 (a.edges id);
  hashOf = v: builtins.hashString "sha256" (builtins.toJSON v);

  # the data-change: bump A's weight. Edges/parents unchanged (data-change envelope).
  changes.A = {
    weight = 20;
  };
  accessor' = acc // {
    nodeData = id: changes.${id} or (acc.nodeData id);
  };

  # from-scratch oracle store over the CHANGED accessor.
  oracle =
    (genRebuild.build {
      accessor = accessor';
      inherit recompute hashOf;
    }).store;

  # prior store (over the unchanged accessor), the splice base.
  priorStore =
    (genRebuild.build {
      accessor = acc;
      inherit recompute hashOf;
    }).store;

  # A one-shot WRONG splice: prune the recompute set by the PARENT chain
  # (ancestorsOf) instead of the dataflow reverse-reach (dependentsOf). Recompute
  # only changedIds ++ ancestorsOf — i.e. {A,Z} — leaving B,X stale. (This helper
  # lives in the test, not the variant surface, because it is a deliberate bug.)
  changedIds = builtins.attrNames changes;
  ancestorsPrunedSet = lib.unique (
    changedIds ++ lib.concatMap (graph.ancestorsOf accessor') changedIds
  );
  ancestorsPrunedStore =
    priorStore
    // lib.fix (s: lib.genAttrs ancestorsPrunedSet (id: recompute accessor' (priorStore // s) id));

  # the CORRECT splice (prune by dependentsOf) for the positive cross-check.
  dependentsPrunedSet = lib.unique (
    changedIds ++ lib.concatMap (graph.dependentsOf accessor') changedIds
  );
  dependentsPrunedStore =
    priorStore
    // lib.fix (s: lib.genAttrs dependentsPrunedSet (id: recompute accessor' (priorStore // s) id));
in
{
  flake.tests.revadj = {
    # --- GUARD: direct ≠ transitive ---------------------------------------
    # On the A→B→X chain, directDependents of A is JUST its immediate reverse
    # neighbour B — NOT the transitive {B,X}. This is the whole point of revadj.
    test-direct-not-transitive = {
      expr = {
        direct =
          (spike.revadj.directDependents acc [
            "A"
            "B"
            "X"
          ]).A;
        transitive = graph.dependentsOf acc "A";
      };
      expected = {
        direct = [ "B" ];
        transitive = [
          "B"
          "X"
        ];
      };
    };

    # B's direct dependent is X (the next link); A is B's producer, not dependent.
    test-direct-mid-chain = {
      expr =
        (spike.revadj.directDependents acc [
          "A"
          "B"
          "X"
        ]).B;
      expected = [ "X" ];
    };

    # X is a sink: no in-cone consumer reads it ⇒ no key in the reverse index.
    test-direct-sink-absent = {
      expr =
        (spike.revadj.directDependents acc [
          "A"
          "B"
          "X"
        ]) ? X;
      expected = false;
    };

    # --- §10 NEGATIVE: parent-edge falsification --------------------------
    # Pruning the cone by the PARENT chain (ancestorsOf) yields a store that does
    # NOT equal the from-scratch oracle — the wrong-edge prune is unsound.
    test-parent-edge-negative = {
      expr = ancestorsPrunedStore == oracle;
      expected = false;
    };

    # the divergence is real, not a degenerate parent-less case: the dataflow
    # reverse-reach and the parent chain are genuinely different sets.
    test-edge-kinds-diverge = {
      expr = {
        dependents = graph.dependentsOf accessor' "A";
        ancestors = graph.ancestorsOf accessor' "A";
      };
      expected = {
        dependents = [
          "B"
          "X"
        ];
        ancestors = [ "Z" ];
      };
    };

    # POSITIVE cross-check: pruning by the CORRECT (dataflow dependentsOf) set IS
    # byte-identical to the oracle — so the negative isolates the edge-kind, not a
    # broken splice mechanism.
    test-dependents-prune-sound = {
      expr = dependentsPrunedStore == oracle;
      expected = true;
    };
  };
}
