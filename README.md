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
- [Demo](#demo)
- [Testing](#testing)
- [Theoretical Foundations](#theoretical-foundations)
- [License](#license)

## Overview

gen-rebuild does **not** schedule or evaluate; it decides reuse and drives change
propagation. v1 functionally composes **gen-graph** (the topology oracle);
**gen-scope** is wired for the v2 warm-cache seam (S1), not used by v1:

```
gen-graph   (topology oracle)   dependentsOf · cycles · transpose
   │  read-only queries over a caller-supplied edge accessor
gen-scope   (scheduler)         demand-driven evaluation  ·  v2 seam (wired, unused in v1)
   │
gen-rebuild (rebuilder)  ◄── THIS LIB
      owns: the flat relocatable result-store + trace, the reuse decision,
            and the change-propagation driver.
```

It owns a flat, **relocatable** result-store (plain values, not thunks closed over
a `lib.fix self`) — relocatability is what makes reuse-across-change possible. A
change recomputes only the dependent **cone** via a reverse-topo splice
(`priorStore // fix-of-cone`); everything else is reused byte-for-byte. v1 runs its
own thin store-backed `lib.fix` eval loop (gen-scope's evaluator is wired in at
v2). It is the **dirty-bit, whole-cone, eager, intra-eval** core — sound and
demonstrable.

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
build :: { accessor, recompute, hashOf } -> BuiltCtx
```

Full evaluation into a flat store + verifying trace. Pre-checks acyclicity via
`graph.cycles` and **throws a catchable located-cycle blame** on a cycle — the
`{ why; cycle; path }` record is constructed from `graph.cycles` and embedded in
the thrown error, so `builtins.tryEval` catches it instead of diverging inside the
`lib.fix` loop. (Surfacing the blame as a *returned, inspectable* value is later.)

- `accessor` — a gen-graph accessor `{ edges, nodes, nodeData, parent }`.
- `recompute :: accessor -> store -> id -> value` — the caller's node-eval.
- `hashOf :: value -> hash` — a content hash; partial on function-bearing values
  (treated as always-dirty, `trace.<id>.hash = null`).

Returns `BuiltCtx = { store, trace, accessor, recompute, hashOf }`.

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

Deduped union of the changed ids and their dependent cones (v1 over-approximation;
the hash-cutoff that prunes unchanged-hash nodes is the v2 `earlyCutoff`).

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
- **Located cycles, not divergence.** A cyclic accessor yields a **catchable
  throw** (the `{ why; cycle; path }` blame embedded in the error), never Nix's
  uncatchable infinite recursion. Surfacing the blame as a returned, inspectable
  value is a later goal.

Deferred: v2 (rebuilder strategies, provenance, drivers, the generic seams), v3
(intra-eval optimality — `O(|AFFECTED|)`, the Adapton sharing/swapping/switching
triple). The impure cross-eval shell is out of scope (a stateful substrate, not a
deferred component).

## Demo

[`examples/dag/`](examples/dag/) — the **B demo**: override one host of a small
synthetic fleet and watch only its dependent cone recompute (proven by a poisoned
recompute), byte-identical to a full rebuild, with a cyclic variant resolving to a
located blame.

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

Uses `gen.lib.mkCi` (nix-unit). 50 tests across 6 suites, including the 120-seed
soundness property and the B demo's thesis assertions.

## Theoretical Foundations

| Paper | Relationship | Used for |
|-------|-------------|----------|
| Mokhov, Mitchell & Peyton Jones (2018) "Build Systems à la Carte" | **Implements** | The rebuilder dimension, factored from the scheduler (gen-scope) and topology oracle (gen-graph); v1 is the dirty-bit rebuilder over a verifying trace |
| Hammer et al. (2014) "Adapton" | Informed by | The pure-core / external-shell *line* — the demand-driven amortization shell is deferred (out of v1 scope), and purity gives read-only-inner-memo soundness for free. v1 is an *eager dirty-bit* rebuilder, not Adapton's demand-driven dirty/clean |
| Arntzenius & Krishnaswami (2016) "Datafun" | Informed by | The dependent cone is gen-graph's reverse reachability (a Datafun-derived query); Datafun's semi-naive incremental fixpoint enters at v2 (`restabilize`) |
| Acar et al. (2002) "Adaptive Functional Programming" | Informed by | Change propagation + the reverse-topo splice; containment recovery for `O(\|AFFECTED\|)` is named as a v3 open problem |
| Reps, Teitelbaum & Demers (1983) | Informed by | `O(\|AFFECTED\|)` optimality + characteristic graphs — the v3 go/no-go gate |
| Radul & Sussman (2009) "Art of the Propagator" | Informed by | Provenance + retraction (v2 `support` / `why` / `retract`) |
| Forgy (1982) "RETE" | Informed by | Delta propagation (v2 change-propagation drivers) |

Full design + milestones: `den-architecture/gen-specs/gen-rebuild/`.

## License

MIT
