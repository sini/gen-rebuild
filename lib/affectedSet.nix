# affectedSet — exact AFFECTED via a hash post-filter over the over-approx cone.
#
# Reps–Teitelbaum–Demers 1983 §4.3: the AFFECTED set = the keys whose value ACTUALLY
# changes, discovered BY the propagation, never precomputed. v1's `dirtySet` is the
# over-approx reachable cone (it STAYS, for callers that want the cheap reachable
# set); `affectedSet` is the exact subset whose hash moved this rebuild.
#
# The chicken/egg (a value-change verdict needs the new value, which needs recompute,
# which needs the AFFECTED set) is broken WITHOUT observing force-order: the prelude.fix
# DOMAIN is the over-approx cone (so reused deps fall through to ctx.store), each cone
# node is gated on needsEval (RTD 1983 §5.3 NeedToBeEvaluated, PRE-cutoff), and
# AFFECTED is POST-filtered from the resulting hashes. This is exactly override's
# splice generalized to a multi-id change — so `affectedSet`'s `affected` is identical
# to the set `override` re-hashes, and `affected ⊆ cone` by construction.
#
# `needsEval` is imported from strategies.nix — the ONE definition (no inlined
# parallel predicate). hashMoved (lib/hash.nix §3.5 gate) is null-safe: a
# function-bearing cone node (hash = null) is always affected, never false-clean.
#
# Precondition (RTD's never-assign-non-final invariant relies on it): acyclic AND
# fixed edges (the data-change envelope — accessor' differs from ctx.accessor only in
# the changedIds' nodeData). Topology-changing deltas are the v2 applyDelta seam.
{ prelude, graph, ... }:
let
  inherit (import ./hash.nix { }) hashGuarded hashMoved;
  inherit (import ./strategies.nix { }) needsEval;
in
{
  affectedSet =
    ctx:
    { accessor', changedIds }:
    let
      # Over-approx cone of all changed ids (edges fixed ⇒ cone is stable). O(1)
      # membership via genAttrs — never builtins.elem.
      cone = prelude.unique (changedIds ++ prelude.concatMap (graph.dependentsOf accessor') changedIds);
      coneSet = prelude.genAttrs cone (_: true);
      changedSet = prelude.genAttrs changedIds (_: true);
      newHashOf = id: hashGuarded ctx.hashOf builtStore.${id};

      # needsEval-gated splice (identical to override's): a cone node is recomputed
      # iff it is a changed id, has a null hash, or has a moved-hash in-cone dep;
      # otherwise its prior value is reused. needsEval takes a single changedId, so
      # for the multi-id change a node mustEval iff ANY changed id forces it — which
      # reuses the ONE strategies.needsEval predicate per changed id.
      builtStore =
        ctx.store
        // prelude.fix (
          s:
          prelude.genAttrs cone (
            id:
            let
              spliced = ctx.store // s;
              mustEval =
                (changedSet ? ${id})
                || prelude.any (
                  cid:
                  needsEval {
                    inherit (ctx) trace;
                    inherit coneSet newHashOf accessor';
                  } cid id
                ) changedIds;
            in
            if mustEval then ctx.recompute accessor' spliced id else ctx.store.${id}
          )
        );

      # AFFECTED = post-filtered from hashes (the keys whose value actually moved).
      affected = builtins.filter (id: hashMoved (newHashOf id) (ctx.trace.${id}.hash or null)) cone;
      reused = builtins.filter (id: !(builtins.elem id affected)) cone;
      hashes = prelude.genAttrs cone newHashOf;
    in
    {
      inherit affected hashes reused;
    };
}
