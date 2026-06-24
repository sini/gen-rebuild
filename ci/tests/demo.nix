# Surfaces the B demo (examples/dag) as a ci test so `nix flake check` verifies
# the thesis end-to-end. The demo logic lives in examples/dag/demo.nix; here we
# inject genRebuild purely (no getFlake) and assert its result record.
{ genRebuild, ... }:
let
  demo = import ../../examples/dag/demo.nix { inherit genRebuild; };
in
{
  flake.tests.demo = {
    # override(host) == full re-eval with that host changed.
    test-result-equals-full-rebuild = {
      expr = demo.resultEqualsFullRebuild;
      expected = true;
    };
    # untouched nodes reused byte-for-byte.
    test-untouched-reused = {
      expr = demo.untouchedReused;
      expected = true;
    };
    # override recomputes ONLY the cone (poison on untouched nodes never fires).
    test-cone-only-recompute = {
      expr = demo.coneOnlyRecompute;
      expected = true;
    };
    # the poison is real: a full build WOULD recompute the untouched nodes.
    test-poison-is-real = {
      expr = demo.poisonIsReal;
      expected = true;
    };
    # the recomputed cone of overriding h1 is exactly {h1, h3, gw}.
    test-recomputed-cone = {
      expr = demo.recomputedCone;
      expected = [
        "gw"
        "h1"
        "h3"
      ];
    };
    # the untouched (reused) nodes are exactly {h2, net}.
    test-untouched-nodes = {
      expr = demo.untouchedNodes;
      expected = [
        "h2"
        "net"
      ];
    };
    # a cycle yields a located blame caught by tryEval, not infinite recursion.
    test-cycle-located-blame = {
      expr = demo.cycleIsLocatedBlame;
      expected = true;
    };
    # spot-check the recomputed values (hand-computed, independent of the lib).
    test-override-store-gw = {
      expr = demo.overrideStore.gw;
      expected = 245;
    };
  };
}
