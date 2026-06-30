# structural — topology-changing deltas: retract + applyEdgeDelta.
#
# v1's `override` is a DATA-change only (edges fixed; lib/override.nix). These ops
# move the topology: `retract` deletes a node and splices it out of its
# dependents; `applyEdgeDelta` replaces a node's declared edge set (and sub-builds
# any newly-reachable producers). Both rebuild a FULL accessor record (v1
# override only swaps `nodeData`), re-write `trace.deps` for every node whose
# edge-set the delta touched, and — for the cycle-RISKING op — re-run a located,
# tryEval-catchable cycle check (a new edge can close a cycle the build-time
# precheck never saw), never Nix's uncatchable infinite recursion.
#
# Theory citations:
#   - Radul 2009 §6.2 `kick-out!` — retract is the DESTRUCTIVE delete half only
#     (NAME-faithful): no TMS-rememberable worldview / no premise lattice. Ours is
#     the contract declared-edge producer set, not a minimal-premise support set.
#   - Acar 2002 §4.5 — obsolete-edge splice-out is the retract MECHANISM (prune the
#     dead node + recompute its dependent cone). "Purity" here = PERSISTENCE of the
#     reader closures (Acar §8), NOT effect-freedom — `requiredBy` catches DECLARED
#     in-edges only, not the ambient hidden read (the K5/H4 risk, unenforceable in
#     pure Nix).
#   - Forgy 1982 — `applyEdgeDelta` is `modify = delete + add` over a node's edge
#     set (the change-token vocabulary; the rebuild mechanism is Acar/RTD).
#
# Edge convention: accessor.edges id = ids that id depends on (consumer→producer).
{ prelude, graph, ... }:
let
  inherit (import ./hash.nix { }) hashGuarded;

  # mkAccessor — full accessor record rebuild (v2 §3.4). Mirrors registry.nix
  # mkGraph: `edges` is wrapped with prelude.unique (the registry.nix:74 dedup), and
  # `parent` is carried through. Unlike v1 override's partial `// { nodeData }`,
  # structural ops move `nodes`/`edges`, so the whole record is rebuilt.
  mkAccessor =
    {
      edges,
      nodes,
      nodeData,
      parent,
    }:
    {
      inherit nodes nodeData parent;
      edges = id: prelude.unique (edges id);
    };

  # reCycleCheck — STRUCTURAL self-reachability query over accessor'.edges, seeded
  # at `touched` (the nodes whose out-edges the delta changed). Any new cycle
  # routes through a touched node that is now self-reachable. Throws a LOCATED
  # blame (the build.nix shape: why="cycle"; cycle=[…]) — tryEval-catchable, never
  # Nix infinite recursion. Restrict-to-touched is sound ONLY because the prior
  # topology was build-proven acyclic and edges not touched cannot create a cycle.
  # Returns the accessor unchanged on success (so it can wrap a let-binding).
  reCycleCheck =
    accessor': touched:
    let
      selfReach = graph.selfReachable { inherit (accessor') edges; };
      offenders = builtins.filter selfReach touched;
      blame = {
        why = "cycle";
        cycle = offenders;
        # one representative cyclic path for the located blame (offenders are
        # self-reachable, so a path from the first offender back to itself exists).
        path =
          let
            o = builtins.head offenders;
          in
          graph.pathsBetween { inherit (accessor') edges; } o o;
      };
    in
    if offenders == [ ] then
      accessor'
    else
      throw "gen-rebuild: structural delta closed a cycle: ${builtins.toJSON blame}";

  # spliceStore — reverse-cone recompute over a base store + obsolete prune.
  # `base` is the store the prelude.fix reads through (already pruned of any dead key);
  # `revCone` is the set of ids to recompute (the dependents whose values move).
  # A revCone node reads its FRESH value from `s`; everything else falls through to
  # `base` (the authoritative `base // s` form — bare `s` would miss non-cone
  # deps). `keep` is the final node set: store keys NOT in keep are pruned
  # (obsolete-node removal). Acar §4.5 splice-out.
  spliceStore =
    {
      accessor',
      base,
      revCone,
      recompute,
      keep,
    }:
    let
      spliced =
        base // prelude.fix (s: prelude.genAttrs revCone (id: recompute accessor' (base // s) id));
      keepSet = prelude.genAttrs keep (_: true);
    in
    prelude.filterAttrs (id: _: keepSet ? ${id}) spliced;
in
{
  inherit mkAccessor;

  # retract — delete deadId from the graph (Radul kick-out!, destructive half).
  #
  # retractPolicy ∈ { "error", "recompute-without" } (default "error"):
  #   "error"             — throw a LOCATED blame if deadId has DECLARED in-edges
  #                         (some dependent still names it as a producer). The
  #                         conservative default: a declared reader of a deleted
  #                         producer is treated as a contract violation.
  #   "recompute-without" — splice deadId out of every dependent's edge list and
  #                         re-fold the dependent cone sans deadId. Soundness is
  #                         claimed for structural (edge-folding) readers: a reader
  #                         that sums over `accessor.edges id` simply drops the
  #                         deadId term. A reader that hard-reads deadId by NAME
  #                         (outside the declared edges) is the unenforceable K5/H4
  #                         ambient read — out of contract.
  #
  # NO cycle recheck: deletion only SHRINKS the graph, so it cannot create a cycle.
  retract =
    ctx: deadId: retractPolicy:
    let
      policy = if retractPolicy == null then "error" else retractPolicy;
      inherit (ctx) recompute hashOf accessor;

      # Declared in-edges: dependents that name deadId as a producer.
      requiredBy = builtins.filter (id: builtins.elem deadId (accessor.edges id)) accessor.nodes;

      # The node-removed accessor: deadId dropped from nodes; every dependent's
      # edge list has deadId spliced out (an edge a→deadId is DROPPED, not
      # redirected). nodeData/edges fall through for the surviving nodes.
      nodes' = builtins.filter (id: id != deadId) accessor.nodes;
      edges' = id: builtins.filter (d: d != deadId) (accessor.edges id);
      accessor' = mkAccessor {
        edges = edges';
        nodes = nodes';
        inherit (accessor) nodeData parent;
      };

      # Reverse cone of deadId = its dependents (the nodes whose value moves when
      # deadId vanishes). Computed over the PRIOR accessor (deadId still present),
      # so dependentsOf can see who pointed at it.
      revCone = graph.dependentsOf accessor deadId;

      # Splice base: deadId removed FIRST. A dependent that still hard-reads deadId
      # by name would then throw "missing" (correct — that is the out-of-contract
      # ambient read), rather than silently reading a STALE value.
      baseWithoutDead = removeAttrs ctx.store [ deadId ];
      store' = spliceStore {
        inherit accessor' recompute;
        base = baseWithoutDead;
        inherit revCone;
        keep = nodes';
      };

      # Re-write trace.deps for EVERY edge-touched node (the dependents whose edge
      # list lost deadId) + drop deadId's own trace entry, and re-hash the cone
      # nodes whose value moved. Edge-touched = requiredBy (their declared edges
      # changed); they must carry FRESH deps (else verify/support read stale deps).
      traceWithoutDead = removeAttrs ctx.trace [ deadId ];
      trace' =
        traceWithoutDead
        // prelude.genAttrs revCone (id: {
          deps = accessor'.edges id;
          hash = hashGuarded hashOf store'.${id};
        });

      blame = {
        why = "retract-in-edges";
        dead = deadId;
        inherit requiredBy;
      };
    in
    if policy == "error" && requiredBy != [ ] then
      throw "gen-rebuild: retract of node with declared in-edges: ${builtins.toJSON blame}"
    else
      {
        store = store';
        trace = trace';
        accessor = accessor';
        inherit recompute hashOf;
      };

  # applyEdgeDelta — replace changedId's edge set with newEdges (the
  # topology-changing override v1 lacked; Forgy modify = delete + add).
  #
  #   - newEdges is DEDUPED (prelude.unique) to match the mkGraph edge contract
  #     (registry.nix:74). `[b c c]` must collapse to `[b c]` else the recompute
  #     fold double-counts the dup (the CONFIRMED bug: store.a = 211 not 311).
  #   - nodes' = prelude.unique (nodes ++ newEdges) — grows if a new target appears.
  #   - NEW PRODUCERS: a newEdges target z may name a node not in the prior nodes
  #     (or whose forward closure adds nodes). z is a *dependency* of changedId,
  #     NOT a *dependent*, so the reverse cone never binds it ⇒ `recompute
  #     changedId`'s `s.z` would throw "missing". So the newly-reachable producer
  #     subgraph is SUB-BUILT (a forward prelude.fix over accessor') and spliced into
  #     the base BEFORE the reverse-cone fix.
  #   - reCycleCheck seeded at the touched node [changedId] (added edges can close
  #     a cycle the build-time precheck never saw); skipped when addedEdges == [].
  applyEdgeDelta =
    ctx: changedId: newEdges:
    let
      inherit (ctx) recompute hashOf accessor;
      newEdgesU = prelude.unique newEdges;

      # The new edge function (changedId's out-edges replaced). The edge function
      # is independent of the node-set, so forward reachability can be queried off
      # it before the node-set is finalized.
      edges' = id: if id == changedId then newEdgesU else accessor.edges id;

      # New producers: forward-reachable from newEdges over the new edge function,
      # minus the prior node set. These are fresh DEPENDENCIES that the reverse cone
      # fix does not bind, so the full node-set must grow to include them and they
      # must be SUB-BUILT before the reverse-cone fix (else `recompute changedId`'s
      # `s.z` throws "missing").
      priorSet = prelude.genAttrs accessor.nodes (_: true);
      forwardReach = prelude.unique (
        newEdgesU ++ prelude.concatMap (graph.reachableFrom { edges = edges'; }) newEdgesU
      );
      newProducers = builtins.filter (id: !(priorSet ? ${id})) forwardReach;

      # New full accessor: changedId's edges replaced; node set grown by ALL the
      # newly-reachable producers (not just the direct newEdges targets — a fresh
      # target may itself read further fresh producers). edges'/nodeData/parent fall
      # through for everyone else.
      nodes' = prelude.unique (accessor.nodes ++ newProducers);
      accessor' = mkAccessor {
        edges = edges';
        nodes = nodes';
        inherit (accessor) nodeData parent;
      };

      # Located cycle recheck (seeded at the only touched node) BEFORE any splice.
      # Forces selfReachable over accessor'.edges; throws a catchable located blame.
      addedEdges = builtins.filter (e: !(builtins.elem e (accessor.edges changedId))) newEdgesU;
      checkedAccessor = if addedEdges == [ ] then accessor' else reCycleCheck accessor' [ changedId ];

      # Reverse cone of changedId over the NEW accessor (added edges pull new
      # producers in as DEPS, not dependents; removed edges shrink the cone).
      revCone = prelude.unique ([ changedId ] ++ graph.dependentsOf checkedAccessor changedId);
      producerStore = prelude.fix (
        s: prelude.genAttrs newProducers (id: recompute checkedAccessor (ctx.store // s) id)
      );

      # Reverse-cone splice over (ctx.store ∪ producerStore): a revCone node reads
      # its fresh value from `s`; new producers + non-cone deps fall through to the
      # extended base. keep = nodes' (no obsolete prune here; nodes only grow).
      base = ctx.store // producerStore;
      store' = spliceStore {
        accessor' = checkedAccessor;
        inherit base recompute revCone;
        keep = nodes';
      };

      # Re-write trace.deps for the edge-touched node (changedId) + re-hash the
      # cone nodes whose value moved + the new producers. changedId's deps MUST be
      # the FRESH newEdgesU (else verify/support read stale deps).
      rehash = prelude.unique (revCone ++ newProducers);
      trace' =
        ctx.trace
        // prelude.genAttrs rehash (id: {
          deps = checkedAccessor.edges id;
          hash = hashGuarded hashOf store'.${id};
        });
    in
    {
      store = store';
      trace = trace';
      accessor = checkedAccessor;
      inherit recompute hashOf;
    };
}
