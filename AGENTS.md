# gen-rebuild — agent capability sheet

## Scope

The rebuilder dimension (Mokhov 2018) as a pure-Nix library: owns a flat relocatable result-store plus a per-key verifying trace, decides node reuse, and drives change propagation over a caller-supplied `recompute`. It is **not in the hub roster** — `gen/lib/mkGenLibs.nix` has no `rebuild` entry, so it is consumed directly via `inputs.gen-rebuild.lib`, never through `mkGenLibs`.

**Consumers** (`git grep` over `*flake.nix` across `/home/sini/Documents/repos/sini/gen-*`, this run): `gen-resolve` alone — `flake.nix:13` and `ci/flake.nix:6`, bound as `rebuild = gen-rebuild.lib` (`gen-resolve/flake.nix:31`) and called at `gen-resolve/lib/resolve.nix:37` and `gen-resolve/lib/override.nix:60`, both `rebuild.build`. den-hoag reaches it **transitively only**: `gen-rebuild` appears in `flake.lock`, `ci/flake.lock` and `parity/flake.lock` with `gen-resolve` as the sole node naming it as an input, and in no den-hoag `flake.nix`.

## Not this library's job

Quoted text is the owner's own `flake.nix` `description` field, verbatim.

| Responsibility | Owner |
|---|---|
| Evaluating a node — computing a value from its data and its deps' values | **The caller.** `recompute : accessor -> store -> id -> value` is a required `build` argument; no lib op supplies one |
| Graph traversal, cycle detection, condensation, reachability, rank | `gen-graph` — "gen-graph: accessor-based graph query combinators". Every structural query delegates: `canReach`, `condensation`, `coneRank`, `cycles`, `dependentsOf`, `directDependents`, `pathsBetween`, `reachableFrom`, `selfReachable` are the nine ops called from `lib/` |
| Scheduling / demand-driven evaluation | `gen-scope` — "gen-scope: demand-driven attribute grammar evaluator over algebraic scope graphs". Threaded as the `scope` argument but **unused**, see traps |
| Attribute schedules, HOAG resolution, the convergence loop over a scope graph | `gen-resolve` — "gen-resolve — demand-driven higher-order RAG evaluator over algebraic scope graphs (Knuth 1968 attribute schedule + Vogt 1989 HOAG)". It is gen-rebuild's consumer, not its dependency |
| Constructing the graph, minting ids, registries, kinds | `gen-schema` — "gen-schema: typed record registry with extension points for the pure-gen module system". gen-rebuild only consumes an accessor record `{ nodes; edges; nodeData; parent; }` |
| Choosing among rules whose guards matched | `gen-dispatch` — "gen-dispatch: relational rule dispatch over ordered groups (the dispatch STEP)" |
| Predicates over graph positions | `gen-select` — "gen-select: selector algebra for attributed graph positions" |
| Derivations / the nixpkgs boundary — the store holds plain Nix values, never drv paths | `gen-flake` — "gen-flake — the pure composition boundary of the pure-gen module ecosystem" |
| Module merging | `gen-merge` — "gen-merge — pure-Nix byte-mode module MERGE engine (evalModuleTree) for the pure-gen module system" |
| Type checking / `verify`-as-typecheck (gen-rebuild's `verify` is trace validity, an unrelated sense) | `gen-types` — "gen-types: pure, nixpkgs-lib-free structural type checker for the gen ecosystem" |
| General utilities | `gen-prelude` — "gen-prelude: vendored, nixpkgs-lib-free pure utilities for the gen ecosystem" |

`lib/` imports no nixpkgs-lib: `grep -rn "nixpkgs\|evalModules\|mkOption" lib/` returns nothing (positive control, same instrument and run: `grep -rln "prelude\." lib/` lists ten of the thirteen `lib/` files). The invariant is enforced by the named test `test-library-source-is-nixpkgs-lib-free` (`ci/tests/purity.nix`) over `lib/**.nix` + root `flake.nix` + `default.nix`.

## Exports

Entry: `inputs.gen-rebuild.lib` (flake). Root `default.nix` is `{ prelude, graph, scope }: import ./lib { … }` — a **function of three gen libs**, unlike the zero-dep libs whose `default.nix` is a bare value. `lib` is one flat namespace (24 attrs, no nesting). `lib/default.nix` merges eleven per-concern module files left-to-right with `//`.

**Build and context** — `lib/build.nix`

| Export | Signature |
|---|---|
| `build` | `{ accessor, recompute, hashOf, fixpoint ? null } -> BuiltCtx` |

`BuiltCtx = { store; trace; accessor; recompute; hashOf; }`, plus `fixpoint` **only** when `fixpoint != null`. `store : { <id> = value; }`; `trace : { <id> = { deps; hash; }; }`.

**Data-change rebuild** — `lib/drivers.nix`, `lib/eager.nix`, `lib/restabilize.nix`

| Export | Signature |
|---|---|
| `override` | `ctx -> changedId -> newDecls -> ctx'` — the fused `propagate ∘ applyDelta` (`lib/drivers.nix:190-192`); shadows `lib/override.nix`, see traps |
| `propagateEager` | `ctx -> { <id> = newDecls; } -> ctx'` — rank-ordered eager push; takes an **attrset** of changes, not `id`+`decls` |
| `restabilize` | `ctx -> changedId -> newDecls -> ctx'` — cyclic-capable; requires `ctx.fixpoint` |

**Change / propagate drivers** — `lib/drivers.nix`

| Export | Signature |
|---|---|
| `applyDelta` | `ctx -> changedId -> newDecls -> ctx'` — rewrites nodeData, appends to `pending.dirty`, recomputes nothing |
| `batch` | `ctx -> [{ id; newDecls; }] -> ctx'` — fold of `applyDelta` |
| `propagate` | `ctx -> ctx'` — drain `pending.dirty` to quiescence |
| `force` | `ctx -> id -> value` — drain, then read; the drained ctx is discarded |
| `forceCtx` | `ctx -> id -> { value; ctx; }` — drain, return both |

**Structural (topology) deltas** — `lib/structural.nix`

| Export | Signature |
|---|---|
| `retract` | `ctx -> deadId -> policy -> ctx'`; `policy ∈ { null, "error", "recompute-without" }`, `null` ⇒ `"error"`. Three arguments, none optional |
| `applyEdgeDelta` | `ctx -> changedId -> newEdges -> ctx'` — replaces the node's edge set, sub-builds newly-reachable producers, re-checks for a closed cycle |
| `mkAccessor` | `{ edges, nodes, nodeData, parent } -> accessor` — wraps `edges` in `prelude.unique` |

**Impact queries** — `lib/affected.nix`, `lib/dirtySet.nix`, `lib/affectedSet.nix`

| Export | Signature |
|---|---|
| `affected` / `impactOf` | `ctx -> id -> [id]` — the dependent cone; `impactOf` is the same function |
| `dirtySet` | `ctx -> [id] -> [id]` — changed ids ∪ their cones (over-approximation) |
| `affectedSet` | `ctx -> { accessor', changedIds } -> { affected; hashes; reused; }` — exact AFFECTED by hash post-filter |

**Reuse predicates** — `lib/strategies.nix`

| Export | Signature |
|---|---|
| `verify` | `ctx -> { accessor', spliced } -> id -> { reuse; value; }` — trace validity |
| `earlyCutoff` | `{ hashOf } -> { oldHash, newValue } -> bool` — post-recompute value cutoff |
| `needsEval` | `{ trace, coneSet, newHashOf, accessor' } -> changedId -> id -> bool` — pre-recompute gate |

The attribute name is literally `accessor'`, with the prime.

**Provenance** — `lib/provenance.nix`

| Export | Signature |
|---|---|
| `support` | `ctx -> id -> [id]` — transitive declared producers, sorted, `id` excluded |
| `supportDirect` | `ctx -> id -> [id]` — depth-1 producers |
| `why` | `ctx -> { id, changedId, cutoffs ? {} } -> WhyResult` |
| `whyNot` | `ctx -> { id, changedId, cutoffs ? {} } -> null \| { reason; at?; }` |

`WhyResult = { verdict = "unaffected"; } | { verdict = "recomputed"; paths?; } | { verdict = "cutoff"; cutNodes; paths; }`.

**Cyclic solver** — `lib/restabilize.nix`

| Export | Signature |
|---|---|
| `runScc` | `{ accessor, store, recompute, scc, higherStrata, lattices } -> { <id> = value; }` |

`lattices : { <id> = { bottom; join; eq ? (==); widen ? null; maxIter ? 100; }; }`.

**Accessor contract** (consumed, not exported): `{ nodes : [id]; edges : id -> [id]; nodeData : id -> any; parent : id -> id|null; }`. Edge convention: `edges id = [ids that id depends on]` (consumer → producer), so the dependent cone of `x` is `graph.dependentsOf accessor x`.

**Not exported**: `lib/hash.nix` (`hashGuarded`, `hashEq`, `hashMoved`) — see traps.

## Entry points by task

| Task | Reach for |
|---|---|
| Build a store from scratch | `build { accessor; recompute; hashOf; }` |
| Build a graph that contains cycles | `build { …; fixpoint = { lattices = { … }; }; }` |
| Change one node's data and rebuild | `override ctx id newDecls` |
| Change several nodes in one drain | `batch ctx [ … ]` then `propagate` |
| Change data on a localized (cut-heavy) edit | `propagateEager ctx { id = newDecls; }` |
| Change data on a graph with cycles | `restabilize ctx id newDecls` (needs a fixpoint-built ctx) |
| Stage a change without recomputing | `applyDelta`, then `propagate` / `force` when the value is wanted |
| Read one value, draining if stale | `force ctx id`; `forceCtx` when the drained ctx is reused |
| Delete a node | `retract ctx deadId "recompute-without"` (or `null` to refuse when dependents remain) |
| Repoint a node's dependencies | `applyEdgeDelta ctx id newEdges` |
| Ask who a change would touch | `affected ctx id` (cone) / `dirtySet ctx ids` (multi-id cone) |
| Ask whose value actually moved | `affectedSet ctx { accessor'; changedIds; }` — `.affected`, not `dirtySet` |
| Ask what justifies a value | `support` / `supportDirect` |
| Ask why a node was (not) recomputed | `why` / `whyNot` |
| Solve one SCC directly | `runScc` |

## Measured traps

Every row verified in this run at rev `25ca134` (a historical fact, not a pin) by evaluating against `(builtins.getFlake "…/gen-rebuild").lib`. Shared fixture: a chain `a → b → c` (`edges a = ["b"]`, `edges b = ["c"]`, `edges c = []`), `nodeData = { a = 1; b = 2; c = 3; }`, `recompute` = own data plus the sum of its deps' stored values, `hashOf = builtins.toJSON`. That gives `ctx.store = {"a":6,"b":5,"c":3}`. `cycAcc` = a two-node cycle `p ⇄ q`. `te e = (builtins.tryEval e).success`.

| Trap | Evidence |
|---|---|
| The public `override` is **not** `lib/override.nix`'s. `lib/default.nix:20-32` folds `drivers.nix` after `override.nix`, so `drivers.override` (the fused `propagate ∘ applyDelta`) shadows it; the `override.nix` definition is unreachable through `lib` | `lib/default.nix:17-19` states the ordering intent. `(override ctx "c" 30) ? pending` ⇒ `true` with `pending = {"dirty":[]}` — a key only `propagate` adds. Positive controls, same run: `(build …) ? pending` ⇒ `false`, `(applyDelta ctx "c" 30) ? pending` ⇒ `true`. Tests: `test-override-is-fused`, `test-override-fused-quiescent` (`ci/tests/override.nix`) |
| The hash helpers are **private**. `lib/hash.nix` is the one lib file `lib/default.nix` does not fold in, so `hashGuarded`/`hashEq`/`hashMoved` are unreachable from `lib` | `lib/hash.nix:10` says so; `grep -n "hash.nix" lib/default.nix` returns nothing while `grep -rln "hash.nix" lib/` lists eight other files that import it directly. `lib ? hashGuarded`, `? hashEq`, `? hashMoved` ⇒ all `false`; positive control `lib ? build` ⇒ `true` |
| `tryEval` does **not** catch `toJSON` on a function — the error escapes and kills the whole evaluation | `nix eval --expr '(builtins.tryEval (builtins.toJSON (x: x))).success'` ⇒ exit 1, `error: cannot convert a function to JSON`. Positive control, same instrument: `nix eval --expr '(builtins.tryEval (throw "boom")).success'` ⇒ exit 0, prints `false`. This is why `hashGuarded` screens for functions *before* calling `hashOf` (`lib/hash.nix:13-25`) |
| `tryEval` does **not** catch a `fix` black-hole either, so divergence is guarded structurally (prechecks + `maxIter`), never by catching | `(builtins.tryEval (let f = x: x; s = f s; in s)).success` ⇒ exit 1, `error: infinite recursion encountered`; the `genAttrs`-mediated shape `prelude.fix (self: { a = self.a; })` ⇒ exit 1 likewise. Same `throw` control as above ⇒ exit 0 |
| A function-valued node does **not** throw: it gets `hash = null` and is conservatively always-dirty | `build` over the chain with `nodeData c = (x: x)` ⇒ `trace.c.hash` is `null` and the build succeeds. Positive control, plain fixture: `ctx.trace.c.hash` ⇒ `"3"`. Tests: `test-trace-hash-null-on-function`, `test-trace-hash-null-on-nested-function` (`ci/tests/build.nix`) |
| With the default `fixpoint = null`, any cycle is a **catchable** throw, not divergence | `te (build { accessor = cycAcc; … }).store` ⇒ `false`; positive control `te ctx.store` ⇒ `true`. Test: `test-cycle-throws-catchable` (`ci/tests/build.nix`) |
| Passing `fixpoint` does not by itself license a cycle — every cyclic node needs a declared lattice | `te (build { accessor = cycAcc; fixpoint = { lattices = {}; }; …}).store` ⇒ `false`. Test: `test-fixpoint-undeclared-cyclic-throws` (`ci/tests/build.nix`) |
| A `fixpoint = null` ctx carries **no** `fixpoint` key, so downstream cyclic ops cannot detect capability by field presence alone | `ctx ? fixpoint` ⇒ `false`; positive control, same run, a ctx built with declared lattices over `cycAcc` ⇒ `true`. Test: `test-fixpoint-absent-is-v1-store` (`ci/tests/build.nix`) |
| `restabilize` on a ctx built without `fixpoint` throws | `te (restabilize ctx "c" 30).store` ⇒ `false`; positive control `te (override ctx "c" 30).store` ⇒ `true`. Test: `test-restab-requires-fixpoint-throws` (`ci/tests/restabilize.nix`) |
| `retract`'s third argument is **required** — a two-argument call silently yields a function, not a ctx | `builtins.isFunction (retract ctx "c")` ⇒ `true` |
| `retract` with the default `"error"` policy throws when the node has declared in-edges; deleting a leaf-of-the-cone needs the explicit `"recompute-without"` | `te (retract ctx "c" null).store` ⇒ `false` (b depends on c); `te (retract ctx "c" "recompute-without").store` ⇒ `true`. Positive control, a node with no in-edges: `te (retract ctx "a" null).store` ⇒ `true`. Tests: `test-retract-error-blames-in-edges`, `test-retract-error-root-ok` (`ci/tests/structural.nix`) |
| `dirtySet` is the over-approximate cone and never consults hashes; a change that moves no value still lists the whole cone, while `affectedSet.affected` is empty | `dirtySet ctx ["c"]` ⇒ `["c","a","b"]`. On a no-op change over the same fixture, `affectedSet ctx { accessor' = accessor; changedIds = ["c"]; }` ⇒ `{"affected":[],"hashes":{"a":"6","b":"5","c":"3"},"reused":["c","a","b"]}`. Test: `test-affected-empty-on-collision` (`ci/tests/affectedSet.nix`) |
| `why`'s fast path returns **no** `paths` key at all; `paths` appears only under a non-empty `cutoffs` overlay | `why ctx { id = "a"; changedId = "c"; }` ⇒ `{"verdict":"recomputed"}` and `? paths` ⇒ `false`; positive control with `cutoffs = { b = true; }` ⇒ `? paths` ⇒ `true`. Tests: `test-why-fastpath-no-paths`, `test-why-cutoff-has-paths` (`ci/tests/provenance.nix`) |
| `whyNot` returns `null` for the recomputed case — the absence of a reason, not a record | `whyNot ctx { id = "a"; changedId = "c"; }` ⇒ `null`; positive control `whyNot ctx { id = "c"; changedId = "a"; }` ⇒ `{"reason":"unaffected"}`. Tests: `test-whyNot-recomputed-null`, `test-whyNot-unaffected-reason` (`ci/tests/provenance.nix`) |
| `applyDelta`/`batch` leave `store` and `trace` **stale** — the change is a value in `pending.dirty`, not a recomputation | `(batch ctx [{id="c";newDecls=30;} {id="b";newDecls=20;}]).store` ⇒ `{"a":6,"b":5,"c":3}` (unchanged) with `pending.dirty` ⇒ `["c","b"]`; after `propagate` ⇒ `{"a":51,"b":50,"c":30}`. Tests: `test-applyDelta-store-stale`, `test-batch-store-stale` (`ci/tests/drivers.nix`) |
| `propagate` on a ctx that has no `pending` is a no-op that still **adds** `pending = { dirty = []; }` | `builtins.attrNames (propagate ctx)` ⇒ `["accessor","hashOf","pending","recompute","store","trace"]`, store unchanged at `{"a":6,"b":5,"c":3}`. Test: `test-propagate-quiescent-noop` (`ci/tests/drivers.nix`) |
| `propagateEager` returns a ctx **without** `pending`, unlike `override`/`propagate` — the two families' ctx shapes differ | `(propagateEager ctx { c = 30; }) ? pending` ⇒ `false`; positive control `(override ctx "c" 30) ? pending` ⇒ `true`. Its store agrees: `{"a":33,"b":32,"c":30}`, identical to `override ctx "c" 30`. Tests: `test-returns-store` … `test-returns-trace` (`ci/tests/eager.nix`) enumerate the returned keys |
| `applyEdgeDelta` and `mkAccessor` dedupe the edge list; without it the recompute fold double-counts | `(applyEdgeDelta ctx "a" ["b" "b"]).store.a` ⇒ `6`, equal to the single-edge control `["b"]` ⇒ `6`. Positive control that the dedup is load-bearing: the same `recompute` run directly on a non-deduped `edges = _: ["b" "b"]` ⇒ `11`. `mkAccessor { edges = _: ["b" "b" "c"]; … }` ⇒ `edges "a"` ⇒ `["b","c"]`. Test: `test-edge-dedup-a` (`ci/tests/structural.nix`) |
| `applyEdgeDelta` that closes a cycle throws a located, catchable blame rather than diverging | `te (applyEdgeDelta ctx "c" ["a"]).store` ⇒ `false`; positive control, a non-cycle-closing repoint `te (applyEdgeDelta ctx "a" ["c"]).store` ⇒ `true`. Test: `test-cycle-recheck-caught` (`ci/tests/structural.nix`) |
| `earlyCutoff` never cuts when the old hash is `null` (unhashable ⇒ always dirty) | `earlyCutoff { inherit hashOf; } { oldHash = null; newValue = 3; }` ⇒ `false`; positive controls `{ oldHash = "3"; newValue = 3; }` ⇒ `true`, `{ oldHash = "3"; newValue = 4; }` ⇒ `false`. Test: `test-earlyCutoff-null-oldhash` (`ci/tests/strategies.nix`) |
| The `scope` (gen-scope) argument is **required but never consumed** — a caller must still pass it | `grep -rn "scope" lib/` outside comments matches only `lib/default.nix:12` (the parameter) and `:15` (the args passthrough); positive control, same run: `grep -rno "graph\.[a-zA-Z]*" lib/` yields nine distinct call sites. `lib/default.nix:7-11` states the sketched warm-cache adapter was found unsound and never wired |
| `affected` and `impactOf` are the same function, not two behaviours | `affected ctx "c"` ⇒ `["a","b"]`, `impactOf ctx "c"` ⇒ `["a","b"]`, `affected ctx "c" == impactOf ctx "c"` ⇒ `true`. Test: `test-impactOf-alias` (`ci/tests/affected.nix`) |
| `force` discards the drained ctx; a loop over `force` re-drains each time. `forceCtx` returns `{ ctx; value; }` | both yield `33` on a pending ctx; `builtins.attrNames (forceCtx …)` ⇒ `["ctx","value"]`. Tests: `test-force-pending-drains`, `test-forceCtx-returns-quiescent` (`ci/tests/drivers.nix`) |

Read, not exercised in this run: `runScc`'s `widen` hook and its `maxIter` divergence blame (`lib/restabilize.nix:76,93-94`); the `"cutoff"` verdict's multi-witness `cutNodes` path (`lib/provenance.nix:96-101`). Both carry named tests — `test-diverge-catchable` (`ci/tests/restabilize.nix`), `test-why-cutoff-cutnodes-set` (`ci/tests/provenance.nix`).

## Theory

`README.md:493-505` splits its sources with a **Relationship** column reading either *Implements* or *Informed by*; restated in per-file code comments.

**Implements**

- **Mokhov, Mitchell & Peyton Jones (2018), *Build Systems à la Carte*** — the rebuilder dimension factored from the scheduler and the topology oracle: the flat relocatable store (§3.1), the verifying trace (§4.2.2), `verify` (§4.2), the acyclicity precheck (§2.1/§4.1). `lib/build.nix:1-6`. The `hash = null` rule for unhashable values is stated in `lib/hash.nix:3-8` as an operational Nix fact with **no** paper behind it — Mokhov assumes a total `hash`.

**Informed by** (README's own label)

- **Reps, Teitelbaum & Demers (1983)** — AFFECTED (§4.3, `affectedSet` and the post-filter), the unchanged-value cutoff (§4.1, `earlyCutoff`), NeedToBeEvaluated (§5.3, `needsEval`). True `O(|AFFECTED|)` optimality and characteristic graphs are recorded as **not reached** in pure evaluation.
- **Acar et al. (2002), *Adaptive Functional Programming*** — the change/propagate split (§4.3, §4.5), the reverse-topo splice (§7 correctness), the adg read backward for `support` (§4.4).
- **Forgy (1982), *RETE*** — change-token vocabulary only: `applyDelta`/`batch` as `+`, `applyEdgeDelta` as `modify = delete + add`.
- **Hammer et al. (2014), *Adapton*** — the demand/force interface. `force` is explicitly full-drain, **not** Adapton's selective per-edge repair (`lib/drivers.nix:14-16`, gap G1).
- **Radul & Sussman (2009), *Art of the Propagator*** — provenance (§6.1 support) and retraction (§6.2 `kick-out!`), both marked **name-faithful only**: no TMS, no merge-lattice, no worldviews (`lib/provenance.nix:10-13`, `lib/structural.nix:13-15`).
- **Arntzenius & Krishnaswami (2016), *Datafun*** — the dependent cone as reverse reachability; Lemma 4 (finite-height iterate-from-⊥) grounds `runScc`.
- **Sloane (2010) §2.2 / Magnusson–Hedin, *Circular Reference Attributes*** — the overwrite/no-op "join" case for `runScc`, converging by peer-agreement rather than lattice ascent.
- **Tarjan (1972) / Kosaraju** — SCC partition and condensation, via gen-graph.

**Stated gaps** (in code, load-bearing): the `fixpoint` path sits outside Mokhov's and RTD's acyclic envelope, and per-SCC convergence rests on the consumer's **unchecked** monotonicity and finite-height obligations — the only runtime guard is `runScc`'s per-member `maxIter` (`lib/build.nix:35-38`, `lib/restabilize.nix:21-32`). `override` is sound for **data changes with fixed edges** only; topology changes route to `lib/structural.nix` (`lib/override.nix:9-26`).

## Drift check

`lib` is one flat namespace, so a single `attrNames` covers it — no nested-namespace clause is needed.

```sh
nix eval --json .#lib --apply 'builtins.attrNames'
```

Current output (verbatim):

```json
["affected","affectedSet","applyDelta","applyEdgeDelta","batch","build","dirtySet","earlyCutoff","force","forceCtx","impactOf","mkAccessor","needsEval","override","propagate","propagateEager","restabilize","retract","runScc","support","supportDirect","verify","why","whyNot"]
```

**Checks.** Test-runner invocation (from the repo root; CI runs the same command with `working-directory: ci`, `.github/workflows/ci.yml:13,18`):

```sh
nix flake check ./ci
```
