# build — full evaluation into a flat relocatable store + a verifying trace.
#
# Mokhov 2018: §3.1 Store (flat relocatable id-keyed map; call-by-need
# dependency-order resolution via `prelude.fix`) + §4.2.2 verifying trace (per-key
# `{ deps; hash }`) + §2.1/§4.1 acyclicity (cyclic deps not allowed ⇒ each task
# executed at most once).
#
# Consumes a gen-graph accessor (the topology oracle) and a caller-supplied
# `recompute` (the node-eval, `accessor -> store -> id -> value`). Pre-checks
# acyclicity via graph.cycles and throws a *located* blame on a cycle — catchable
# via builtins.tryEval, never Nix's uncatchable infinite recursion inside the
# prelude.fix loop. Returns a BuiltCtx threading everything `override` needs to splice
# incrementally.
#
# Optional `fixpoint` param (default null): when null, build is EXACTLY the
# acyclic v1 behavior above — throw-on-any-cycle, `prelude.fix` store, no `fixpoint`
# key in the returned ctx. When present, build relaxes the precheck (a cycle is
# allowed iff every cyclic node carries a declared lattice) and computes the
# store STRATIFIED bottom-up over the condensation (quotient) graph:
#   - SCC partition + condensation: Tarjan 1972 / Kosaraju quotient-graph idiom
#     (gen-graph computes it closure-based, O(n²), pure-Nix).
#   - Per cyclic stratum: Arntzenius 2016 (Datafun Lemma 4) per-SCC least fixed
#     point via `runScc` (iterate-from-⊥ on the member lattices to quiescence).
#   - `cond.bottomUp` is PRODUCERS-FIRST (a consumer SCC appears after every SCC
#     it depends on), so each stratum reads already-CONVERGED lower strata out of
#     the accumulator. This is the build-domain-restriction: solve over the
#     ascending prefix only. It is what AVOIDS the v1 bare-`prelude.fix` splice
#     divergence — a single `prelude.fix` over all nodes dispatching `id ∈ scc ?
#     runScc : recompute` re-invokes runScc once per MEMBER and can read a
#     not-yet-converged peer SCC, a self-referential thunk black-hole that
#     escapes builtins.tryEval (Nix uncatchable infinite recursion). The
#     bottom-up fold never forms that thunk: a stratum is only ever solved once,
#     after its producers.
#
# Honest gap: the fixpoint path is OUTSIDE Mokhov/RTD's acyclic envelope. Each
# per-SCC convergence rests on the consumer's UNCHECKED monotonicity + finite-
# height obligation (Arntzenius's preconditions for Kleene ascent); the only
# runtime divergence guard is `runScc`'s per-member maxIter (a catchable blame).
#
# Edge convention: accessor.edges id = [ids that id depends on] (consumer→producer).
{ prelude, graph, ... }:
let
  inherit (import ./hash.nix { }) hashGuarded;
  inherit (import ./restabilize.nix { inherit prelude graph; }) runScc;

  build =
    {
      accessor,
      recompute,
      hashOf,
      fixpoint ? null,
    }:
    let
      # Authoritative cyclic id-set (sorted) — graph.cycles (gen-graph/lib/global.nix).
      cyclic = graph.cycles accessor;

      # Per-key trace shape, shared by both paths (Mokhov verifying-trace shape):
      # per-key dep list + content hash (null when the value is unhashable).
      traceFor =
        store:
        prelude.genAttrs accessor.nodes (id: {
          deps = accessor.edges id;
          hash = hashGuarded hashOf store.${id};
        });

      # --- v1 (acyclic) path: EXACTLY the original behavior. ---------------------
      v1 =
        let
          # Located cycle blame: throw-on-any-cycle (Mokhov 2018 §2.1/§4.1, cyclic
          # deps not allowed). gen-graph supplies the ids; the blame record is ours.
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

          # Flat relocatable store (Mokhov 2018 §3.1): prelude.fix resolves deps in
          # dependency order via call-by-need; terminates because the precheck
          # guarantees acyclicity.
          store = prelude.fix (s: prelude.genAttrs accessor.nodes (id: recompute accessor s id));
          trace = traceFor store;
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

      # --- fixpoint path: condensation-stratified bottom-up solve. ---------------
      stratified =
        let
          # Relaxed precheck: a cycle is allowed iff every cyclic node carries a
          # declared lattice. The undeclared ones are the blame (both fields kept
          # for debugging: `nodes` = the cyclic nodes lacking a lattice, `cycle` =
          # the full authoritative cyclic set).
          missing = builtins.filter (id: !(fixpoint.lattices ? ${id})) cyclic;
          undeclaredBlame = {
            why = "undeclared-cyclic-node";
            nodes = missing;
            cycle = cyclic;
          };

          cond = graph.condensation accessor;
          cyclicSet = prelude.genAttrs cyclic (_: true);

          # Bottom-up fold over the condensation strata (producers-first). Each
          # stratum reads the accumulator `acc` (the already-converged lower
          # strata) as its externals.
          solved = prelude.foldl' (
            acc: tag:
            let
              members = cond.members tag;
              isCyclicStratum = builtins.any (m: cyclicSet ? ${m}) members;
            in
            if isCyclicStratum then
              # Cyclic SCC: solve to its lfp ONCE for the whole component
              # (Arntzenius per-SCC fixpoint). Lower strata already sit in acc.
              acc
              // runScc {
                inherit accessor recompute;
                store = { };
                scc = members;
                higherStrata = acc;
                lattices = fixpoint.lattices;
              }
            else
              # Acyclic singleton: recompute reading acc (lower strata) as
              # externals. Byte-identical to v1's prelude.fix value (deps already in
              # acc, walked in dependency order).
              acc // prelude.genAttrs members (m: recompute accessor acc m)
          ) { } cond.bottomUp;

          store = solved;
          trace = traceFor store;
        in
        if missing != [ ] then
          throw "gen-rebuild: undeclared cyclic node: ${builtins.toJSON undeclaredBlame}"
        else
          {
            inherit
              store
              trace
              accessor
              recompute
              hashOf
              fixpoint
              ;
          };
    in
    if fixpoint == null then v1 else stratified;
in
{
  inherit build;
}
