#!/usr/bin/env bash
# Reads the `why-cone.nix` pairing: the allocation axes, and the wall clock under the
# standing five-arm protocol.
#
#   ./ci/bench/why-cone.sh alloc                   -> arm answer list sets nrLookups
#   ./ci/bench/why-cone.sh calibrate [rounds]      -> per-arm window gap maximum, beside the
#                                                     rows it is read from
#   ./ci/bench/why-cone.sh wall <bound%> [rounds]  -> per-arm readings, then ADMISSIBLE | VOID
#
# ★ THE WALL BOUND IS REQUIRED AND HAS NO DEFAULT, and that is P5's rule rather than a
# usability choice: a default would certify P4 and P5 against a figure the running host
# never derived, while printing that `calibrate` derived it. Run `calibrate` here, read its
# window maximum under the one-mode condition that mode states, declare a bound above that
# figure, and pass it.
#
# ★★ THE DIRECTION OF THE WALL DELTA IS NOT A PASS CONDITION IN EITHER DIRECTION. The
# construction is not scoped to buy a win at four to seven nodes, and a reading showing the
# cone arm worse there is a reading. What this script refuses to do is report a delta the
# instrument cannot resolve as though it were one, or report a cell that did not run as a
# cell that cost nothing.
#
# THE TWO HONESTY CLAUSES ARE DIFFERENT CLAUSES AND NEITHER SOFTENS THE OTHER:
#
#   WALL CLOCK has a RESOLUTION FLOOR, and it is a formula rather than a constant: the
#   host's calibrated gap bound times the arm's own min/net amplification. The instrument
#   prices the whole evaluation, so a remedy that is a small fraction of a large eval reads
#   as noise. A net-of-floor delta under that floor is reported as NOT RESOLVED — never as
#   "no difference", and never as a win.
#
#   THE ALLOCATION AXES have no floor of that kind and a different defect: they are a LOWER
#   BOUND. genericClosure's done-set and its key comparisons live in C++ and appear on none
#   of the three. A delta there is admissible as measured and inadmissible as a wall-clock
#   prediction.
#
# THE PROTOCOL, and every rule of it is mandatory rather than advisory:
#   P1  five arms, and the NULL arm — byte-identical to SHIPPED under a second name — is
#       what makes the run admissible at all.
#   P2  round-robin interleaving, the floor included, never blocked. A floor measured as a
#       preamble is a floor from whatever mode the machine was in then.
#   P3  min per arm across rounds, with the SECOND-SMALLEST reported beside it. No mean.
#   P4  NULL-parity or the run is VOID: two byte-identical arms must read alike net of
#       floor, or a mode transition landed between them and no figure may be quoted.
#   P5  the min-second gap is binding, the FLOOR is an arm for this purpose, and the bound
#       is CALIBRATED ON THE HOST by the `calibrate` mode — never assumed. An arm whose min
#       has no near witness is a property of the moment it was taken.
#
# ★ stderr is never suppressed. A missing instrument that reads as a zero timing is the
# failure this whole apparatus exists to avoid.
set -u
cd "$(dirname "$0")/../.." || exit 99

BENCH=./ci/bench/why-cone.nix
MODE=${1:-alloc}

# Elapsed milliseconds. Only stdout is discarded.
t() {
  local s e
  s=$(date +%s%N)
  "$@" >/dev/null
  e=$(date +%s%N)
  echo $(((e - s) / 1000000))
}

arm_cmd() { # arm_cmd <ARM-NAME>
  case "$1" in
  FLOOR) nix-instantiate --eval --impure --expr '"x"' ;;
  NULL) nix-instantiate --eval --strict --impure --argstr arm shippedNull "$BENCH" ;;
  SHIPPED) nix-instantiate --eval --strict --impure --argstr arm shipped "$BENCH" ;;
  ARM) nix-instantiate --eval --strict --impure --argstr arm cone "$BENCH" ;;
  Q1) nix-instantiate --eval --strict --impure --argstr arm q1 "$BENCH" ;;
  CONTROL4X) nix-instantiate --eval --strict --impure --argstr arm q4 "$BENCH" ;;
  *) return 99 ;;
  esac
}
WALL_ARMS=(FLOOR NULL SHIPPED ARM Q1 CONTROL4X)

# "min second" of a whitespace-separated integer list.
minsec() {
  local sorted
  sorted=$(tr ' ' '\n' <<<"$1" | grep -v '^$' | sort -n)
  echo "$(head -n1 <<<"$sorted") $(head -n2 <<<"$sorted" | tail -n1)"
}
# (second - min) / min, in tenths of a percent.
gap10() { echo $((($2 - $1) * 1000 / $1)); }
pct() { printf '%d.%d%%' $(($1 / 10)) $(($1 % 10)); }

case "$MODE" in

