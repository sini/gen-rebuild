# override — incremental re-evaluation of a single node's data.
#
# `override ctx changedId newDecls` replaces changedId's nodeData with newDecls,
# recomputes ONLY the dependent cone (changedId + everyone who depends on it),
# and splices the result over the prior store — byte-identical to a from-scratch
# build of the same accessor. Returns an updated BuiltCtx so overrides chain
# soundly (the new trace/hashes are threaded).
#
# SOUNDNESS — scope of the guarantee (read precisely; the property test proves
# exactly this and no more):
#   - It is a *data-change* override. `newDecls` replaces only changedId's
#     nodeData; EDGES ARE FIXED. So the cone computed over the OLD accessor is
#     exactly the affected set in the NEW accessor (only changedId's value moved,
#     not who-depends-on-whom), and acyclicity is preserved — no override-time
#     cycle risk. Soundness here = "data-change override == full rebuild", NOT
#     unconditional soundness.
#   - TOPOLOGY-CHANGING override (changing a node's edges/dep set, e.g. a host's
#     module set) is OUT OF v1 SCOPE — it's the v2 seam (applyDelta / retract with
#     structural deltas). There is no edge-handling code here to be wrong; the
#     property test cannot catch an edge-handling bug because there is none. v1
#     consumers that change topology must rebuild.
#   - Store byte-equality is over *hashable* node values (the toJSON-able values
#     the trace can hash). A node whose stored value carries a function is
#     sound-by-always-dirty for the dirty DECISION (hash = null, see hash.nix),
#     not by store `==` — two function thunks from distinct builds never compare
#     equal. The 120-seed property exercises integer-valued nodes.
#
# The splice:
#   builtStore = ctx.store // lib.fix (s: genAttrs cone (id: recompute accessor' (ctx.store // s) id))
# realizes Acar 2002 change propagation (§4.5 algorithm; §7 correctness — change
# propagation "yields essentially the same result as a complete re-execution on the
# changed inputs"). A cone-internal dep reads its FRESH value from `s` (Acar `l∈C`
# ⇒ re-evaluate); a non-cone dep falls through to `ctx.store` (`l∉C` ⇒ reuse). Bare
# `s` would miss non-cone deps of a recomputed node — unsound. This gives the §7
# property that the override-store is byte-identical to a from-scratch build.
{ lib, graph, ... }:
let
  inherit (import ./hash.nix { }) hashGuarded;
  inherit (import ./dirtySet.nix { inherit lib graph; }) dirtySet;
in
{
  override =
    ctx: changedId: newDecls:
    let
      inherit (ctx) recompute hashOf;

      # accessor' : prior topology with changedId's nodeData replaced. Edges fall
      # through to ctx.accessor (unchanged), so the prior cone stays valid.
      accessor' = ctx.accessor // {
        nodeData = id: if id == changedId then newDecls else ctx.accessor.nodeData id;
      };

      # The set to recompute: changedId + its dependent cone (over the OLD accessor).
      cone = dirtySet ctx [ changedId ];

      # Reverse-topo splice. lib.fix resolves the cone in dependency order;
      # acyclicity (preserved) guarantees termination.
      builtStore =
        ctx.store // lib.fix (s: lib.genAttrs cone (id: recompute accessor' (ctx.store // s) id));

      # Re-hash the recomputed cone; reuse the rest of the trace untouched.
      trace' =
        ctx.trace
        // lib.genAttrs cone (id: {
          deps = accessor'.edges id;
          hash = hashGuarded hashOf builtStore.${id};
        });
    in
    {
      store = builtStore;
      trace = trace';
      accessor = accessor';
      inherit recompute hashOf;
    };
}
