# gen-rebuild — pure-Nix incremental rebuilder

[![CI](https://github.com/sini/gen-rebuild/actions/workflows/ci.yml/badge.svg)](https://github.com/sini/gen-rebuild/actions/workflows/ci.yml) [![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT) [![Sponsor](https://img.shields.io/badge/Sponsor-%E2%9D%A4-pink?logo=github)](https://github.com/sponsors/sini)

gen-rebuild answers one question — **"given the last evaluation, must key K be
recomputed?"** — and performs the minimal recompute + reuse. It is the *rebuilder*
dimension of [Mokhov 2018](https://www.microsoft.com/en-us/research/publication/build-systems-la-carte/)'s
build-systems taxonomy, factored out of the *scheduler* (gen-scope) and the
*topology oracle* (gen-graph) as a standalone, pure-Nix gen library.

## Table of Contents

- [Overview](#overview)
- [Terminology](#terminology)
- [Gen Ecosystem](#gen-ecosystem)
- [Quick Start](#quick-start)
- [Example](#example)
- [API Reference](#api-reference)
- [Edge Convention](#edge-convention)
- [Scope & Soundness](#scope--soundness)
- [Cut-heavy fast path](#cut-heavy-fast-path)
- [Demo](#demo)
- [Testing](#testing)
- [Theoretical Foundations](#theoretical-foundations)
- [License](#license)

## Overview

gen-rebuild does **not** schedule or evaluate; it decides reuse and drives change
propagation. It functionally composes **gen-graph** (the topology oracle) for every
structural query — including the cyclic convergence-loop: `runScc` ascends each
strongly-connected component to its least fixed point and `restabilize` re-solves a
change's cone stratum-by-stratum over `graph.condensation`, both driven by the
caller-supplied `recompute`. **gen-scope** is the ecosystem's scheduler layer but is
**not currently consumed** by gen-rebuild (the `scope` arg is threaded but unused —
see `lib/default.nix`):

```
gen-graph   (topology oracle)   dependentsOf · cycles · condensation · canReach
   │  read-only queries over a caller-supplied edge accessor
gen-scope   (scheduler)         demand-driven evaluation — NOT consumed (threaded, unused)
   │
gen-rebuild (rebuilder)  ◄── THIS LIB
      owns: the flat relocatable result-store + verifying trace, the reuse
            decision, the change/propagate drivers, the structural deltas,
            and the cyclic re-stabilizer.
```

It owns a flat, **relocatable** result-store (plain values, not thunks closed over
a `lib.fix self`) — relocatability is what makes reuse-across-change possible. A
change recomputes only the dependent **cone** via a reverse-topo splice
(`priorStore // fix-of-cone`); everything else is reused byte-for-byte. The acyclic
core runs its own thin store-backed `lib.fix` eval loop; the cyclic path stratifies
the solve bottom-up over `graph.condensation` and runs a per-SCC fixpoint
(`runScc`). The surface is now the **full v1+v2 rebuilder**: dirty-bit reuse with
per-node early-cutoff, exact AFFECTED, provenance, change/propagate drivers,
structural deltas, and a cyclic re-stabilizer — sound and demonstrable, with each
gap stated honestly.

## Terminology

| Term | Definition | Source |
| ---------- | -------------------------------------------------------------- | ------------------------------------- |
| Rebuilder | decides reuse: "must K be recomputed, given last time?" | Mokhov 2018 |
| Store | flat relocatable id-keyed result map `{ <id> = value; }` | Mokhov 2018 (result store) |
| Trace | per-key `{ deps; hash }` verifying record | Mokhov 2018 (verifying trace) |
| Cone | dependent cone of `x` — everyone who transitively depends on x | gen-graph (reverse reachability) |
| Dirty set | changed ids ∪ their dependent cones (v1 over-approx) | Reps–Teitelbaum–Demers 1983 (AFFECTED set) |
| Splice | `priorStore // fix-of-cone` — recompute the cone, reuse rest | Acar 2002 (change propagation) |
| BuiltCtx | the threaded `{ store, trace, accessor, recompute, hashOf }` | — |
| AFFECTED | the keys whose value *actually* moved — post-filtered, not precomputed | Reps–Teitelbaum–Demers 1983 §4.3 |
| Early-cutoff | reuse a node whose inputs are all unchanged-hash | RTD 1983 (§4.1 value-cutoff, §5.3 NeedToBeEvaluated) |
| Change / Propagate | `applyDelta` (rewrite data) vs `propagate` (drain dirty-set) | Acar 2002 (§4.3 change, §4.5 propagate) |
| Support | the transitive declared *producers* of a node (name-faithful) | Radul 2009 §6.1 |
| Lattice | per-node `{ bottom; join; eq?; widen?; maxIter? }` for a cyclic solve | Arntzenius 2016 (Datafun Lemma 4) |
| SCC / condensation | the cyclic strata, solved producers-first bottom-up | Tarjan 1972 / Kosaraju (via gen-graph) |

## Gen Ecosystem

| Library | Role |
|---------|------|
| [gen-algebra](https://github.com/sini/gen-algebra) | Pure primitives (search, record, identity) |
| [gen-schema](https://github.com/sini/gen-schema) | Typed registries (kinds, instances, collections, refs) |
| [gen-aspects](https://github.com/sini/gen-aspects) | Aspect types (traits, classification, dispatch) |
| [gen-graph](https://github.com/sini/gen-graph) | Graph queries (combinators, traversals, fixpoint) |
| [gen-scope](https://github.com/sini/gen-scope) | Scope graphs (construction, evaluation, resolution) |
| [gen-select](https://github.com/sini/gen-select) | Selector algebra (pattern matching over graph positions) |
| [gen-bind](https://github.com/sini/gen-bind) | Module binding (inject args into NixOS modules) |
| [gen-derive](https://github.com/sini/gen-derive) | Rule dispatch (stratified phases, fixpoint, conflict resolution) |
| [gen-vars](https://github.com/sini/gen-vars) | Variable generation (scope-driven, multi-target) |
| [gen-rebuild](https://github.com/sini/gen-rebuild) | Incremental rebuilder (dirty-bit, dependent-cone reuse) |

## Quick Start

### As a flake input

gen-rebuild's `lib` output comes pre-wired with gen-graph + gen-scope:

```nix
{
  inputs.gen-rebuild.url = "github:sini/gen-rebuild";
  outputs =
    { gen-rebuild, ... }:
    let
      rebuild = gen-rebuild.lib;
    in
    {
      # use rebuild.build, rebuild.override, rebuild.affected, …
    };
}
```

### Without flakes

```nix
let
  lib = (import <nixpkgs> { }).lib;
  graph = import ./path/to/gen-graph { inherit lib; };
  scope = import ./path/to/gen-scope { inherit lib; };
  rebuild = import ./path/to/gen-rebuild { inherit lib graph scope; };
in
rebuild.build {
  accessor = …;
  recompute = …;
  hashOf = …;
}
```

## Example

A node's value is its own weight plus the sum of its dependencies' values. Override
one node, and only its dependent cone recomputes — the rest is reused untouched:

```nix
let
  inherit (rebuild) build override affected;

  # a depends on b depends on c (edges a=["b"], b=["c"], c=[]).
  accessor = graph.mkGraph {
    edges = [
      { from = "a"; to = "b"; }
      { from = "b"; to = "c"; }
    ];
    nodeData = {
      a = { weight = 1; };
      b = { weight = 10; };
      c = { weight = 100; };
    };
  };
  recompute =
    acc: store: id:
    (acc.nodeData id).weight + lib.foldl' (sum: dep: sum + store.${dep}) 0 (acc.edges id);
  hashOf = v: builtins.hashString "sha256" (builtins.toJSON v);

  ctx = build { inherit accessor recompute hashOf; };
  # ctx.store == { a = 111; b = 110; c = 100; }

  ctx' = override ctx "c" { weight = 200; };
  # affected ctx "c" == [ "a" "b" ]            (c's cone, besides c itself)
  # ctx'.store == { a = 211; b = 210; c = 200; } — recomputed {a,b,c}, nothing else
in
ctx'.store
```

## API Reference

### `build`

```
build :: { accessor, recompute, hashOf, fixpoint ? null } -> BuiltCtx
```

Full evaluation into a flat store + verifying trace.

- `accessor` — a gen-graph accessor `{ edges, nodes, nodeData, parent }`.
- `recompute :: accessor -> store -> id -> value` — the caller's node-eval.
- `hashOf :: value -> hash` — a content hash; partial on function-bearing values
  (treated as always-dirty, `trace.<id>.hash = null`).
- `fixpoint ? null` — when `null` (default), `build` is **exactly v1** (see below).
  When present (`{ lattices = { <id> = { bottom; join; … }; }; }`), `build` admits
  cycles whose every node carries a lattice and solves the store
  condensation-stratified — see [Cyclic fixpoints](#cyclic-fixpoints).

In the **v1 (acyclic)** path it pre-checks acyclicity via `graph.cycles` and
**throws a catchable located-cycle blame** on a cycle — the `{ why; cycle; path }`
record is constructed from `graph.cycles` and embedded in the thrown error, so
`builtins.tryEval` catches it instead of diverging inside the `lib.fix` loop.

Returns `BuiltCtx = { store, trace, accessor, recompute, hashOf }` (plus `fixpoint`
when one was supplied).

### `override`

```
override :: BuiltCtx -> changedId -> newDecls -> BuiltCtx
```

Replaces `changedId`'s nodeData with `newDecls`, recomputes **only** the dependent
cone via the reverse-topo splice, and reuses the rest byte-for-byte. Returns an
updated `BuiltCtx`, so overrides chain soundly. v1 changes node *data*, not
topology (edges fixed) — see [Scope & Soundness](#scope--soundness).

### `affected` (alias `impactOf`)

```
affected :: BuiltCtx -> id -> [id]
```

The dependent cone of `id` — everyone who transitively depends on it
(`graph.dependentsOf` over the ctx's accessor). This is the set `override` must
recompute, besides `id` itself.

### `dirtySet`

```
dirtySet :: BuiltCtx -> [changedId] -> [id]
```

Deduped union of the changed ids and their dependent cones (the cheap
over-approximation; the hash-cutoff that prunes unchanged-hash nodes is
`earlyCutoff` / `needsEval`, and the exact subset is `affectedSet`).

### Strategies

The three reuse predicates, all routed through the null-safe hash gate.

```
verify      :: BuiltCtx -> { accessor', spliced } -> id -> { reuse; value }
earlyCutoff :: { hashOf } -> { oldHash, newValue } -> bool
needsEval   :: { trace, coneSet, newHashOf, accessor' } -> changedId -> id -> bool
```

- `verify` — Mokhov §4.2 trace-validity: reuse iff `id`'s recorded deps still match
  and every dep's hash is clean.
- `earlyCutoff` — RTD §4.1 unchanged-value cutoff (*post*-recompute): true iff the
  freshly recomputed value hashes equal to `oldHash`.
- `needsEval` — RTD §5.3 NeedToBeEvaluated (*pre*-cutoff): the single gate
  `override`/`affectedSet`/`propagate` share; recompute iff `id` is the changed id,
  has a null hash, or has an in-cone dep whose hash moved.

### Exact AFFECTED

```
affectedSet :: BuiltCtx -> { accessor', changedIds } -> { affected; hashes; reused }
```

The **exact** AFFECTED set for a multi-id data change (RTD §4.3): splices the
over-approx cone with the `needsEval` gate, then post-filters `affected` to the
nodes whose hash actually moved (`affected ⊆ cone`). `reused` are the unaffected
cone nodes; `hashes` are the new hashes for the whole cone. Data-change envelope
(acyclic, fixed edges).

### Provenance

The pure read layer over the trace — zero recompute. **Name-faithful** to Radul
§6.1 (no TMS, no merge-lattice, no worldviews).

```
support       :: BuiltCtx -> id -> [id]
supportDirect :: BuiltCtx -> id -> [id]
why           :: BuiltCtx -> { id, changedId, cutoffs ? {} } -> WhyResult
whyNot        :: BuiltCtx -> { id, changedId, cutoffs ? {} } -> reason | null
```

- `support` — the transitive declared producers of `id` (the dual of `affected`),
  read from the trace snapshot.
- `supportDirect` — the depth-1 declared producers (immediate in-edges).
- `why` — the verdict an override of `changedId` *would* produce for `id`:
  `unaffected` / `recomputed` / `cutoff` (Acar §7 read-rule, reframed).
- `whyNot` — the negative wrapper: `null` when recomputed, else the reason.

### Drivers

The Acar change/propagate split, batching, pull-semantics force, and the fused
override. Dirtiness is a **value** (`ctx.pending.dirty`), not a mutated flag.

```
applyDelta     :: BuiltCtx -> changedId -> newDecls -> BuiltCtx
batch          :: BuiltCtx -> [{ id, newDecls }] -> BuiltCtx
propagate      :: BuiltCtx -> BuiltCtx
propagateEager :: BuiltCtx -> { <changedId> = newDecls; } -> BuiltCtx
force          :: BuiltCtx -> id -> value
forceCtx       :: BuiltCtx -> id -> { value; ctx }
override       :: BuiltCtx -> changedId -> newDecls -> BuiltCtx
```

- `applyDelta` — Acar §4.3 change: rewrite `changedId`'s data, stage it in
  `pending.dirty`, recompute nothing.
- `batch` — fold `applyDelta` over many deltas (one `propagate` then drains them).
- `propagate` — Acar §4.5 drain-to-quiescence: union-cone splice over all seeds,
  `needsEval`-gated, clearing `pending`.
- `propagateEager` — opt-in **cut-heavy fast path**: a rank-ordered eager-push that
  constructs only `O(|AFFECTED| + frontier)` nodes on localized edits (RTD §4.3/§5
  eager topological push), byte-identical to `propagate`. A constant-factor
  expensive-axis win on cut-heavy edits — **not** a total-work `O(|AFFECTED|)` bound
  (it still pays `O(|cone|)` cheap drive bookkeeping). Use `propagate` for full
  rebuilds; see [Cut-heavy fast path](#cut-heavy-fast-path).
- `force` / `forceCtx` — Hammer/Adapton demand: drain then read the value
  (`forceCtx` also returns the quiescent ctx). **Full-drain**, not Adapton's
  selective per-edge repair (the dropped S6 seam).
- `override` — the fused convenience `propagate ∘ applyDelta`; this is the
  **exported** `override` (it shadows the standalone definition via the `//`-fold),
  byte-identical on `.store`/`.trace` for a data change.

### Structural

Topology-changing deltas (edges move, not just data). Both rebuild a full accessor
record and re-write `trace.deps` for every edge-touched node.

```
mkAccessor    :: { edges, nodes, nodeData, parent } -> accessor
retract       :: BuiltCtx -> deadId -> retractPolicy -> BuiltCtx
applyEdgeDelta :: BuiltCtx -> changedId -> newEdges -> BuiltCtx
```

- `mkAccessor` — rebuild a full accessor record (`edges` deduped via `lib.unique`).
- `retract` — Radul §6.2 `kick-out!` (destructive half): delete `deadId` and splice
  it out of every dependent. `retractPolicy ∈ { "error", "recompute-without" }`
  (default `"error"` throws on declared in-edges). No cycle recheck — deletion only
  shrinks the graph.
- `applyEdgeDelta` — Forgy `modify = delete + add` over a node's edge set: replace
  `changedId`'s edges (deduped), sub-build any newly-reachable producers, then
  reverse-cone splice. A located `reCycleCheck` runs when edges were added.

### Cyclic

Graphs outside the acyclic envelope. **No optimality claim** — fixed-point-equality
to the unique lfp, with a `maxIter` divergence blame.

```
build (fixpoint param) :: { …, fixpoint = { lattices } } -> BuiltCtx
runScc      :: { accessor, store, recompute, scc, higherStrata, lattices } -> { <id> = value }
restabilize :: BuiltCtx -> changedId -> newDecls -> BuiltCtx
```

- `build`'s `fixpoint` param — see [Cyclic fixpoints](#cyclic-fixpoints).
- `runScc` — solve one SCC to its least fixed point by iterating each member's
  lattice from ⊥ to quiescence (Arntzenius Lemma 4 ascent, or Sloane §2.2 naive
  iterate-to-stabilization for an overwrite join).
- `restabilize` — the cyclic-capable `override`: re-solve only the change's cone,
  acyclic strata by recompute-and-splice (== `override`), cyclic strata by
  `runScc`. Requires `ctx.fixpoint != null`.

## Edge Convention

`accessor.edges id = [ids that id depends on]` (consumer → producer).
`graph.mkGraph [{ from; to; }]` makes `edges from = [to]`. Therefore the **dependent
cone** of a change to `x` is `graph.dependentsOf accessor x` — everyone who
transitively depends on `x`.

## Scope & Soundness

A *data-change* override produces a store **byte-identical** to a from-scratch
rebuild with `changedId := newDecls` — property-tested over 120 seeded random DAGs
plus fixed adversarial shapes. The guarantee is precisely scoped:

- **Data, not topology.** `newDecls` replaces only the node's nodeData; edges are
  fixed, so the cone computed over the old accessor is exactly the affected set and
  acyclicity is preserved. **Topology-changing override** (altering a node's dep
  set) is the v2 seam (`applyDelta` / `retract`), out of v1 scope.
- **Hashable values.** Store byte-equality is over toJSON-able node values; a
  function-valued node is sound-by-always-dirty (`hash = null`), not by `==`.
- **Located cycles, not divergence.** With `fixpoint = null` a cyclic accessor
  yields a **catchable throw** (the `{ why; cycle; path }` blame embedded in the
  error), never Nix's uncatchable infinite recursion. `tryEval` does **not** catch
  a `lib.fix` black-hole, so divergence is guarded *structurally* — by the located
  prechecks (`graph.cycles`, `reCycleCheck`) and by `runScc`'s `maxIter`, never by
  catching infinite recursion.

### Cyclic fixpoints

`build`'s `fixpoint` param is the opt-in to cyclic graphs. With `fixpoint = null`
(default) `build` is **exactly v1** — throw-on-any-cycle, `lib.fix` store, no
`fixpoint` key in the ctx. When present, a cycle is admitted iff **every** cyclic
node carries a declared **per-node lattice**:

```nix
ctx = build {
  inherit accessor recompute hashOf;
  fixpoint.lattices = {
    a = { bottom = { }; join = prev: cur: prev // cur; };  # genuine-join semilattice
    b = { bottom = { }; join = prev: cur: prev // cur; eq = (a: b: a == b); widen = null; maxIter = 100; };
  };
};
```

`build` then solves the store **condensation-stratified, producers-first**: each
acyclic singleton recomputes reading already-converged lower strata; each cyclic
SCC is solved once by `runScc` (iterate each member's lattice from ⊥ to
quiescence). `restabilize` re-solves a change's cone the same way.

Three caveats:

- **Fixed-point-equality, not byte-identity.** A cyclic SCC's value matches a
  from-scratch build by *equality of two fixpoint computations to the same unique
  least fixed point* (Arntzenius Lemma 4 on a finite-height bounded semilattice) —
  **not** the v1 byte-identical-to-the-acyclic-`lib.fix` property. The acyclic
  strata retain the v1 byte-identical guarantee.
- **Consumer obligation: monotonicity + finite height.** `runScc` does **not** check
  that `recompute`/`join` are monotone or that the lattice is finite-height. A
  non-monotone step can oscillate; an infinite-ascending chain never quiesces. Use
  `widen` to force finite ascent on tall lattices.
- **The only divergence guard is `maxIter`.** On overrun `runScc` throws a located,
  `tryEval`-catchable `fixpoint-diverged` blame. The cyclic path is explicitly
  **outside RTD's acyclic envelope** — no `O(|AFFECTED|)` optimality, no
  never-assign-a-non-final-value invariant.

Deferred: the cut-heavy expensive-axis fast path SHIPPED as `propagateEager` (opt-in
V-push). True total-work `O(|AFFECTED|)` (RTD characteristic-graph cutoff edges,
containment-pruned propagation, the Adapton selective per-edge repair) is **not** a
pure intra-eval optimization — the v3 minimality spike proved it unreachable in a
single pure eval (verdict PARTIAL). It needs the impure cross-eval substrate (a
stateful shell, not a deferred component) — see
`gen-specs/gen-rebuild/FUTURE_WORK.md`.

### Cut-heavy fast path

`propagateEager` is the opt-in **eager-push** variant of `propagate` for *localized*
edits — e.g. overriding one host in a large fleet. Where `propagate` materializes the
full reverse-reachable cone and post-filters AFFECTED, `propagateEager` recomputes
nodes in producers-first rank order and **cuts at the source**: when a node recomputes
to its prior hash it enqueues nothing, so the unmoved tail past the cut is never
constructed. The result store is byte-identical to `propagate` (the unmoved and
non-cone nodes carry through from the prior store — the §4(B) carry).

The win is precisely scoped, per the [v3 minimality
spike](https://github.com/sini/gen-rebuild) (verdict: **PARTIAL**):

- **It is a constant-factor expensive-axis win on cut-heavy edits, not an
  `O(|AFFECTED|)` total bound.** On the expensive axis (recompute / hash / alloc — the
  ~94% of real cost) it constructs only `O(|AFFECTED| + frontier)` nodes; on cut-heavy
  shapes (`|AFFECTED| ≪ |cone|`) that is ~12–15% of the cone. But it still pays
  `O(|cone|)` cheap drive bookkeeping (the cone-local rank precompute + the rank-ordered
  sweep) **regardless**, so total work is floored at `O(|cone|)`. It does **not** beat
  `O(|cone|)` total, and it does **not** generalize: on full-propagation shapes (every
  cone node moves) it constructs the whole cone and exactly matches `propagate`.
- **When to use:** localized / cut-heavy edits where `|AFFECTED| ≪ |cone|`. **When
  not:** full rebuilds (every cone node moves) — there the eager push gets no win and
  `propagate` is the simpler default.
- **Envelope:** data-change only (edges fixed, like `override`) and an **acyclic** cone
  (the rank recurrence requires it); a cyclic cone stays in `restabilize` / `runScc`.

True sub-cone *total* work (cross-edit amortization of the ordering bookkeeping) is
unreachable in a pure single eval and needs the deferred cross-eval persistence layer —
out of scope here.

## Demo

[`examples/dag/`](examples/dag/) — the **B demo**: override one host of a small
synthetic fleet and watch only its dependent cone recompute (proven by a poisoned
recompute), byte-identical to a full rebuild, with a cyclic variant — an undeclared
cycle resolves to a located blame, while a lattice-declared cycle re-stabilizes via
`runScc`.

```sh
nix eval -f examples/dag
```

It also contrasts the **dirty-bit rebuilder** — gen-rebuild externalizes the graph
and store as inspectable values — with the **effects paradigm** (zen, where
re-evaluation is scoped and memoized by effect handlers): two dual lenses on one
incremental core. A runnable zen side-by-side is a v1 follow-on TODO.

## Testing

```sh
cd ci && nix flake check
```

Uses `gen.lib.mkCi` (nix-unit). 210 tests, including the 120-seed soundness property
(shared by `override`/`propagate`/`propagateEager`), the B demo's thesis assertions,
and the cyclic/structural generators.

## Theoretical Foundations

| Paper | Relationship | Used for |
|-------|-------------|----------|
| Mokhov, Mitchell & Peyton Jones (2018) "Build Systems à la Carte" | **Implements** | The rebuilder dimension, factored from the scheduler (gen-scope) and topology oracle (gen-graph); the dirty-bit rebuilder over the flat store (§3.1) + verifying trace (§4.2.2), `verify` (§4.2), acyclicity precheck (§2.1/§4.1) |
| Reps, Teitelbaum & Demers (1983) | Informed by | The AFFECTED set (§4.3, `affectedSet`/the post-filter), the unchanged-value cutoff (§4.1, `earlyCutoff`), NeedToBeEvaluated (§5.3, `needsEval`); true `O(\|AFFECTED\|)` optimality + characteristic graphs were the v3 go/no-go gate — spike verdict: unreachable in a pure eval, needs the cross-eval substrate (FUTURE_WORK.md) |
| Acar et al. (2002) "Adaptive Functional Programming" | Informed by | The change/propagate split (§4.3 `applyDelta`, §4.5 `propagate`), the reverse-topo splice (§7 correctness), the adg read backward for `support` (§4.4); containment recovery for `O(\|AFFECTED\|)` was the v3 open problem — closed for pure eval by the spike (needs the cross-eval substrate) |
| Forgy (1982) "RETE" | Informed by | The ± change-token vocabulary: `applyDelta`/`batch` are the `+` token, `applyEdgeDelta` is `modify = delete + add` |
| Hammer et al. (2014) "Adapton" | Informed by | The demand/force interface (`force`/`forceCtx`). Note: our force is **full-drain**, not Adapton's selective per-edge repair (the dropped S6 seam, impure / O(N²) in pure Nix) |
| Radul & Sussman (2009) "Art of the Propagator" | Informed by | Provenance (§6.1 support, **name-faithful only** — `support`/`why`/`whyNot`) + retraction (§6.2 `kick-out!`, `retract`'s destructive-delete half); no TMS / merge-lattice / worldviews |
| Arntzenius & Krishnaswami (2016) "Datafun" | Informed by | The dependent cone is gen-graph's reverse reachability (a Datafun-derived query); Lemma 4 (finite-height iterate-from-⊥) grounds `runScc`'s genuine-join lattices |
| Sloane (2010) §2.2 / Magnusson–Hedin "Circular Reference Attributes" | Informed by | The overwrite / no-op "join" case for `runScc`: naive iterate-to-stabilization (converges by peer-agreement, not lattice ascent) |
| Tarjan (1972) / Kosaraju | Informed by | The SCC partition + condensation (via gen-graph, closure-based O(n²)) that stratifies the cyclic `build`/`restabilize` solve producers-first |

Full design + milestones: `den-architecture/gen-specs/gen-rebuild/`.

## License

MIT
