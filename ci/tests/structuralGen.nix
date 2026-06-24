# Deterministic seeded random-DAG generator for the STRUCTURAL soundness
# properties — the edge-VARYING analogue of gen.nix.
#
# A flake-parts module exposing `mkStructuralCase` as a module arg. PURE: every
# case derives from an int seed via an LCG (no currentTime / no impurity), so the
# properties are reproducible. Where gen.nix varies only a node's DATA (edges
# fixed), this generator varies the TOPOLOGY: it produces an edge delta (a node's
# dep-set replaced) and a node retraction (a node deleted + spliced out of its
# dependents), each paired with the from-scratch ground-truth accessor over the
# NEW topology.
#
# `mkStructuralCase seed` returns
#   { acc, accEdge, changedId, newEdges, accRetract, deadId,
#     recompute, hashOf, ids } where
#   acc         — a random acyclic DAG (edges point to lower indices)
#   accEdge      — acc with changedId's edge-set replaced by newEdges (still
#                  acyclic: newEdges target only lower indices) — the
#                  applyEdgeDelta ground truth
#   accRetract   — acc with deadId deleted from nodes AND spliced out of every
#                  dependent's edge list — the `retract` ground truth
#
# SCOPE: node values are INTEGERS (hashable / toJSON-able), so store
# byte-equality is well-defined; the recompute mirrors gen.nix
# (own weight + Σ dep values), so a topology change genuinely moves values.
{ lib, graph, ... }:
let
  # glibc LCG (same constants/64-bit-safety argument as gen.nix).
  mod = a: b: a - b * (a / b);
  lcg = s: mod (1103515245 * s + 12345) 2147483648;
  rnd =
    seed: i: j:
    lcg (lcg (lcg (seed + 1) + i) + j);

  mkStructuralCase =
    seed:
    let
      nNodes = 5 + mod (rnd seed 0 0) 4; # 5..8 nodes (≥5 so an edge delta has room)
      idx = lib.range 0 (nNodes - 1);
      nameOf = i: "n${toString i}";
      ids = map nameOf idx;

      # Base edges: node i may depend on any j < i (⇒ acyclic), ~1/2 prob.
      edgesList = lib.concatMap (
        i:
        lib.concatMap (
          j:
          lib.optional (mod (rnd seed i j) 2 == 0) {
            from = nameOf i;
            to = nameOf j;
          }
        ) (lib.range 0 (i - 1))
      ) (lib.range 1 (nNodes - 1));

      weightsMap = lib.listToAttrs (
        map (i: {
          name = nameOf i;
          value = {
            weight = 1 + mod (rnd seed i 99) 100;
          };
        }) idx
      );

      acc = graph.mkGraph {
        edges = edgesList;
        nodeData = weightsMap;
      };

      # ----- the EDGE delta -----------------------------------------------------
      # changedId = ni with i ≥ 1 (so it has lower-index candidate producers).
      changedIdx = 1 + mod (rnd seed 7 7) (nNodes - 1); # 1..nNodes-1
      changedId = nameOf changedIdx;
      # newEdges: a fresh ~1/2 subset of { nj : j < changedIdx } — targeting only
      # lower indices keeps the new topology acyclic (so the oracle can `build`).
      # A DIFFERENT salt than edgesList so the dep-set genuinely changes.
      newEdges = lib.concatMap (j: lib.optional (mod (rnd seed (changedIdx + 50) j) 2 == 0) (nameOf j)) (
        lib.range 0 (changedIdx - 1)
      );

      # accEdge: the from-scratch ground truth — acc's edge list with changedId's
      # out-edges replaced by newEdges, rebuilt via mkGraph (same lib.unique edge
      # dedup as the in-lib mkAccessor).
      edgesWithoutChanged = builtins.filter (e: e.from != changedId) edgesList;
      newEdgeRecords = map (t: {
        from = changedId;
        to = t;
      }) newEdges;
      accEdge = graph.mkGraph {
        edges = edgesWithoutChanged ++ newEdgeRecords;
        nodeData = weightsMap;
      };

      # ----- the RETRACTION -----------------------------------------------------
      # deadId = some nj. Pick one; retraction deletes it and splices it out of
      # every dependent's edge list (an edge a→deadId is dropped, NOT redirected).
      deadId = nameOf (mod (rnd seed 23 23) nNodes);
      edgesWithoutDead = builtins.filter (e: e.from != deadId && e.to != deadId) edgesList;
      weightsWithoutDead = removeAttrs weightsMap [ deadId ];
      accRetract = graph.mkGraph {
        edges = edgesWithoutDead;
        nodeData = weightsWithoutDead;
      };

      recompute =
        a: s: id:
        (a.nodeData id).weight + lib.foldl' (sum: dep: sum + s.${dep}) 0 (a.edges id);
      hashOf = v: builtins.hashString "sha256" (builtins.toJSON v);
    in
    {
      inherit
        acc
        accEdge
        changedId
        newEdges
        accRetract
        deadId
        recompute
        hashOf
        ids
        ;
    };
in
{
  _module.args.mkStructuralCase = mkStructuralCase;
}
