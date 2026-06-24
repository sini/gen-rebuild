{
  lib,
  genRebuild,
  graph,
  ...
}:
let
  inherit (genRebuild)
    build
    verify
    earlyCutoff
    needsEval
    ;
  inherit (import ../../lib/hash.nix { }) hashGuarded;

  # chain a->b->c (edges a=["b"], b=["c"], c=[]) — consumer→producer.
  recompute =
    a: s: id:
    (a.nodeData id).weight + lib.foldl' (sum: dep: sum + s.${dep}) 0 (a.edges id);
  hashOf = v: builtins.hashString "sha256" (builtins.toJSON v);
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
  # ctx.store: c=100, b=110, a=111.

  # Override c := 200. cone = {a,b,c}; coneSet = all true.
  changedId = "c";
  accessor' = ctx.accessor // {
    nodeData = id: if id == changedId then { weight = 200; } else ctx.accessor.nodeData id;
  };
  cone = lib.unique ([ changedId ] ++ graph.dependentsOf accessor' changedId);
  coneSet = lib.genAttrs cone (_: true);
  # the recomputed store over the changed accessor: c=200, b=210, a=211.
  spliced = ctx.store // lib.fix (s: lib.genAttrs cone (id: recompute accessor' (ctx.store // s) id));
  newHashOf = id: hashGuarded hashOf spliced.${id};

  needsEvalCtx = needsEval {
    inherit (ctx) trace;
    inherit coneSet newHashOf accessor';
  };

  # --- a function-bearing node => hash = null => always-dirty ---
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
  lambdaNeedsEval = needsEval {
    inherit (lambdaCtx) trace;
    coneSet = {
      f = true;
    };
    newHashOf = _id: hashGuarded hashOf lambdaCtx.store.f;
    accessor' = lambdaCtx.accessor;
  };
in
{
  flake.tests."strategies" = {
    # ===== needsEval (RTD §5.3, PRE-cutoff) =====
    # changedId itself always needs evaluation.
    test-needsEval-changed = {
      expr = needsEvalCtx "c" "c";
      expected = true;
    };
    # b depends on c (whose hash moved 100->200) ⇒ must eval.
    test-needsEval-moved-dep = {
      expr = needsEvalCtx "c" "b";
      expected = true;
    };
    # a depends on b (whose hash moved 110->210) ⇒ must eval.
    test-needsEval-moved-transitive = {
      expr = needsEvalCtx "c" "a";
      expected = true;
    };
    # a function-bearing (hash = null) node is always-dirty ⇒ must eval.
    test-needsEval-null-hash = {
      expr = lambdaNeedsEval "f" "f";
      expected = true;
    };

    # ===== earlyCutoff (RTD §4.1, POST-recompute value compare) =====
    # recomputing c to its OLD value (100) ⇒ cut (reuse).
    test-earlyCutoff-cut = {
      expr = earlyCutoff { inherit hashOf; } {
        oldHash = ctx.trace.c.hash;
        newValue = 100;
      };
      expected = true;
    };
    # recomputing c to a NEW value (200) ⇒ no cut.
    test-earlyCutoff-nocut = {
      expr = earlyCutoff { inherit hashOf; } {
        oldHash = ctx.trace.c.hash;
        newValue = 200;
      };
      expected = false;
    };
    # null oldHash (was unhashable) ⇒ never a cut (always recompute).
    test-earlyCutoff-null-oldhash = {
      expr = earlyCutoff { inherit hashOf; } {
        oldHash = null;
        newValue = 100;
      };
      expected = false;
    };

    # ===== verify (Mokhov §4.2, trace-VALIDITY) =====
    # against the UNCHANGED store: every dep hash still matches the trace ⇒ reuse.
    test-verify-reuse-clean = {
      expr =
        (verify
          {
            inherit (ctx) trace store hashOf;
          }
          {
            accessor' = ctx.accessor;
            spliced = ctx.store;
          }
          "b"
        ).reuse;
      expected = true;
    };
    test-verify-reuse-value = {
      expr =
        (verify
          {
            inherit (ctx) trace store hashOf;
          }
          {
            accessor' = ctx.accessor;
            spliced = ctx.store;
          }
          "b"
        ).value;
      expected = ctx.store.b;
    };
    # against the spliced store where c moved (100->200): b's dep c is dirty ⇒ no reuse.
    test-verify-noreuse-moved = {
      expr =
        (verify {
          inherit (ctx) trace store hashOf;
        } { inherit accessor' spliced; } "b").reuse;
      expected = false;
    };
  };
}
