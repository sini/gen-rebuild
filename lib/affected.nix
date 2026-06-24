# affected — the dependent cone of an id (provenance query).
#
# Arntzenius 2016 Datafun: single-target reverse reachability (the dependent cone
# of `id`); `graph.dependentsOf` is the Datafun-derived query.
#
# A thin re-export of graph.dependentsOf over the ctx's accessor: everyone who
# transitively depends on `id` (single-target, O(reachable)). `impactOf` is an
# alias. This is the set `override` must recompute when `id` changes.
{ graph, ... }:
let
  affected = ctx: id: graph.dependentsOf ctx.accessor id;
in
{
  inherit affected;
  impactOf = affected;
}
