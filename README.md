# gen-rebuild

Pure-Nix incremental **rebuilder** — the rebuilder dimension of Mokhov 2018's
build-systems taxonomy, factored out as a standalone gen library.

> "Given the last evaluation, must key K be recomputed?" gen-rebuild answers that
> and performs the minimal recompute + reuse. It does not schedule (gen-scope) or
> run graph algorithms (gen-graph); it composes both.

## Architecture — three composed layers

- **gen-graph** — topology oracle (`dependentsOf`, `cycles`, `transpose`).
- **gen-scope** — demand-driven scheduler / evaluator.
- **gen-rebuild** (this lib) — owns the flat relocatable result-store + trace,
  the reuse decision, and the change-propagation driver.

## v1 surface

| op | meaning |
| ------------------------- | ------------------------------------------------------------ |
| `build` | full eval → `BuiltCtx { store, trace, … }`; cycle-checked |
| `override` | incremental: recompute only the dependent cone, splice rest |
| `affected` (`impactOf`) | the dependent cone of an id |
| `dirtySet` | deduped union of changed ids and their dependent cones |

v1 is the **dirty-bit, whole-cone, eager, intra-eval** core — sound and
demonstrable. Optimality / laziness / cross-eval amortization are deferred
(see the design spec).

## Edge convention (load-bearing)

`accessor.edges id = [ids that id depends on]` (consumer → producer). Therefore
the **dependent cone** of a change to `x` is `graph.dependentsOf accessor x`
(everyone who transitively depends on `x`).

## Usage

```nix
gen-rebuild = import ./. { inherit lib graph scope; };
```

## Tests

```sh
cd ci && nix flake check
```

## Design

`den-architecture/gen-specs/gen-rebuild/2026-06-23-gen-rebuild-design.md`.
