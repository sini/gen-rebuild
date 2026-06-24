# build — full evaluation into a flat relocatable store + a verifying trace.
#
# Mokhov 2018: §3.1 Store (flat relocatable id-keyed map; call-by-need
# dependency-order resolution via `lib.fix`) + §4.2.2 verifying trace (per-key
# `{ deps; hash }`) + §2.1/§4.1 acyclicity (cyclic deps not allowed ⇒ each task
# executed at most once).
#
# Consumes a gen-graph accessor (the topology oracle) and a caller-supplied
# `recompute` (the node-eval, `accessor -> store -> id -> value`). Pre-checks
# acyclicity via graph.cycles and throws a *located* blame on a cycle — catchable
# via builtins.tryEval, never Nix's uncatchable infinite recursion inside the
# lib.fix loop. Returns a BuiltCtx threading everything `override` needs to splice
# incrementally.
#
# Edge convention: accessor.edges id = [ids that id depends on] (consumer→producer).
{ lib, graph, ... }:
let
  inherit (import ./hash.nix { }) hashGuarded;

  build =
    {
      accessor,
      recompute,
      hashOf,
    }:
    let
      # Acyclicity precondition (Mokhov 2018 §2.1/§4.1: cyclic deps not allowed ⇒
      # each task executed at most once). graph.cycles returns the sorted cyclic
      # id-list (gen-graph/lib/global.nix); gen-rebuild constructs the located blame
      # from it — a tryEval-catchable thrown blame, vs Nix's uncatchable infinite
      # recursion (gen-graph supplies the ids; the blame record is ours).
      cyclic = graph.cycles accessor;
      blame =
        let
          a = builtins.head cyclic;
          b = if builtins.length cyclic > 1 then builtins.elemAt cyclic 1 else a;
        in
        {
          why = "cycle";
          cycle = cyclic;
          path = graph.pathsBetween accessor a b;
        };

      # Flat relocatable store (Mokhov 2018 §3.1): lib.fix resolves deps in
      # dependency order via call-by-need; terminates because the precheck
      # guarantees acyclicity.
      store = lib.fix (s: lib.genAttrs accessor.nodes (id: recompute accessor s id));

      # Verifying trace (Mokhov shape): per-key dep list + content hash
      # (null when the value is unhashable).
      trace = lib.genAttrs accessor.nodes (id: {
        deps = accessor.edges id;
        hash = hashGuarded hashOf store.${id};
      });
    in
    if cyclic != [ ] then
      throw "gen-rebuild: cycle detected: ${builtins.toJSON blame}"
    else
      {
        inherit
          store
          trace
          accessor
          recompute
          hashOf
          ;
      };
in
{
  inherit build;
}
