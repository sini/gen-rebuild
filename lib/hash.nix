# hash — internal content-hash guarding, shared by build + override.
#
# A function-bearing value is not toJSON-able, and the toJSON error is
# *uncatchable* by builtins.tryEval — so we detect the partiality structurally:
# such values get hash = null and are treated as always-dirty (spec §6 Phase-2b
# decision 1, clause (c)). Hashable values hash as normal.
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
