# Tests for the provenance read layer — support / why / whyNot.
#
# support = transitive declared producers (Acar 2002 adg read backward / in-edge
# direction; Radul 2009 §6.1 NAME-only). why = the recomputed/cutoff/unaffected
# verdict an override of `changedId` would produce for `id` (Acar S7 read-rule:
# l∈C → recomputed, cmp-unchanged → cutoff, l∉C → unaffected). whyNot = the thin
# negative wrapper. The why⟺dirtySet 120-seed property is the soundness anchor.
{
  lib,
  genRebuild,
  graph,
  mkCase,
  ...
}:
let
  inherit (genRebuild)
    build
    support
    why
    whyNot
    dirtySet
    ;

  # support / why are TOPOLOGICAL reads — node values are irrelevant, so the
  # structural fixtures use the identity recompute (id ↦ id). The 120-seed
  # property uses mkCase's own weight-summing recompute.
  hashOf = v: builtins.hashString "sha256" (builtins.toJSON v);
  mkCtx =
    accessor:
    build {
      inherit accessor;
      recompute =
        _a: _s: id:
        id;
      inherit hashOf;
    };

  sort = builtins.sort builtins.lessThan;

  # chain a->b->c->d : edges a=[b], b=[c], c=[d], d=[] (consumer→producer).
  chainCtx = mkCtx graph.fixtures.chain;
  # diamond a->{b,c}->d : edges a=[b,c], b=[d], c=[d], d=[].
  diamondCtx = mkCtx graph.fixtures.diamond;

  # --- a function-bearing node (hash = null) for the null-hash support/why cases.
  # f depends on g; g's value carries a function ⇒ trace.g.hash = null.
  lambdaAcc = graph.mkGraph {
    edges = [
      {
        from = "f";
        to = "g";
      }
    ];
    nodeData = {
      f = { };
      g = { };
    };
  };
  lambdaCtx = build {
    accessor = lambdaAcc;
    recompute =
      _a: _s: id:
      if id == "g" then { fn = x: x + 1; } else 0;
    inherit hashOf;
  };

  # ===== why ⟺ dirtySet over 120 random seeds (the soundness anchor) =====
  # For every node id of every seed: (why … != "unaffected") ⟺ id ∈ dirtySet.
  seeds = lib.range 1 120;
  whyMatchesDirty =
    seed:
    let
      c = mkCase seed;
      ctx = build {
        accessor = c.acc;
        inherit (c) recompute hashOf;
      };
      cone = dirtySet ctx [ c.changedId ];
    in
    builtins.all (
      id:
      let
        recomputed =
          (why ctx {
            inherit id;
            inherit (c) changedId;
          }).verdict != "unaffected";
      in
      recomputed == builtins.elem id cone
    ) c.ids;
  whyDirtyMismatchSeeds = builtins.filter (seed: !(whyMatchesDirty seed)) seeds;

  # ===== synthetic cutoff overlay (cutNodes-as-SET) =====
  # diamond: why "a" "d" has TWO interior-disjoint paths [a,b,d] and [a,c,d].
  # Block BOTH with cutoffs {b=true; c=true;} ⇒ verdict cutoff, cutNodes={b,c}.
  cutBoth = why diamondCtx {
    id = "a";
    changedId = "d";
    cutoffs = {
      b = true;
      c = true;
    };
  };
  # block only ONE branch (b) ⇒ the c-branch stays live ⇒ recomputed.
  cutOne = why diamondCtx {
    id = "a";
    changedId = "d";
    cutoffs = {
      b = true;
    };
  };
