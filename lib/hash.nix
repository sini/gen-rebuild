# hash — internal content-hash guarding, shared by build + override.
#
# Mokhov 2018 assumes a TOTAL `hash :: Hashable v => v -> Hash v` (§3.1) feeding
# the verifying trace (§4.2.2). Nix `hashOf` is PARTIAL on function-bearing values
# (not toJSON-able; the error is uncatchable by tryEval) — no Hashable instance.
# Modelled structurally: such values get `hash = null` and are conservatively
# always-dirty (never false-clean). The null rule itself has NO paper — it is an
# operational Nix fact, not a theorem.
#
# Not part of the public surface — imported directly, not via lib/default.nix.
{ ... }:
let
  containsFunction =
    v:
    if builtins.isFunction v then
      true
    else if builtins.isList v then
      builtins.any containsFunction v
    else if builtins.isAttrs v then
      builtins.any containsFunction (builtins.attrValues v)
    else
      false;
in
{
  hashGuarded = hashOf: value: if containsFunction value then null else hashOf value;
}
