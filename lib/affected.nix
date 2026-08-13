# affected — the dependent cone of an id (provenance query).
#
# Arntzenius 2016 Datafun: single-target reverse reachability (the dependent cone
# of `id`); `graph.dependentsOf` is the Datafun-derived query.
#
# A thin re-export of graph.dependentsOf over the ctx's accessor: everyone who
# transitively depends on `id` (single-target). `impactOf` is an alias. This is
# the set `override` must recompute when `id` changes.
#
# Cost is graph.dependentsOf's own: Θ(n + E) to build the reverse index — it reads
# EVERY node's out-edges, reachable or not — then a BFS over that index costing
#   Θ( Σ_{u ∈ reach⁻ id} (1 + indeg u) )
# → reduces to the cone's size only where in-degree is BOUNDED, and never falls
# below the Θ(n + E) the index build pays whatever the cone's size; Θ(n²) on a
# complete DAG.
{ graph, ... }:
let
  affected = ctx: id: graph.dependentsOf ctx.accessor id;
in
{
  inherit affected;
  impactOf = affected;
}
