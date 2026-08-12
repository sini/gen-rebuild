# Rebuilder strategies — three reuse predicates routed through the v2 §3.5 hash gate
# (an internal spec coordinate, NOT a paper one — see `lib/structural.nix`'s "v2 §3.4").
# verify: Mokhov 2018 §4.2 verifying-trace (trace-VALIDITY). earlyCutoff: RTD 1983
# §4.1 unchanged-value cutoff (POST-recompute). needsEval: RTD 1983 §5.3
# NeedToBeEvaluated (PRE-cutoff) — DISTINCT from verify: RTD introduces
# NeedToBeEvaluated as a SEPARATE set gating whether to evaluate at all, not as a
# comparison of values, so the two predicates are different in kind. (That reading is
# ours; "complementary to / distinct from" are not RTD's words and are no longer
# quoted as such.) They COINCIDE only in the single-changed-input acyclic data-change
# envelope, NOT a definitional identity.
{ ... }:
let
  inherit (import ./hash.nix { }) hashGuarded hashEq hashMoved;
in
{
  verify =
    ctx:
    { accessor', spliced }:
    id:
    let
      depsMatch = ctx.trace.${id}.deps == accessor'.edges id;
      allDepsClean = builtins.all (
        d: hashEq (hashGuarded ctx.hashOf spliced.${d}) (ctx.trace.${d}.hash or null)
      ) (accessor'.edges id);
    in
    if depsMatch && allDepsClean then
      {
        reuse = true;
        value = ctx.store.${id};
      }
    else
      {
        reuse = false;
        value = null;
      };

  earlyCutoff =
    { hashOf }:
    { oldHash, newValue }:
    hashEq (hashGuarded hashOf newValue) oldHash;

  needsEval =
    {
      trace,
      coneSet,
      newHashOf,
      accessor',
    }:
    changedId: id:
    id == changedId
    || (trace.${id}.hash or null) == null
    || builtins.any (d: (coneSet ? ${d}) && hashMoved (newHashOf d) (trace.${d}.hash or null)) (
      accessor'.edges id
    );
}
