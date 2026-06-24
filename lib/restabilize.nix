# restabilize — per-member semi-naive SCC solver (runScc).
#
# Solves ONE strongly-connected component to its least fixed point by iterating
# each member's lattice from ⊥ (bottom) until per-member equality (quiescence).
# In-SCC deps read the CURRENT iterate; external (lower-stratum) deps read the
# fixed `store`/`higherStrata` — exactly what the merged `store // higherStrata
# // prev` provides to `recompute`.
#
# Theory citations:
#   - Arntzenius 2016 (Datafun Lemma 4): for a GENUINE-join (union/powerset, or
#     any finite-height bounded semilattice) lattice, iterate-from-⊥ ascends a
#     finite chain ⊥ ⊑ f(⊥) ⊑ f²(⊥) ⊑ … and converges at the lfp, detected by
#     eq-stabilization (prev == next). The reachability fixture is the ascent
#     witness: ⊥ = {} ⊑ {self} ⊑ {a,b}.
#   - Sloane 2010 §2.2 / Magnusson–Hedin (circular reference attributes): for an
#     OVERWRITE / no-op "join" (e.g. `join = _prev: v: v`) — which is NOT a
#     semilattice join, has no ⊑ order and no ascent witness — this is naive
#     iterate-to-stabilization: keep recomputing until the values stop moving.
#     Such fixtures converge by peer-agreement, NOT by lattice ascent.
#
# Honest gaps (load-bearing; consumer obligations, NOT checked here):
#   - MONOTONICITY of `recompute`/`join` is UNCHECKED. A non-monotone step can
#     oscillate forever (no Kleene/Arntzenius termination guarantee).
#   - FINITE HEIGHT of the lattice is UNCHECKED. An infinite-ascending chain
#     never quiesces.
#   - The ONLY divergence guard is per-member `maxIter`: on overrun, runScc
#     throws a LOCATED, tryEval-CATCHABLE blame (never Nix's uncatchable infinite
#     recursion). `widen` (applied after join, per-member) is the consumer's tool
#     to force finite ascent on tall/infinite lattices.
#   - This is OUTSIDE the rebuilder's acyclic envelope (build.nix prechecks
#     acyclicity and forbids cycles); runScc is the cyclic-stratum solver that
#     the acyclic build cannot express.
#
# `graph`/`scope` are threaded for sibling ops (restabilize lands beside this);
# runScc itself takes its topology via the `accessor` field.
{ lib, ... }:
let
  # runScc — solve one SCC to its least fixed point (per-member iterate-from-⊥).
  #
  # runScc :: {
  #   accessor,            # any object exposing .edges / .nodeData (topology oracle)
  #   store,               # externals map (lower-stratum / fixed inputs)
  #   recompute,           # accessor -> store -> id -> value (the node-eval)
  #   scc,                 # [id] — the SCC member ids (M)
  #   higherStrata,        # { <id> = value } — already-solved lower-stratum results
  #   lattices,            # per-NODE { bottom; join; eq ? (==); widen ? null; maxIter ? 100; }
  # } -> { <id> = value }   # the fixed-point iterate for each SCC member
  runScc =
    {
      accessor,
      store,
      recompute,
      scc,
      higherStrata,
      lattices,
    }:
    let
      M = scc;
      # Per-member equality, defaulting to structural `==` when the lattice omits eq.
      eqOf = m: lattices.${m}.eq or (a: b: a == b);

      go =
        iter: prev:
        let
          # In-SCC deps read the current iterate (prev); externals read store /
          # higherStrata. The // merge gives `recompute` the unified view.
          cur = lib.genAttrs M (m: recompute accessor (store // higherStrata // prev) m);
          # PINNED DETAIL 1: widen applies AFTER join, per-member.
          next = lib.mapAttrs (
            m: _v:
            let
              j = lattices.${m}.join prev.${m} cur.${m};
            in
            if (lattices.${m}.widen or null) != null then lattices.${m}.widen prev.${m} j else j
          ) cur;
          maxI = lib.foldl' (acc: m: lib.max acc (lattices.${m}.maxIter or 100)) 0 M;
          # PINNED DETAIL 2: lastDelta = the still-moving members' prev/next pairs.
          moving = lib.filter (m: !(eqOf m prev.${m} next.${m})) M;
          blame = {
            why = "fixpoint-diverged";
            scc = M;
            iters = iter;
            lastDelta = lib.genAttrs moving (m: {
              prev = prev.${m};
              next = next.${m};
            });
          };
        in
        # maxIter-blame guard: a tryEval-CATCHABLE thrown blame, never Nix
        # infinite recursion.
        if iter >= maxI then
          throw "gen-rebuild: fixpoint did not converge: ${builtins.toJSON blame}"
        # Per-MEMBER eq: each node's OWN eq predicate drives its quiescence.
        else if lib.all (m: eqOf m prev.${m} next.${m}) M then
          next
        else
          go (iter + 1) next;
    in
    # Per-member ⊥ seed (Arntzenius iterate-from-bottom).
    go 0 (lib.genAttrs M (m: lattices.${m}.bottom));
in
{
  inherit runScc;
}
