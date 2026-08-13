# The pairing for the amortized provenance dual: the same verdict loop, asked per call and
# asked through a cone bound once.
#
# ★★★ WHAT THIS FILE IS FOR, AND WHAT IT IS NOT FOR. The dual exists so that the batch
# question has a batch answer: a caller asking the verdict of many ids can pay for
# membership ONCE per change instead of once per id, and no caller has to build a batch
# answer out of point queries. It was not built because a caller was measured paying for
# one — there is no production caller of `why` in this library or any other, and the only
# loop over it anywhere is the soundness suite's own, over graphs of four to seven nodes.
#
# ★★ IT DOES NOT MAKE THE PER-ID SHAPE UNCONSTRUCTIBLE, AND NOTHING HERE CLAIMS IT DOES.
# `why` and `whyNot` are retained deliberately and still answer per call, so looping them
# is still exactly the closure-per-id shape — this file's own `shipped` arm IS that loop,
# and the soundness suite runs it 660 times. The amortization is a decision the CALLER
# makes, which is to say a decision the caller can make WRONGLY: applying the dual inline
# per id rebuilds the cone per id, and the `coneInline` arm below prices that and is the
# worst column in the table. What the API offers is the form that pays once; what it
# cannot do is stop a caller reaching for the other one.
#
# **NO COST CLAIM IS MADE FROM THESE FIGURES, IN EITHER DIRECTION.** They are a
# disclosure — what the construction costs at the one regime that exercises it — and a
# cell showing the cone arm WORSE here is a reading, not a defect.
#
# THE PAIRING IS THE INSTRUMENT, and both columns live in ONE revision of this file so the
# comparison is between two constructions rather than between two runs:
#   · `shipped`    issues one point query per id — the shape the suite runs today.
#   · `cone`       binds one cone per change and spends it over that change's whole id set.
#   · `coneInline` the same dual, applied inline per id — the caller's decision taken
#                  wrongly, priced rather than merely warned about.
#   · `floor`      builds the same fixture and forces the same id sets, issuing NO verdict,
#                  so a reader can see how much of any column is the fixture.
# Neither verdict column means anything alone: `shipped` is a number with nothing to
# compare against, and `cone` prices a construction whose whole point is a comparison.
#
# ══ THE CELL, AS MEASURED. 120 cases, 660 ids, 4-7 nodes each, mean out-degree 1.181 ══
#
# ALLOCATION — one run of `why-cone.sh alloc`, all three axes, every arm:
#
#   arm           answer           list         sets      nrLookups
#   floor            660           6895        14308           6732
#   shipped          213          16938        23902          20979
#   cone             213          26290        31916          19124
#   coneInline       213          52584        52211          39921
#
#   Net of the fixture floor: shipped 10043 / 9594 / 14247 · cone 19395 / 17608 / 12392 ·
#   coneInline 45689 / 37903 / 33189.
#   ★★ THE THREE AXES DISAGREE ON THE DIRECTION FOR `cone`, and that is the reading rather
#   than a defect in it: it allocates 1.93x the list elements and 1.84x the set elements,
#   and performs 0.87x the lookups. At this regime the reverse index is built over the
#   whole node set once per change while the forward walk stops at the target on a graph of
#   at most seven nodes. There is no dominant term, so a single-axis reading would
#   manufacture a confident answer the measurement does not contain.
#   ★★★ THEY DO NOT DISAGREE ABOUT `coneInline`: 4.55x / 3.95x / 2.33x the shipped loop's
#   net on all three. The wrong caller decision is not merely unimproved, it is worse than
#   the per-id shape it was reached for instead of — each id pays a Θ(n + E) index build
#   where the point query walked forward and stopped. This is what "the amortization is the
#   caller's decision" costs when the decision goes the other way, and it is the reason
#   this file claims an OFFER rather than a guarantee.
#
# WALL CLOCK — the five-arm protocol, six arms interleaved, 8 rounds, ms:
#
#   arm        readings                            min   second     gap    net
#   FLOOR      28 27 27 27 27 27 28 27              27       27    0.0%     27
#   NULL       87 88 87 87 88 87 89 86              86       87    1.1%     59
#   SHIPPED    84 84 83 85 84 88 86 84              83       84    1.2%     56
#   ARM        85 86 86 85 88 90 89 87              85       85    0.0%     58
#   Q1         56 53 59 56 55 56 53 55              53       53    0.0%     26
#   CONTROL4X  137 138 138 138 139 138 139 138     137      138    0.7%    110
#
#   P4 NULL-parity PASS (59 vs 56 net, 5.3% apart) · P5 PASS on all six arms against a
#   bound of 12% · CONTROL-4x 4.23x (sensitivity only; it passes in either machine mode
#   and certifies nothing). RUN ADMISSIBLE — and neither certificate suffices alone.
#   The bound is CALIBRATED ON THIS HOST, not assumed: a 32-round idle run, the gap over
#   every six-round window of every arm, clean maximum 8.3%, reproduced on three separate
#   runs. The same statistic read 93-120% on runs that straddled a mode transition, which
#   is P5 firing,
#   and the reason a run is certified rather than read.
#   SHIPPED net 56 ms · ARM net 58 ms · delta 3.5% of the smaller net.
#   RESOLUTION FLOOR = bound 12% x the arm's own min/net 1.48 = 17.7%.
#   ⇒ VERDICT: NOT RESOLVED BY THIS INSTRUMENT. Not "no difference", and not a win.
#
# ★★ THE COUNTERS ARE A LOWER BOUND. `list.elements` / `sets.elements` / `nrLookups` count
# Nix-heap allocation only; `genericClosure` keeps its done-set and its key comparisons in
# C++, where none of the three axes can see them. Every figure here is a floor on the real
# cost, admissible as measured and inadmissible as a wall-clock prediction — the two axes
# have disagreed on which term is bigger before, and an allocation delta has bought a wall
# result of the opposite sign.
#
# ★ THE CONTEXT IS MINIMAL, AND THAT IS THE MEASUREMENT'S REASON RATHER THAN A SHORTCUT.
# Both routes read exactly `ctx.accessor` on the fast path — `why` through `canReach`, the
# dual through `dirtySet` — so the ctx carries an accessor and nothing else. A real built
# context would put a whole store fixpoint under both arms, and a preamble that costs more
# than the arm is the reading. The overlay path, which does read the trace, is NOT priced
# here: it falls through to the same per-id machinery in both routes, and no claim is made
# about it.
#
# ★ THE LIBRARY AND ITS SUBSTRATE COME FROM THE LOCK, NOT FROM A SIBLING CLONE. The suite
# evaluates the pinned `gen-graph`, which is not the tip; a bench that read a working clone
# would price a construction this consumer does not contain.
#
# INTERFACE — `arm`:
#   floor        the fixture, no verdicts
#   shipped      one `why` per id
#   shippedNull  byte-identical to `shipped`, under a second name (the wall-clock parity arm)
#   cone         one `whyFor` per change, spent over its ids
#   coneInline   the dual applied inline per id — the wrong caller decision, priced
#   q1 / q4      an instrument pair whose work differs by exactly 4x, by construction
#   seeds        how many fixture cases (default 120, the suite's own corpus)
#
# Every arm returns `{ answer = <int>; }`, and the answer is a control rather than a
# convenience: `shipped` and `cone` answer the same question, so a cost figure whose cell
# answered differently from its pair is not a cheaper reading of the same question.
{
  arm ? "cone",
  seeds ? 120,
}:
let
  # ★ EVERY INPUT RESOLVES THROUGH `root.inputs`, NEVER BY BARE NODE NAME. A lock's node
  # keys are not its input names: where two inputs want the same flake, the bare name and
  # the suffixed one are DIFFERENT NODES, and which of them root binds is the lock writer's
  # business rather than something a reader may assume. Two nodes are free to pin different
  # revisions, and where they do a bare-name read returns the wrong one SILENTLY — with an
  # entirely plausible hash and no error anywhere. Whether they happen to agree in any given
  # lock today is not the ground and is not asserted here: the node identity is, one bump
  # either way moves the revisions sitting behind it, and nothing in this file re-checks them.
  ci = builtins.getFlake "path:${toString ../.}";
  inherit (ci.inputs)
    gen-prelude
    gen-graph
    gen-scope
    nixpkgs
    ;

  prelude = import "${gen-prelude}/lib";
  graph = gen-graph.lib;
  scope = gen-scope.lib;
  lib = import "${nixpkgs}/lib";
  genRebuild = import ../../lib { inherit prelude graph scope; };
  inherit (genRebuild) why whyFor;

  # The suite's own fixture, imported rather than transcribed: a re-spelled generator is a
  # different corpus wearing the same name.
  mkCase = (import ../tests/gen.nix { inherit lib graph; })._module.args.mkCase;

  cases = map (
    seed:
    let
      c = mkCase seed;
    in
    {
      inherit c;
      ctx = {
        accessor = c.acc;
      };
    }
  ) (lib.range 1 seeds);

  # Non-unaffected verdicts across the whole corpus. Forcing it forces every cell.
  countRecomputed =
    verdictOf:
    builtins.foldl' (
      total: k:
      total + builtins.length (builtins.filter (v: v != "unaffected") (map (verdictOf k) k.c.ids))
    ) 0 cases;

  # ── THE SHIPPED SHAPE: one point query per id ──
  shipped = countRecomputed (
    k: id:
    (why k.ctx {
      inherit id;
      inherit (k.c) changedId;
    }).verdict
  );

  # ── THE DUAL: one cone per change, spent over that change's ids ──
  # The binding is OUTSIDE the id map, which is the whole construction: move it inside and
  # this arm is the shipped arm with a reverse index in place of a forward walk.
  cone = countRecomputed (
    k:
    let
      verdictFor = whyFor k.ctx { inherit (k.c) changedId; };
    in
    id: (verdictFor id).verdict
  );

  # ── THE SAME DUAL, APPLIED INLINE: the caller's decision, taken WRONGLY ──
  # `whyFor ctx { changedId }` binds the cone inside its own body, so a caller who writes
  # the whole application inside the per-id map rebuilds it once per id. This arm exists
  # because the amortization is the CALLER's decision and a decision can be made wrongly;
  # a file that says so and does not price it is asking to be taken on trust.
  coneInline = countRecomputed (k: id: (whyFor k.ctx { inherit (k.c) changedId; } id).verdict);

  # ── THE FIXTURE ALONE: the id sets forced, no verdict issued, no edge read ──
  floor = builtins.length (lib.concatMap (k: k.c.ids) cases);

  # The instrument pair. Four times the list, nothing else different.
  countTo = m: builtins.foldl' (a: _: a + 1) 0 (builtins.genList (i: i) m);
in
{
  answer =
    if arm == "shipped" then
      shipped
    else if arm == "shippedNull" then
      shipped
    else if arm == "cone" then
      cone
    else if arm == "coneInline" then
      coneInline
    else if arm == "floor" then
      floor
    else if arm == "q1" then
      countTo 200000
    else if arm == "q4" then
      countTo 800000
    else
      throw "why-cone.nix: unknown arm '${arm}' (floor|shipped|shippedNull|cone|coneInline|q1|q4)";
}
