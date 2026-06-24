# spike/revadj.nix — DIRECT reverse-adjacency (`directDependents`).
#
# WHY THIS FILE EXISTS: V-push enqueues a moved node's DIRECT dependents — its
# immediate reverse neighbours — NOT its full transitive reverse cone. Using the
# transitive set (`graph.dependentsOf`) would re-materialise O(|cone|) work per
# move and silently defeat the minimality cutoff while STILL passing the
# byte-identity gate, corrupting the work metric with no soundness alarm. So this
# builds the DIRECT reverse-adjacency, restricted to the cone.
#
# gen-graph's `_reverseIndex` (lib/global.nix:18-30) is exactly this shape but is
# PRIVATE (not exported), so the spike re-derives it via ONE `groupBy` over the
# cone edges — restricted to cone members on both endpoints.
#
# Edge convention (gen-rebuild): `accessor.edges id = [ids that id DEPENDS ON]`
# (consumer→producer). So the DIRECT dependents of producer `p` = the consumers
# `c` (in-cone) with `p ∈ edges c` (and `p` itself in-cone). Mirrors _reverseIndex:
# each edge c→p becomes a reverse entry { name = p; value = c; }, grouped by p.
{ lib, graph }:
{
  # directDependents accessor cone -> { <producerId> = [direct in-cone consumers]; }
  # One groupBy over the cone edges, both endpoints restricted to the cone. A
  # producer with no in-cone consumer (a sink) simply gets no key.
  directDependents =
    accessor: cone:
    let
      coneSet = lib.genAttrs cone (_: true);
      pairs = lib.concatMap (
        c:
        map (p: {
          name = p;
          value = c;
        }) (builtins.filter (d: coneSet ? ${d}) (accessor.edges c))
      ) cone;
    in
    builtins.mapAttrs (_: es: map (e: e.value) es) (builtins.groupBy (e: e.name) pairs);
}