in
{
  flake.tests."provenance" = {
    # ===== support: transitive declared producers (sorted, self-excluded) =====
    test-support-chain-a = {
      expr = support chainCtx "a";
      expected = [
        "b"
        "c"
        "d"
      ];
    };
    test-support-chain-c = {
      expr = support chainCtx "c";
      expected = [ "d" ];
    };
    test-support-chain-leaf-empty = {
      expr = support chainCtx "d";
      expected = [ ];
    };
    test-support-no-self = {
      expr = builtins.elem "a" (support chainCtx "a");
      expected = false;
    };
    # diamond: a's producers are the full lower cone {b,c,d}, deduped + sorted.
    test-support-diamond-a = {
      expr = support diamondCtx "a";
      expected = [
        "b"
        "c"
        "d"
      ];
    };
    # support reads the TRACE SNAPSHOT deps, not a re-fetched accessor.
    test-support-snapshot = {
      expr = support diamondCtx "a";
      expected = sort (
        graph.reachableFrom {
          edges = id: diamondCtx.trace.${id}.deps;
        } "a"
      );
    };
    # null-hash node is still a structural producer (support is topological).
    test-support-null-hash = {
      expr = support lambdaCtx "f";
      expected = [ "g" ];
    };

    # ===== why: recomputed verdict (id reaches changedId forward) =====
    test-why-recomputed = {
      expr =
        (why chainCtx {
          id = "a";
          changedId = "d";
        }).verdict;
      expected = "recomputed";
    };
    # trivial origin: id == changedId is always recomputed (canReach fast path /
    # depth-0; changedId is never an interior node, never cut).
    test-why-trivial-origin = {
      expr =
        (why chainCtx {
          id = "d";
          changedId = "d";
        }).verdict;
      expected = "recomputed";
    };
    # DIRECTION: an override of the root `a` does NOT touch the leaf `d`
    # (d does not depend on a). Proves why does NOT transpose the accessor.
    test-why-unaffected-direction = {
      expr =
        (why chainCtx {
          id = "d";
          changedId = "a";
        }).verdict;
      expected = "unaffected";
    };
    # the verdict-only fast path (cutoffs == {}) carries NO paths key.
    test-why-fastpath-no-paths = {
      expr =
        (why chainCtx {
          id = "a";
          changedId = "d";
        }) ? paths;
      expected = false;
    };
    test-why-unaffected-no-paths = {
      expr =
        (why chainCtx {
          id = "d";
          changedId = "a";
        }) ? paths;
      expected = false;
    };
    # diamond multipath: a reaches d via b AND c ⇒ recomputed (≥1 live path).
    test-why-diamond-multipath = {
      expr =
        (why diamondCtx {
          id = "a";
          changedId = "d";
        }).verdict;
      expected = "recomputed";
    };

    # ===== why: cutoff overlay — cutNodes is a SET (one witness per path) =====
    test-why-cutoff-verdict = {
      expr = cutBoth.verdict;
      expected = "cutoff";
    };
    test-why-cutoff-cutnodes-set = {
      expr = sort cutBoth.cutNodes;
      expected = [
        "b"
        "c"
      ];
    };
    test-why-cutoff-has-paths = {
      expr = cutBoth ? paths && builtins.length cutBoth.paths == 2;
      expected = true;
    };
    # blocking only one branch leaves a live path ⇒ recomputed (NOT cutoff).
    test-why-cutoff-one-branch-live = {
      expr = cutOne.verdict;
      expected = "recomputed";
    };
    # a null-hash interior node can NEVER be a cutoff: overlay claims g is cut, but
    # g is unhashable (always-dirty) ⇒ the path stays live ⇒ recomputed.
    test-why-null-hash-never-cutoff = {
      expr =
        (why lambdaCtx {
          id = "f";
          changedId = "g";
          cutoffs = {
            g = true;
          };
        }).verdict;
      expected = "recomputed";
    };

    # ===== whyNot: thin negative wrapper =====
    # recomputed ⇒ null (it WAS touched, so there is no "why not").
    test-whyNot-recomputed-null = {
      expr = whyNot chainCtx {
        id = "a";
        changedId = "d";
      };
      expected = null;
    };
    # unaffected ⇒ a reason record.
    test-whyNot-unaffected-reason = {
      expr =
        (whyNot chainCtx {
          id = "d";
          changedId = "a";
        }).reason;
      expected = "unaffected";
    };
    # cutoff ⇒ a reason naming the cut witnesses.
    test-whyNot-cutoff-reason = {
      expr =
        (whyNot diamondCtx {
          id = "a";
          changedId = "d";
          cutoffs = {
            b = true;
            c = true;
          };
        }).reason;
      expected = "cutoff";
    };

    # ===== the soundness anchor: why ⟺ dirtySet over 120 seeds =====
    test-why-iff-dirtySet-120 = {
      expr = whyDirtyMismatchSeeds;
      expected = [ ];
    };
  };
}
