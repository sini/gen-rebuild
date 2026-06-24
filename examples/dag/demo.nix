# B demo — incremental override + located cycle, as a pure value record.
#
# A small synthetic "fleet": hosts read a shared network base and each other's
# outputs (peer IPs), a gateway aggregates the hosts (prometheus-target shaped).
# Overriding one host recomputes ONLY its dependent cone; the rest is reused
# byte-for-byte; a cyclic variant yields a *located blame*, not Nix's uncatchable
# infinite recursion.
#
# This is the function layer (takes genRebuild) so the ci test can inject the lib
# purely; examples/dag/default.nix wraps it with getFlake for `nix eval -f`.
{ genRebuild }:
let
  inherit (genRebuild) build override dirtySet;

  # Hand-written accessor (the demo needs no gen-graph constructor; build wires
  # graph.cycles/dependentsOf in itself). Edge convention: edges id = deps of id.
  mkAcc = nodeDataMap: edgesMap: {
    nodes = builtins.attrNames nodeDataMap;
    edges = id: edgesMap.${id} or [ ];
    nodeData = id: nodeDataMap.${id} or { };
    parent = _id: null;
  };

  fleetData = {
    net = {
      weight = 10;
    }; # shared network base
    h1 = {
      weight = 1;
    }; # host 1
    h2 = {
      weight = 2;
    }; # host 2
    h3 = {
      weight = 3;
    }; # host 3 — also reads peer h1
    gw = {
      weight = 0;
    }; # gateway — aggregates all hosts
  };
  fleetEdges = {
    net = [ ];
    h1 = [ "net" ];
    h2 = [ "net" ];
    h3 = [
      "net"
      "h1"
    ];
    gw = [
      "h1"
      "h2"
      "h3"
    ];
  };
  fleet = mkAcc fleetData fleetEdges;

  # node value = own weight + sum of dep values. The trace marker makes the
  # cone-only recompute visible when you run `nix eval -f examples/dag`.
  recompute =
    acc: s: id:
    let
      deps = acc.edges id;
    in
    builtins.trace "recompute ${id}" (
      (acc.nodeData id).weight + builtins.foldl' (sum: d: sum + s.${d}) 0 deps
    );

  hashOf = v: builtins.hashString "sha256" (builtins.toJSON v);

  ctx = build {
    accessor = fleet;
    inherit recompute hashOf;
  };

  # Override host h1. Its dependent cone is {h1, h3, gw} (h3 reads h1; gw aggregates).
  changedId = "h1";
  newDecls = {
    weight = 100;
  };
  overridden = override ctx changedId newDecls;

  # Ground truth: a full rebuild with h1's data replaced.
  fleet' = fleet // {
    nodeData = id: if id == changedId then newDecls else fleet.nodeData id;
  };
  fullRebuild = build {
    accessor = fleet';
    inherit recompute hashOf;
  };

  cone = dirtySet ctx [ changedId ]; # {h1, h3, gw}
  untouched = builtins.filter (id: !(builtins.elem id cone)) fleet.nodes; # {net, h2}

  # Poison proof of cone-only recompute: a recompute that THROWS on the untouched
  # nodes. override must never call it on them (it splices their prior values), so
  # the override succeeds; a from-scratch build, which recomputes everything, hits
  # the poison and fails. The asymmetry IS the proof.
  poison =
    acc: s: id:
    if builtins.elem id untouched then throw "POISON: ${id} was recomputed" else recompute acc s id;
  poisonedCtx = ctx // {
    recompute = poison;
  };
  overrideWithPoison = override poisonedCtx changedId newDecls;
  fullBuildWithPoison = build {
    accessor = fleet;
    recompute = poison;
    inherit hashOf;
  };

  # Cyclic variant: make the network base depend on the gateway → net→gw→h*→net.
  cyclicFleet = mkAcc fleetData (fleetEdges // { net = [ "gw" ]; });
  cyclicResult =
    builtins.tryEval
      (build {
        accessor = cyclicFleet;
        inherit recompute hashOf;
      }).store;
in
{
  # --- observable state ---
  cleanStore = ctx.store; # { net=10; h1=11; h2=12; h3=24; gw=47; }
  overrideStore = overridden.store; # { net=10; h1=110; h2=12; h3=123; gw=245; }
  recomputedCone = builtins.sort builtins.lessThan cone; # [ gw h1 h3 ]
  untouchedNodes = builtins.sort builtins.lessThan untouched; # [ h2 net ]

  # --- the thesis, as booleans ---
  # override == a full re-eval with h1 changed (soundness).
  resultEqualsFullRebuild = overridden.store == fullRebuild.store;
  # untouched nodes are reused byte-for-byte from the prior store.
  untouchedReused = builtins.all (id: overridden.store.${id} == ctx.store.${id}) untouched;
  # override never recomputes the poisoned untouched nodes … (deepSeq forces the
  # store values, not just the attrset spine, so a poison throw would surface).
  coneOnlyRecompute = (builtins.tryEval (builtins.deepSeq overrideWithPoison.store true)).success;
  # … whereas a full build does (proving the poison is real, not vacuous).
  poisonIsReal = !(builtins.tryEval (builtins.deepSeq fullBuildWithPoison.store true)).success;
  # a cycle is a located blame caught by tryEval, not uncatchable infinite recursion.
  cycleIsLocatedBlame = !cyclicResult.success;
}
