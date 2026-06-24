# build — full evaluation into a flat relocatable store + a verifying trace.
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
  # Does the value carry a function anywhere? Such values are not toJSON-able,
  # and the toJSON error is *uncatchable* by builtins.tryEval — so we detect the
  # partiality structurally rather than by guarding the hash application.
  containsFunction =
    v:
    if builtins.isFunction v then
      true
    else if builtins.isList v then
      builtins.any containsFunction v
    else if builtins.isAttrs v then
      builtins.any containsFunction (builtins.attrValues v)
    else
      false;

  # Apply the caller's content hash, guarded. A function-bearing value is partial
  # for hashOf — such nodes get hash = null and are treated as always-dirty (spec
  # §6 Phase-2b decision 1, clause (c)). Hashable values hash as normal.
  hashGuarded = hashOf: value: if containsFunction value then null else hashOf value;

  build =
    {
      accessor,
      recompute,
      hashOf,
    }:
    let
      # Acyclicity precondition. graph.cycles returns the sorted cyclic id-list
      # (gen-graph/lib/global.nix); gen-rebuild constructs the located blame from
      # it (gen-graph supplies the ids; the blame record is ours).
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

      # Flat relocatable store: lib.fix resolves deps in dependency order via
      # call-by-need; terminates because the precheck guarantees acyclicity.
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
