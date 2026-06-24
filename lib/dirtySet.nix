# dirtySet — the set of ids a multi-id change forces to recompute.
#
# Reps–Teitelbaum–Demers 1983 §4.3 AFFECTED set (an over-approximation; AFFECTED
# is determined by the updating process, not a priori). The cone is Arntzenius 2016
# Datafun reverse-reachability (`graph.dependentsOf`). v1 omits the hash-cutoff that
# prunes unchanged-hash nodes.
#
# Deduped union of the changed ids and their dependent cones. v1 is an
# over-approximation: every node in a changed id's cone is considered dirty
# (the hash-cutoff that prunes unchanged-hash nodes is the v2 `earlyCutoff`).
#
# Uses concatMap over the single-target graph.dependentsOf rather than the
# O(n²) multi-target `dependents` — cheaper for the small changed-id sets v1 sees.
{ lib, graph, ... }:
{
  dirtySet =
    ctx: changedIds:
    lib.unique (changedIds ++ lib.concatMap (graph.dependentsOf ctx.accessor) changedIds);
}
