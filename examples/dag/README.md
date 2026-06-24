# B demo — incremental override + located cycle

A runnable, docs-as-code proof of the gen-rebuild thesis: **sound intra-eval
incremental override** over a flat relocatable store, plus **located cycles**
instead of Nix's uncatchable infinite recursion.

```sh
nix eval -f examples/dag
```

(`--impure` only if your working tree is dirty — see [`default.nix`](default.nix).)

## The synthetic fleet

A five-node abstract value-DAG shaped like a tiny cluster — hosts read a shared
network base and each other's outputs (peer IPs), a gateway aggregates the hosts
(prometheus-target shaped). Edge convention: `edges id = the ids id depends on`.

```
net ──┬── h1 ──┐
      ├── h2   ├── gw      gw depends on h1,h2,h3
      └── h3 ──┘           h3 also depends on peer h1
       (h1,h2,h3 depend on net)
```

`recompute id = own weight + Σ dep values`, so the clean store is
`{ net=10, h1=11, h2=12, h3=24, gw=47 }`.

## What it proves

Overriding host **h1** (`weight := 100`):

1. **Cone-only recompute.** The dependent cone of `h1` is `{h1, h3, gw}` — only
   those recompute; `net` and `h2` are spliced from the prior store untouched.
   This is proven *rigorously and purely* by a **poisoned recompute** that throws
   on the untouched nodes: `override` succeeds (`coneOnlyRecompute = true`) because
   it never calls recompute on them, while a from-scratch build hits the poison
   (`poisonIsReal = true`). The asymmetry is the proof. Running the demo, the
   `recompute <id>` trace markers make the same point visible to the eye.
1. **Soundness.** `override(ctx, h1, …).store` is byte-identical to a full rebuild
   with `h1` changed (`resultEqualsFullRebuild = true`), and the untouched nodes
   are byte-identical to the prior store (`untouchedReused = true`). The override
   store is `{ net=10, h1=110, h2=12, h3=123, gw=245 }`.
1. **Located cycle.** A variant where the network base depends on the gateway
   (`net → gw → h* → net`) yields a *located blame* caught by `tryEval`
   (`cycleIsLocatedBlame = true`) — gen-rebuild runs `graph.cycles` as a
   build-time precheck and throws a `{ why; cycle; path }` record, rather than
   diverging inside the `lib.fix` loop.

## Contrast: the dirty-bit rebuilder vs. an effects paradigm (zen)

gen-rebuild is the **rebuilder** dimension of Mokhov 2018 made explicit: a
topology oracle (gen-graph) + a flat relocatable result-store + a reverse-topo
splice (`priorStore // fix-of-cone`). The reuse decision is a *dirty-bit over a
dependency graph* — "given the last eval, must K be recomputed?" — and reuse is a
store splice you can inspect as plain data.

zen (Vic's stream/effects module system: bend / nix-effects / dnzl) reaches the
*same* incremental behaviour from the other side — **algebraic effects**. Instead of an explicit store + dirty-bit, a host's evaluation is an
effectful computation whose handler scopes and memoizes re-evaluation; "recompute
only what changed" falls out of effect-handler structure (submodule-as-scope)
rather than a graph query. The two are dual lenses on the same incremental core:
gen-rebuild externalizes the dependency graph and result store as values you can
diff; zen internalizes them in the effect/handler control flow.

**TODO (v1 follow-on):** a runnable side-by-side `zen` implementation of this exact
fleet demo, so the paradigm contrast is executable, not just prose.
