# Direct tests for affectedSet — exact AFFECTED via hash post-filter over the cone
# (RTD 1983 §4.3). affectedSet ctx { accessor'; changedIds } -> { affected; hashes;
# reused }: `affected` = cone nodes whose hash moved, `reused` = the rest, `hashes` =
# per-cone-node new hash. The over-approx cone (dirtySet) stays the recompute domain.
{
  lib,
  genRebuild,
  graph,
  ...
}:
let
  inherit (genRebuild) build affectedSet dirtySet;

  recompute =
    a: s: id:
    (a.nodeData id).weight + lib.foldl' (sum: dep: sum + s.${dep}) 0 (a.edges id);
  hashOf = v: builtins.hashString "sha256" (builtins.toJSON v);

  # chain a -> b -> c (a deps b, b deps c). ctx.store: c=100, b=110, a=111.
  acc = graph.mkGraph {
    edges = [
      {
        from = "a";
        to = "b";
      }
      {
        from = "b";
        to = "c";
      }
    ];
    nodeData = {
      a = {
        weight = 1;
      };
      b = {
        weight = 10;
      };
      c = {
        weight = 100;
      };
    };
  };
  ctx = build {
    accessor = acc;
    inherit recompute hashOf;
  };

  # Override leaf c := 200. cone = {a,b,c}; ALL three values move (c=200,b=210,a=211).
  accC = acc // {
    nodeData = id: if id == "c" then { weight = 200; } else acc.nodeData id;
  };
  affC = affectedSet ctx {
    accessor' = accC;
    changedIds = [ "c" ];
  };

  # Override root a := 5. cone = {a} (nothing depends on a). Only a moves (115).
  accA = acc // {
    nodeData = id: if id == "a" then { weight = 5; } else acc.nodeData id;
  };
  affA = affectedSet ctx {
    accessor' = accA;
    changedIds = [ "a" ];
  };

  # --- value-collision: abs(weight - 50) so a changed-weight can keep its value ---
  absRecompute =
    a: _s: id:
    let
      x = (a.nodeData id).weight - 50;
    in
    if x < 0 then -x else x;
  collAcc = graph.mkGraph {
    nodeData = {
      l = {
        weight = 30;
      };
    };
  };
  collCtx = build {
    accessor = collAcc;
    recompute = absRecompute;
    hashOf = hashOf;
  };
  # |30-50| = 20; override to weight 70 ⇒ |70-50| = 20 (collision). Nothing affected.
  collAcc' = collAcc // {
    nodeData = id: if id == "l" then { weight = 70; } else collAcc.nodeData id;
  };
  affColl = affectedSet collCtx {
    accessor' = collAcc';
    changedIds = [ "l" ];
  };

  # --- function-bearing node (hash = null) is always affected when in the cone ---
  lambdaAcc = graph.mkGraph {
    nodeData = {
      f = { };
    };
  };
  lambdaCtx = build {
    accessor = lambdaAcc;
    recompute = _acc: _s: _id: { fn = x: x + 1; };
    inherit hashOf;
  };
  affLambda = affectedSet lambdaCtx {
    accessor' = lambdaAcc;
    changedIds = [ "f" ];
  };
in
{
  flake.tests."affectedSet" = {
    # ===== full move: leaf change moves the whole chain =====
    test-affected-c-all = {
      expr = builtins.sort builtins.lessThan affC.affected;
      expected = [
        "a"
        "b"
        "c"
      ];
    };
    test-reused-c-empty = {
      expr = affC.reused;
      expected = [ ];
    };
    test-hashes-c-leaf = {
      expr = affC.hashes.c;
      expected = hashOf 200;
    };
    test-hashes-c-root = {
      expr = affC.hashes.a;
      expected = hashOf 211;
    };

    # ===== root change: cone is just {a}; only a is affected =====
    test-affected-a-only = {
      expr = affA.affected;
      expected = [ "a" ];
    };
    test-hashes-a = {
      expr = affA.hashes.a;
      expected = hashOf 115;
    };

    # ===== affected ⊆ cone (subset of the over-approx reachable set) =====
    test-affected-subset-cone-c = {
      expr = builtins.all (id: builtins.elem id (dirtySet ctx [ "c" ])) affC.affected;
      expected = true;
    };

    # ===== value collision ⇒ AFFECTED is empty (RTD: value unchanged ⇒ not affected) =====
    test-affected-empty-on-collision = {
      expr = affColl.affected;
      expected = [ ];
    };
    test-reused-on-collision = {
      expr = affColl.reused;
      expected = [ "l" ];
    };

    # ===== function-bearing (hash = null) node is always affected (always-dirty) =====
    test-affected-null-hash = {
      expr = affLambda.affected;
      expected = [ "f" ];
    };
    test-hashes-null-hash = {
      expr = affLambda.hashes.f;
      expected = null;
    };
  };
}
