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
# The splice (P2 rewrite — needsEval-gated, per-node-EXACT recompute):
#   builtStore = ctx.store // lib.fix (s:
#     genAttrs cone (id:
#       if needsEval … then recompute accessor' (ctx.store // s) id else ctx.store.${id}))
# realizes Acar 2002 change propagation (§4.5 algorithm; §7 correctness — change
# propagation "yields essentially the same result as a complete re-execution on the
# changed inputs"). A cone-internal dep that needsEval reads its FRESH value from `s`
# (Acar `l∈C` ⇒ re-evaluate); a non-cone dep falls through to `ctx.store` (`l∉C` ⇒
# reuse), as does a cone node with NO moved-hash dep (RTD 1983 §5.3 NeedToBeEvaluated
# PRE-cutoff — the per-node early-cutoff that v1's whole-cone recompute lacked). The
# authoritative `ctx.store // s` form is KEPT: bare `s` would miss non-cone deps of a
# recomputed node — unsound. This gives the §7 property that the override-store is
# byte-identical to a from-scratch build, AND skips recompute for reused cone nodes.
{ lib, graph, ... }:
let
  inherit (import ./hash.nix { }) hashGuarded hashMoved;
  inherit (import ./strategies.nix { inherit lib; }) needsEval;
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

      # Over-approx cone: changedId + its dependent cone (over the changed accessor;
      # edges are fixed, so this equals the cone over the old accessor). genAttrs
      # gives O(1) membership for the needsEval gate (never builtins.elem).
      cone = lib.unique ([ changedId ] ++ graph.dependentsOf accessor' changedId);
      coneSet = lib.genAttrs cone (_: true);
      newHashOf = id: hashGuarded hashOf builtStore.${id};

      # Reverse-topo splice. lib.fix resolves the cone in dependency order;
      # acyclicity (preserved) + fixed edges guarantee termination. Each cone node
      # is gated on needsEval: a node with a moved-hash in-cone dep (or that is
      # changedId, or whose hash is null) is recomputed; otherwise its prior value
      # is reused (still bound in builtStore so dependents read it identically).
      builtStore =
        ctx.store
        // lib.fix (
          s:
          lib.genAttrs cone (
            id:
            let
              spliced = ctx.store // s;
              # mustEval IS strategies.needsEval (RTD 1983 §5.3 NeedToBeEvaluated) —
              # the single source of the predicate, never an inlined parallel expression.
              mustEval = needsEval {
                inherit (ctx) trace;
                inherit coneSet newHashOf accessor';
              } changedId id;
            in
            if mustEval then recompute accessor' spliced id else ctx.store.${id}
          )
        );

      # AFFECTED = post-filtered from hashes (RTD 1983 §4.3 — the keys whose value
      # ACTUALLY moved, never precomputed). hashMoved is null-safe: a function-bearing
      # cone node (hash = null) is always affected, never false-clean.
      affected = builtins.filter (id: hashMoved (newHashOf id) (ctx.trace.${id}.hash or null)) cone;

      # Re-hash ONLY the genuinely affected nodes; a reused (cone-but-unaffected)
      # node keeps its prior trace entry byte-identical.
      trace' =
        ctx.trace
        // lib.genAttrs affected (id: {
          deps = accessor'.edges id;
          hash = newHashOf id;
        });
    in
    {
      store = builtStore;
      trace = trace';
      accessor = accessor';
      inherit recompute hashOf;
    };
}
