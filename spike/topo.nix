# spike/topo.nix — cone-local producers-first rank (`coneRank`).
#
# WHY THIS FILE EXISTS: V-push (a later task) drains a worklist in PRODUCERS-FIRST
# rank order over the CONE. That rank is load-bearing — V-push is byte-identical to
# a full build ONLY IF every dependency (producer) is ranked before every dependent
# (consumer). This computes that rank CONE-LOCALLY: O(|cone| + edges-in-cone), NOT
# the whole-graph O(n²) `graph.condensation`. The guard suite (spike/ci/tests/topo.nix)
# cross-checks the order against `(graph.condensation acc).bottomUp` filtered to the
# cone on all three rank-order shapes — the topological-consistency acceptance.
#
# Edge convention (gen-rebuild): `accessor.edges id = [ids that id DEPENDS ON]`
# (consumer→producer). So a producer must come BEFORE its consumers in `order`.
{ lib, graph }:
{
  # coneRank accessor cone -> { order; depth; precompute; }
  #   depth id    = 0 if id has no in-cone producers, else 1 + max(depth of its
  #                 in-cone producers).
  #   order       = cone sorted ASCENDING by depth (producers first), id tie-break.
  #   precompute  = Σ |in-cone producers of id| over cone (the counted edge touches).
  # `lib.fix` over `genAttrs cone` memoizes depth; an acyclic cone guarantees the
  # recursion terminates (every producer is strictly shallower than its consumer).
  coneRank =
    accessor: cone:
    let
      coneSet = lib.genAttrs cone (_: true);
      # in-cone producers of id: the deps of id that fall inside the cone.
      prodOf = id: builtins.filter (d: coneSet ? ${d}) (accessor.edges id);
      depth = lib.fix (
        d:
        lib.genAttrs cone (
          id:
          let
            ps = prodOf id;
          in
          if ps == [ ] then 0 else 1 + lib.foldl' (m: p: lib.max m d.${p}) 0 ps
        )
      );
      order = builtins.sort (
        a: b: if depth.${a} == depth.${b} then a < b else depth.${a} < depth.${b}
      ) cone;
      precompute = lib.foldl' (acc: id: acc + builtins.length (prodOf id)) 0 cone;
    in
    {
      inherit order depth precompute;
    };
}
