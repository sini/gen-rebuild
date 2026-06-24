# Rebuilder strategies — three reuse predicates routed through the §3.5 hash gate.
# verify: Mokhov 2018 §4.2 verifying-trace (trace-VALIDITY). earlyCutoff: RTD 1983
# §4.1 unchanged-value cutoff (POST-recompute). needsEval: RTD 1983 §5.3
# NeedToBeEvaluated (PRE-cutoff) — DISTINCT from verify (RTD §5.3 is "complementary
# to / distinct from" the value compare); they COINCIDE only in the single-changed-
# input acyclic data-change envelope, NOT a definitional identity.
{ lib, ... }:
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