alloc)
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  printf '%-11s %8s %14s %12s %14s\n' arm answer list sets nrLookups
  for a in floor shipped cone coneInline; do
    f="$tmp/$a.json"
    # A cell that fails prints FAILED on every column. It must never print zeros: a cell
    # that did not run is not a cell that allocated nothing.
    if ! out=$(NIX_SHOW_STATS=1 NIX_SHOW_STATS_PATH="$f" nix-instantiate --eval --strict \
      --impure --argstr arm "$a" "$BENCH" 2>"$tmp/$a.err"); then
      printf '%-11s %8s %14s %12s %14s\n' "$a" FAILED FAILED FAILED FAILED
      cat "$tmp/$a.err" >&2
      continue
    fi
    if [ ! -f "$f" ]; then
      printf '%-11s %8s %14s %12s %14s\n' "$a" FAILED FAILED FAILED FAILED
      continue
    fi
    ans=$(sed -n 's/.*answer = \([0-9]*\);.*/\1/p' <<<"$out")
    read -r l s k < <(jq -r '"\(.list.elements) \(.sets.elements) \(.nrLookups)"' "$f")
    printf '%-11s %8s %14s %12s %14s\n' "$a" "${ans:-FAILED}" "$l" "$s" "$k"
  done
  ;;

calibrate)
  rounds=${2:-35}
  [ "$rounds" -ge 30 ] || {
    echo "calibrate needs >= 30 rounds (asked $rounds)" >&2
    exit 1
  }
  declare -A obs
  for a in "${WALL_ARMS[@]}"; do obs[$a]=""; done
  for ((r = 1; r <= rounds; r++)); do
    for a in "${WALL_ARMS[@]}"; do obs[$a]="${obs[$a]} $(t arm_cmd "$a")"; done
  done
  # The gap over every six-round window: the statistic P5 binds, at the width P5 reads it.
  echo "rounds=$rounds  window=6"
  for a in "${WALL_ARMS[@]}"; do printf '%-10s %s\n' "$a" "$(echo "${obs[$a]}" | xargs)"; done
  echo
  printf '%-10s %8s %10s %8s %8s %10s\n' arm windows maxGap runMin runMax runSpread
  worst=0
  for a in "${WALL_ARMS[@]}"; do
    read -r -a xs <<<"${obs[$a]}"
    n=${#xs[@]}
    wmax=0
    wcount=0
    for ((i = 0; i + 6 <= n; i++)); do
      window="${xs[i]} ${xs[i + 1]} ${xs[i + 2]} ${xs[i + 3]} ${xs[i + 4]} ${xs[i + 5]}"
      read -r mn sc < <(minsec "$window")
      g=$(gap10 "$mn" "$sc")
      [ "$g" -gt "$wmax" ] && wmax=$g
      wcount=$((wcount + 1))
    done
    # The WHOLE-RUN spread, printed beside the window statistic. It is not a bound and
    # nothing is decided from it here; it is the evidence that says whether the window
    # maximum is a CLEAN maximum at all.
    rsorted=$(tr ' ' '\n' <<<"${obs[$a]}" | grep -v '^$' | sort -n)
    rmin=$(head -n1 <<<"$rsorted")
    rmax=$(tail -n1 <<<"$rsorted")
    printf '%-10s %8d %10s %8d %8d %9s\n' \
      "$a" "$wcount" "$(pct "$wmax")" "$rmin" "$rmax" "$((rmax * 100 / rmin))/100x"
    [ "$wmax" -gt "$worst" ] && worst=$wmax
  done
  echo
  echo "WINDOW MAXIMUM (all arms, all windows): $(pct "$worst")"
  echo
  # ★ WHAT MAY AND MAY NOT BE DECLARED FROM THIS, and the judgement is the reader's rather
  # than a threshold invented here. The window maximum is a CLEAN maximum only if the run
  # held ONE machine mode throughout. Read the raw rows and the runSpread column: readings
  # that fall into two clusters -- a fast group and a slow group roughly twice it -- are a
  # mode transition, and a run that straddled one did not measure a clean maximum, however
  # large or small its window figure came out. Declare a bound above the window maximum of
  # a run WITHOUT a step, and from no other. Declaring one from a straddled run sets the
  # bound above the very value P5 exists to catch.
  echo "A bound is declarable from this run ONLY if its rows hold one mode throughout --"
  echo "see the raw readings and runSpread above. Then pass it: wall <bound%> [rounds]."
  ;;

wall)
  bound=${2:-}
  rounds=${3:-8}
  # P5's bound is CALIBRATED ON THE HOST, so this mode refuses to supply one. A run that
  # certifies itself against an assumed figure is not certified.
  if [ -z "$bound" ]; then
    {
      echo "wall: the gap bound is REQUIRED. It is derived on the host, never assumed."
      echo "      Run '$0 calibrate' HERE, read its window maximum under the one-mode"
      echo "      condition that mode states, declare a bound above that figure, and pass"
      echo "      it: '$0 wall <bound%> [rounds]'."
    } >&2
    exit 2
  fi
  case "$bound" in
  '' | *[!0-9]*)
    echo "wall: bound must be a whole percent, got '$bound'" >&2
    exit 2
    ;;
  esac
  [ "$bound" -gt 0 ] || {
    echo "wall: bound must be positive, got '$bound'" >&2
    exit 2
  }
  bound10=$((bound * 10))
  [ "$rounds" -ge 6 ] || {
    echo "wall needs >= 6 rounds (asked $rounds)" >&2
    exit 1
  }
  declare -A obs
  for a in "${WALL_ARMS[@]}"; do obs[$a]=""; done
  for ((r = 1; r <= rounds; r++)); do
    for a in "${WALL_ARMS[@]}"; do obs[$a]="${obs[$a]} $(t arm_cmd "$a")"; done
  done

  declare -A MIN SEC GAP NET
  read -r fmin _ < <(minsec "${obs[FLOOR]}")
  printf '%-10s %-32s %6s %8s %7s %6s\n' arm readings min second gap net
  void=0
  for a in "${WALL_ARMS[@]}"; do
    read -r mn sc < <(minsec "${obs[$a]}")
    MIN[$a]=$mn
    SEC[$a]=$sc
    GAP[$a]=$(gap10 "$mn" "$sc")
    NET[$a]=$((mn - fmin))
    [ "$a" = FLOOR ] && NET[$a]=$mn
    printf '%-10s %-32s %6d %8d %7s %6d\n' \
      "$a" "$(echo "${obs[$a]}" | xargs)" "$mn" "$sc" "$(pct "${GAP[$a]}")" "${NET[$a]}"
    if [ "${GAP[$a]}" -gt "$bound10" ]; then void=$((void + 1)); fi
  done
  echo
  echo "declared gap bound: $bound% (calibrate mode derives it on this host)"

  # P5 — every arm, the floor included.
  if [ "$void" -eq 0 ]; then
    echo "P5 min-second gap: PASS on all ${#WALL_ARMS[@]} arms"
  else
    echo "P5 min-second gap: FAIL on $void arm(s) -- RUN VOID"
  fi

  # P4 — the two byte-identical arms, net of floor.
  nn=${NET[NULL]}
  ns=${NET[SHIPPED]}
  small=$((nn < ns ? nn : ns))
  diff=$((nn > ns ? nn - ns : ns - nn))
  if [ "$small" -le 0 ]; then
    echo "P4 NULL-parity: FAILED (net of floor is not positive) -- RUN VOID"
    void=$((void + 1))
  else
    p4=$((diff * 1000 / small))
    if [ "$p4" -le "$bound10" ]; then
      echo "P4 NULL-parity: PASS  ($nn vs $ns net, $(pct "$p4") apart)"
    else
      echo "P4 NULL-parity: FAIL  ($nn vs $ns net, $(pct "$p4") apart) -- RUN VOID"
      void=$((void + 1))
    fi
  fi

  # CONTROL-4x is SENSITIVE BUT NOT SPECIFIC: it passes in either machine mode, so it can
  # never certify a run. It answers only whether this instrument can see a factor at all.
  if [ "${NET[Q1]}" -gt 0 ]; then
    echo "CONTROL-4x: $((NET[CONTROL4X] * 100 / NET[Q1]))/100 x  (4x by construction; sensitivity only, certifies nothing)"
  else
    echo "CONTROL-4x: FAILED (Q1 net not positive)"
  fi

  echo
  if [ "$void" -ne 0 ]; then
    echo "RUN VOID -- no figure from it may be quoted, including one that looks reasonable."
    exit 1
  fi

  # The subject, and the resolution floor it is read against.
  na=${NET[ARM]}
  smaller=$((na < ns ? na : ns))
  smallerMin=$((na < ns ? MIN[ARM] : MIN[SHIPPED]))
  amp=$((smallerMin * 1000 / smaller))                 # min/net, x1000
  floor10=$((bound10 * amp / 1000))                    # the resolution floor, tenths of a %
  d=$((na > ns ? na - ns : ns - na))
  dpct=$((d * 1000 / smaller))
  echo "RUN ADMISSIBLE (P4 and P5 both pass; neither suffices alone)"
  echo "SHIPPED net $ns ms   ARM net $na ms   delta $(pct "$dpct") of the smaller net"
  echo "resolution floor = bound $bound% x min/net $((amp / 1000)).$((amp % 1000 / 10)) = $(pct "$floor10")"
  if [ "$dpct" -le "$floor10" ]; then
    echo "VERDICT: NOT RESOLVED BY THIS INSTRUMENT"
  elif [ "$na" -lt "$ns" ]; then
    echo "VERDICT: RESOLVED -- the cone arm is FASTER by $(pct "$dpct") of the smaller net"
  else
    echo "VERDICT: RESOLVED -- the cone arm is SLOWER by $(pct "$dpct") of the smaller net"
  fi
  ;;

*)
  echo "usage: $0 [alloc|calibrate [rounds]|wall <bound%> [rounds]]" >&2
  exit 2
  ;;
esac
