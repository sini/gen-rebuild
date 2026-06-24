# Deterministic seeded random-CYCLIC-graph generator for the restabilize
# fixed-point-equality property.
#
# A flake-parts module that exposes `mkCyclicCase` as a module arg (consumed by
# restabilize.nix's tests). PURE: every case derives from an int seed via the
# same glibc LCG as gen.nix — no currentTime / no impurity — so the property is
# reproducible.
#
# `mkCyclicCase seed` returns
#   { acc, acc', changedId, newDecls, recompute, hashOf, lattices, ids }:
#   acc       — a random graph with controlled back-edges ⇒ at least the chance
#               of one or more 2-SCCs (genuine cycles, not just a DAG)
#   acc'      — acc with changedId's nodeData replaced by newDecls (DATA change;
#               edges identical ⇒ same cyclic set)
# so the property can compare restabilize(build acc, …) against build acc'.
#
# CONVERGENCE is guaranteed for EVERY seed: `recompute` is a MAX-fold (max of the
# node's own weight and all its dep values). max is monotone and bounded by the
# global maximum weight ⇒ runScc ascends a finite chain and quiesces well under
# maxIter = 100. The 120-seed property therefore never triggers an uncatchable
# runScc divergence — the soundness gate measures fixed-point-EQUALITY, not
# termination luck.
{ lib, graph, ... }:
let
  # glibc LCG (identical to gen.nix). 64-bit safe: lcg < 2^31, salts small.
  mod = a: b: a - b * (a / b);
  lcg = s: mod (1103515245 * s + 12345) 2147483648;
  rnd =
    seed: i: j:
    lcg (lcg (lcg (seed + 1) + i) + j);

  mkCyclicCase =
    seed:
    let
      k = 4 + mod (rnd seed 0 0) 4; # 4..7 nodes
      idx = lib.range 0 (k - 1);
      nameOf = i: "n${toString i}";
      ids = map nameOf idx;

      # Acyclic base edges: node i may depend on any j < i with ~1/2 prob (same
      # rule as gen.nix — these alone are acyclic).
      baseEdges = lib.concatMap (
        i:
        lib.concatMap (
          j:
          lib.optional (mod (rnd seed i j) 2 == 0) {
            from = nameOf i;
            to = nameOf j;
          }
        ) (lib.range 0 (i - 1))
      ) (lib.range 1 (k - 1));

      # Controlled back-edges to form genuine SCCs: for each i in 1..k-1, with
      # ~1/3 prob add BOTH directions between i and i-1, guaranteeing a real
      # 2-SCC (i ↔ i-1). Adding the forward edge i→(i-1) explicitly (it may also
      # already be in baseEdges; lib.unique dedups) ensures the cycle exists.
      cycleEdges = lib.concatMap (
        i:
        lib.optionals (mod (rnd seed i 42) 3 == 0) [
          {
            from = nameOf i;
            to = nameOf (i - 1);
          }
          {
            from = nameOf (i - 1);
            to = nameOf i;
          }
        ]
      ) (lib.range 1 (k - 1));

      edgesList = lib.unique (baseEdges ++ cycleEdges);

      # Weights: 1..100 per node.
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

      # MAX-fold recompute: max of the node's own weight and all dep values.
      # Monotone + bounded by the global max weight ⇒ always converges.
      recompute =
        a: s: id:
        lib.foldl' lib.max (a.nodeData id).weight (map (d: s.${d}) (a.edges id));

      # Per-node OVERWRITE lattice for ALL ids. Declaring every node is safe:
      # build/restabilize only require the CYCLIC nodes to carry a lattice; the
      # acyclic ones are recomputed directly and ignore their entry.
      lattices = {
        lattices = lib.genAttrs ids (_: {
          bottom = 0;
          join = _prev: v: v;
          eq = (a: b: a == b);
        });
      };

      changedId = nameOf (mod (rnd seed 7 7) k);
      newDecls = {
        weight = 1 + mod (rnd seed 13 13) 100;
      };

      # acc' : the from-scratch ground truth — acc with changedId's data replaced.
      acc' = acc // {
        nodeData = id: if id == changedId then newDecls else acc.nodeData id;
      };
    in
    {
      inherit
        acc
        acc'
        changedId
        newDecls
        recompute
        hashOf
        lattices
        ids
        ;
    };

  hashOf = v: builtins.hashString "sha256" (builtins.toJSON v);
in
{
  _module.args.mkCyclicCase = mkCyclicCase;
}
