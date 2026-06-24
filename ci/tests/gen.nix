# Deterministic seeded random-DAG generator for the override soundness property.
#
# A flake-parts module that exposes `mkCase` as a module arg (consumed by
# override.nix). PURE: every case derives from an int seed via an LCG — no
# currentTime / no impurity — so the property is reproducible.
#
# `mkCase seed` returns { acc, acc', changedId, newDecls, recompute, hashOf }:
#   acc   — a random DAG (edges only point to lower indices ⇒ acyclic)
#   acc'  — acc with changedId's nodeData replaced by newDecls
# so the soundness test can compare override(build acc) against build acc'.
#
# SCOPE of what this property proves (matches override.nix's guarantee):
#   - DATA-change only: acc' differs from acc solely in changedId's nodeData;
#     edges are identical. So this proves data-change override == full rebuild,
#     NOT topology-changing override (the v2 seam — edges are never varied here).
#   - Node values are INTEGERS (hashable / toJSON-able), so store byte-equality is
#     well-defined; function-valued nodes are out of this property's reach (they
#     are sound-by-always-dirty, not by store ==). The fixed adversarial fixtures
#     in override.nix complement these random DAGs with hand-built shapes.
{ lib, graph, ... }:
let
  # glibc LCG. 64-bit safe: lcg always returns < 2^31, and the salts i,j added are
  # small (< 2^31), so every lcg input stays < 2^32 ⇒ 1103515245·input < 9.2e18.
  mod = a: b: a - b * (a / b);
  lcg = s: mod (1103515245 * s + 12345) 2147483648;
  # A deterministic pseudo-random from a seed + two small salts.
  rnd =
    seed: i: j:
    lcg (lcg (lcg (seed + 1) + i) + j);

  mkCase =
    seed:
    let
      nNodes = 4 + mod (rnd seed 0 0) 4; # 4..7 nodes
      idx = lib.range 0 (nNodes - 1);
      nameOf = i: "n${toString i}";
      ids = map nameOf idx;

      # Edges: node i may depend on any j < i (⇒ acyclic). Include with ~1/2 prob.
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

      # Pick the node to override + its new data.
      changedId = nameOf (mod (rnd seed 7 7) nNodes);
      newDecls = {
        weight = 1 + mod (rnd seed 13 13) 100;
      };

      # acc' : the from-scratch ground truth — acc with changedId's data replaced.
      acc' = acc // {
        nodeData = id: if id == changedId then newDecls else acc.nodeData id;
      };

      # node value = own weight + sum of dep values (deps from accessor.edges).
      recompute =
        a: s: id:
        (a.nodeData id).weight + lib.foldl' (sum: dep: sum + s.${dep}) 0 (a.edges id);

      hashOf = v: builtins.hashString "sha256" (builtins.toJSON v);
    in
    {
      inherit
        acc
        acc'
        changedId
        newDecls
        recompute
        hashOf
        ids
        ;
    };
in
{
  _module.args.mkCase = mkCase;
}
