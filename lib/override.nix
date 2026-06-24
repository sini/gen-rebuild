# override — incremental re-evaluation of a single node's data.
#
# `override ctx changedId newDecls` replaces changedId's nodeData with newDecls,
# recomputes ONLY the dependent cone (changedId + everyone who depends on it),
# and splices the result over the prior store — byte-identical to a from-scratch
# build of the same accessor. Returns an updated BuiltCtx so overrides chain
# soundly (the new trace/hashes are threaded).
#
# v1 changes node *data*, not topology: edges are unchanged, so the cone computed
# over the OLD accessor is exactly the affected set, and acyclicity is preserved
# (no override-time cycle risk).
#
# The splice (authoritative form — spec §4's bare-`s` sketch is a bug):
#   builtStore = ctx.store // fix (s: genAttrs cone (id: recompute accessor' (ctx.store // s) id))
# recompute receives `ctx.store // s`: a cone-internal dep reads the fresh value
# from `s`; a reused (non-cone) dep falls through to ctx.store. Passing bare `s`
# would miss non-cone deps of a recomputed node — unsound.
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
