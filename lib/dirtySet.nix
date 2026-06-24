# dirtySet — the set of ids a multi-id change forces to recompute.
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
