# dirtySet — the set of ids a multi-id change forces to recompute.
#
# Reps–Teitelbaum–Demers 1983 §4.3 AFFECTED set (an over-approximation; AFFECTED
# is determined by the updating process, not a priori). The cone is Arntzenius 2016
# Datafun reverse-reachability (`graph.dependentsOf`). `dirtySet` is intentionally
# the cheap over-approx — the hash-cutoff that prunes unchanged-hash nodes lives in
# `earlyCutoff`/`needsEval` (strategies.nix); the exact moved subset is `affectedSet`.
#
# Deduped union of the changed ids and their dependent cones: every node in a
# changed id's cone is considered dirty. Stays the reachable-cone set for callers
# that want it (the exact moved subset is `affectedSet`, not `dirtySet`).
#
# Uses concatMap over the single-target graph.dependentsOf rather than the
# O(n²) multi-target `dependents` — cheaper for the small changed-id sets v1 sees.
{ lib, graph, ... }:
{
  dirtySet =
    ctx: changedIds:
    lib.unique (changedIds ++ lib.concatMap (graph.dependentsOf ctx.accessor) changedIds);
}
