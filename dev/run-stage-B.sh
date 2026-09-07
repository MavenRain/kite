#!/bin/zsh
# kite Stage B runner.  One script holds every gate command and every
# mutation command of the Stage B brief, because a subagent shell resets
# its working directory between calls and only an absolute path is
# repeatable (M0-PLAN.md:150).  Every path below is absolute.
#
# Use:
#   zsh /absolute/path/to/kite/dev/run-stage-B.sh --gate SB-G1
#   zsh /absolute/path/to/kite/dev/run-stage-B.sh --gates-b1
#
# Round B1 writes the script with the five gates round B1 runs, that is
# SB-G1, SB-G3, SB-G4, SB-G8 and SB-G19.  Rounds B2, B3 and B4 APPEND
# their own gate functions and their own dispatch rows, and round B4
# appends the six mutation commands of brief section 5, so every gate a
# round runs already has a home here (brief section 4).
#
# The script never writes in the repository tree.  Every work file and
# every probe lives under SCRATCH.  It runs no git add, no git commit
# and no git push.
#
# WRITTEN in the /Users/oobi/Documents/kite/dev/run-stage-A.sh pattern
# (309 lines).  The set -u header, the REPO and SCRATCH names, the one
# function per gate, the print -r -- evidence lines and the case
# dispatch at the tail are unchanged.  The gate ids become the SB ids.

set -u
setopt pipefail

# The user shell startup files add a chpwd hook that reads an unset
# parameter.  Under set -u that hook fails and cd inherits its non-zero
# status, so the hooks are cleared before any cd (dev/gates.sh:42-46).
chpwd_functions=()
unfunction chpwd 2>/dev/null

REPO=${0:A:h:h}
SCRATCH=${TMPDIR:-/tmp}
SCRATCH=${SCRATCH%/}/kite-stageB-$$
mkdir -m 700 -- "$SCRATCH" || exit 9
cleanup () {
  [[ -d $SCRATCH && ! -L $SCRATCH ]] && rm -rf -- "$SCRATCH"
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

has_line () {
  rg -q -- "$2" <<< "$1"
}

RO_TREES=(
  /Users/oobi/Documents/brisk
  /Users/oobi/Documents/kanon
  /Users/oobi/Documents/affine-lang-tot-pin
)
typeset -A RO_COUNTS

# --- SB-G1 the build ---------------------------------------------------
g1 () {
  local out code
  out=$(zsh $REPO/dev/pin-dune.sh dune build @all 2>&1)
  code=$?
  print -r -- "SB-G1 exit=$code output_bytes=${#out}"
  print -r -- "SB-G1 output=[$out]"
  [[ $code -eq 0 && -z $out ]]
}

# --- SB-G3 the grammar arms of brief 3.1 -------------------------------
g3 () {
  local n missing=0
  local -a tarms karms
  tarms=(Var Con Arrow Record Variant Code REmpty RVar RExt Many AtMostOnce)
  karms=(Type Row)
  for n in $tarms; do
    if rg -q "\b$n\b" $REPO/lib/types.ml; then : ; else
      print -r -- "SB-G3 MISSING types.ml $n"; missing=$(( missing + 1 ))
    fi
  done
  for n in $karms; do
    if rg -q "\b$n\b" $REPO/lib/kind.ml; then : ; else
      print -r -- "SB-G3 MISSING kind.ml $n"; missing=$(( missing + 1 ))
    fi
  done
  print -r -- "SB-G3 arms-missing=$missing of $(( ${#tarms} + ${#karms} ))"
  [[ $missing -eq 0 ]]
}

# --- SB-G4 the house rules ---------------------------------------------
g4 () {
  local out code
  out=$(zsh $REPO/dev/house.sh 2>&1)
  code=$?
  print -r -- "$out"
  print -r -- "SB-G4 exit=$code"
  [[ $code -eq 0 ]] && has_line "$out" '^HOUSE OK$'
}

# --- SB-G8 the closed fifteen-name error set ---------------------------
# The count reads the TYPE DECLARATION span alone, because the arms of
# name, span_of and text_of match the same pattern and a raw file count
# reads them too (brief SB-G8).
g8 () {
  local count names
  count=$(awk '/^type t =/,/^$/' $REPO/lib/error.ml | rg -c '^  \| [A-Z]')
  names=$(awk '/^type t =/,/^$/' $REPO/lib/error.ml \
    | rg -o '^  \| [A-Z][A-Za-z]*' | sd '^  \| ' '' | sort | tr '\n' ' ')
  print -r -- "SB-G8 constructors=$count"
  print -r -- "SB-G8 names=$names"
  [[ $count == 15 && $names == 'Affine Budget Capture Compensation IfaceMismatch KindMismatch Mismatch NotYet OccursRow OccursType Parse PeerLost RowDuplicate RowMissing Unbound ' ]]
}

# --- SB-G19 the read-only trees, two clauses ---------------------------
# The count clause is taken twice in the round's own window:  once with
# start and once with end.  Equal counts pass (brief SB-G19).
g19 () {
  local when=${1:-now} tree head porcelain fresh failed=0
  for tree in $RO_TREES; do
    head=$(git -C $tree log -1 --format='%h %ci %s' 2>&1) || failed=1
    porcelain=$(git -C $tree status --porcelain | wc -l | tr -d ' ') || failed=1
    fresh=$(fd -t f --changed-within 240min . $tree --exclude .git | wc -l | tr -d ' ') || failed=1
    print -r -- "SB-G19 $when tree=$tree porcelain=$porcelain changed_240min=$fresh head=$head"
    if [[ $when == start ]]; then
      RO_COUNTS[$tree]=$porcelain
    elif [[ -n ${RO_COUNTS[$tree]:-} && ${RO_COUNTS[$tree]} != $porcelain ]]; then
      print -r -- "SB-G19 count_changed tree=$tree before=${RO_COUNTS[$tree]} after=$porcelain explanation_required=yes"
      failed=1
    fi
  done
  return $failed
}

# --- the git witness of SB-G18, printed by every round -----------------
gitw () {
  local history count porcelain
  history=$(git -C $REPO log --oneline) || return 1
  count=$(git -C $REPO rev-list --count HEAD) || return 1
  porcelain=$(git -C $REPO status --porcelain) || return 1
  print -r -- "GIT log=$(print -r -- "$history" | wc -l | tr -d ' ') count=$count"
  print -r -- "GIT porcelain=[$porcelain]"
  [[ $count == 1 ]]
}

# === round B2 appends SB-G2, SB-G5, SB-G6, SB-G7 and SB-G9 =============

# The file list the CHECK gate reads:  every positive of test/pos and the
# six negative twins of test/neg, which are the check- files and the
# milestones twin.  The parse- negatives of Stage A belong to the PARSE
# leg and never to this one.
check_files () {
  print -r -- $REPO/test/pos/*.kite(N) $REPO/test/neg/check-*.kite(N) \
    $REPO/test/neg/milestones.kite(N)
}

# --- SB-G2 the files of the round exist --------------------------------
g2 () {
  local p missing=0 positives
  local -a want base
  base=(lib/usage.ml lib/infer.ml lib/dune test/check.ml test/dune
        test/pos/affine-ok.usage
        lib/iface.ml lib/ir.ml lib/lower.ml lib/pp.ml lib/sha256.ml
        lib/types.ml lib/kind.ml lib/row.ml lib/subst.ml lib/unify.ml lib/env.ml
        bin/kite.ml bin/dune test/iface.ml test/pos/import-iface.coi
        examples/m0-spine.kite examples/m0-spine.sha256 examples/m0-spine.lines
        dev/floor-corpus.txt dev/floor-corpus.sha256 dev/floor-corpus.lines)
  want=($base)
  for p in affine-ok lit lam-app let-poly value-restriction records row-var \
           scoped variant-match import-iface protocol-role budget-ok manifest; do
    want+=(test/pos/$p.kite test/pos/$p.scheme)
  done
  for p in check-affine check-capture check-compensate check-peer-lost \
           check-budget milestones; do
    want+=(test/neg/$p.kite test/neg/$p.err)
  done
  for p in $want; do
    if [[ -f $REPO/$p ]]; then : ; else
      print -r -- "SB-G2 MISSING $p"; missing=$(( missing + 1 ))
    fi
  done
  positives=$(fd -e kite . $REPO/test/pos | wc -l | tr -d ' ') || return 1
  print -r -- "SB-G2 pos_kite=$positives"
  print -r -- "SB-G2 missing=$missing of ${#want}"
  [[ $missing -eq 0 && $positives == 13 ]]
}

# --- SB-G5 the CHECK leg ------------------------------------------------
# The CHECK leg builds first and includes the solver regressions.
g5 () {
  local out code p q
  out=$(zsh $REPO/dev/gates.sh --leg check 2>&1)
  code=$?
  print -r -- "$out"
  p=$(print -r -- "$out" | rg -o 'pos=[0-9]+' | sd 'pos=' '')
  q=$(print -r -- "$out" | rg -o 'neg=[0-9]+' | sd 'neg=' '')
  print -r -- "SB-G5 exit=$code"
  if [[ $code -eq 0 && ${p:-0} -ge 13 && ${q:-0} -ge 6 ]] \
      && has_line "$out" '^CHECK files=[0-9]+ pos=[0-9]+ neg=[0-9]+ ok=[0-9]+ fail=0$' \
      && has_line "$out" '^PASS CHECK positives=[0-9]+ twins=[0-9]+$'; then
    print -r -- "PASS CHECK positives=$p twins=$q"
    return 0
  else
    print -r -- "FAIL CHECK positives=${p:-0} twins=${q:-0} exit=$code"
    return 1
  fi
}

# --- SB-G6 the CHECK leg is not vacuous --------------------------------
# Clause one:  no argument prints CHECK-EMPTY and exits 2.  Clause two:  a
# COPY of the tree under SCRATCH with one byte changed in a golden prints
# one CHECK-FAIL and exits 1.  The copy carries the mutation, never the
# repository tree.
g6 () {
  local out1 code1 out2 code2 fails
  out1=$($REPO/_build/default/test/check.exe 2>&1)
  code1=$?
  print -r -- "SB-G6 empty=[$out1] exit=$code1"
  mkdir -p $SCRATCH/mutcheck || return 1
  cp -R $REPO/test/pos $SCRATCH/mutcheck/pos || return 1
  rg -q 'Unit' $SCRATCH/mutcheck/pos/lit.scheme || return 1
  sd 'Unit' 'Uni7' $SCRATCH/mutcheck/pos/lit.scheme || return 1
  cmp -s $REPO/test/pos/lit.scheme $SCRATCH/mutcheck/pos/lit.scheme && return 1
  out2=$($REPO/_build/default/test/check.exe $SCRATCH/mutcheck/pos/lit.kite 2>&1)
  code2=$?
  fails=$(print -r -- "$out2" | rg -c '^CHECK-FAIL' || true)
  print -r -- "SB-G6 mutant_fails=$fails exit=$code2"
  print -r -- "SB-G6 mutant_line=[$(print -r -- "$out2" | rg '^CHECK-FAIL' | head -1)]"
  [[ $code1 -eq 2 && $out1 == CHECK-EMPTY && $code2 -eq 1 && $fails == 1 ]]
}

# --- SB-G7 the six twins ------------------------------------------------
g7 () {
  local t out code golden failed=0 i=1 distinct
  local -a twins expected
  twins=(check-affine check-capture check-compensate check-peer-lost
         check-budget milestones)
  expected=(Affine Capture Compensation PeerLost Budget NotYet)
  for t in $twins; do
    out=$($REPO/_build/default/test/check.exe $REPO/test/neg/$t.kite 2>&1)
    code=$?
    golden=$(cat $REPO/test/neg/$t.err) || failed=1
    print -r -- "SB-G7 $t exit=$code golden=$golden [$out]"
    [[ $code -eq 0 && $golden == ${expected[$i]} ]] || failed=1
    has_line "$out" '^CHECK files=1 pos=0 neg=1 ok=1 fail=0$' || failed=1
    i=$(( i + 1 ))
  done
  distinct=$(cat $REPO/test/neg/check-*.err $REPO/test/neg/milestones.err | sort -u | wc -l | tr -d ' ') || failed=1
  print -r -- "SB-G7 twins=${#twins} distinct_goldens=$distinct"
  [[ $distinct == 6 ]] || failed=1
  return $failed
}

# --- SB-G9 the usage golden --------------------------------------------
g9 () {
  local lines ones
  lines=$(wc -l < $REPO/test/pos/affine-ok.usage | tr -d ' ')
  ones=$(rg -c 'Once' $REPO/test/pos/affine-ok.usage || true)
  print -r -- "SB-G9 usage_lines=$lines once_lines=$ones"
  print -r -- "SB-G9 usage=[$(cat $REPO/test/pos/affine-ok.usage | tr '\n' ';')]"
  [[ ${lines:-0} -ge 2 && ${ones:-0} -ge 1 ]]
}

# --- SB-G10 the .coi write-then-read round trip -------------------------
# test/iface.exe builds the interface of every positive, writes it, reads
# that text back and compares, and the golden of test/pos/import-iface
# carries a val line, a second val line and the import line.
g10 () {
  local out code rows first
  out=$($REPO/_build/default/test/iface.exe $REPO/test/pos/*.kite(N) 2>&1)
  code=$?
  print -r -- "SB-G10 exit=$code [$out]"
  first=$(head -1 $REPO/test/pos/import-iface.coi) || return 1
  print -r -- "SB-G10 head1=[$first]"
  rows=$(rg -c '^budget |^import |^val ' $REPO/test/pos/import-iface.coi || true)
  print -r -- "SB-G10 coi_rows=$rows"
  [[ $code -eq 0 && $first == 'coi 1' && ${rows:-0} -ge 3 ]] \
    && has_line "$out" '^IFACE files=13 ok=13 fail=0$'
}

# --- SB-G11 separate compilation ---------------------------------------
# A.kite exports one name.  kite.exe iface writes A.coi, the SOURCE of A
# is then REMOVED, and B.kite type checks against A.coi alone through the
# Stage A import declaration, which is the whole dependency edge and adds
# no surface syntax (D-B-15).  A second B whose import declares another
# type prints IfaceMismatch at exit 1.
g11 () {
  local sep=$SCRATCH/sep out code failed=0
  mkdir -p $sep || return 1
  {
    print -r -- '(* Module A of the separate-compilation pair.  One export. *)'
    print -r -- 'let fetch = fun n -> if n == 0 then "zero" else "more"'
  } > $sep/A.kite
  {
    print -r -- '(* Module B.  The edge is the Stage A import declaration. *)'
    print -r -- 'import fetch : Int -> Str cost 3 deadline 5'
    print -r -- 'let text = fetch 1'
  } > $sep/B.kite
  {
    print -r -- '(* Module B with a wrong import type. *)'
    print -r -- 'import fetch : Str -> Str cost 3 deadline 5'
    print -r -- 'let text = fetch "x"'
  } > $sep/Bbad.kite
  out=$($REPO/_build/default/bin/kite.exe iface $sep/A.kite 2>&1); code=$?
  print -r -- "SB-G11 iface exit=$code [$out]"
  [[ $code -eq 0 && -f $sep/A.coi ]] || return 1
  has_line "$out" '^IFACE-OK file=.*[/]A.kite exports=1$' || failed=1
  rm -f $sep/A.kite || return 1
  if [[ -f $sep/A.kite ]]; then
    print -r -- "SB-G11 source_present=yes"
    failed=1
  else
    print -r -- "SB-G11 source_present=no"
  fi
  out=$($REPO/_build/default/bin/kite.exe check --iface $sep/A.coi $sep/B.kite 2>&1)
  code=$?
  print -r -- "SB-G11 check exit=$code [$out]"
  [[ $code -eq 0 ]] && has_line "$out" '^CHECK-OK files=1$' || failed=1
  out=$($REPO/_build/default/bin/kite.exe check --iface $sep/A.coi $sep/Bbad.kite 2>&1)
  code=$?
  print -r -- "SB-G11 mismatch exit=$code [$out]"
  [[ $code -eq 1 ]] && has_line "$out" '^IfaceMismatch ' || failed=1
  return $failed
}

# --- SB-G12 the driver, one run per verb --------------------------------
# The fmt leg compares the fmt output with the fmt of that output, which
# is the canonical form of surface/print.ml as a fixed point.
g12 () {
  local d=$SCRATCH/verbs out code failed=0
  mkdir -p $d || return 1
  cp $REPO/test/pos/lam-app.kite $d/spine.kite || return 1
  local -a verbs patterns
  verbs=(check build iface roundtrip)
  patterns=('^CHECK-OK files=1$' '^BUILD-OK file=.+ ir=.+ bytes=[1-9][0-9]* artifact=.+[.]kite[.]js$'
            '^IFACE-OK file=.+ exports=[0-9]+$' '^ROUNDTRIP-OK file=.+$')
  local v i=1
  for v in $verbs; do
    out=$($REPO/_build/default/bin/kite.exe $v $d/spine.kite 2>&1); code=$?
    print -r -- "SB-G12 $v exit=$code [$out]"
    [[ $code -eq 0 ]] && has_line "$out" "${patterns[$i]}" || failed=1
    i=$(( i + 1 ))
  done
  out=$($REPO/_build/default/bin/kite.exe run 2>&1); code=$?
  print -r -- "SB-G12 run-missing-file exit=$code [$out]"
  [[ $code -eq 2 && $out == 'usage: kite check build iface run fmt roundtrip version' ]] || failed=1
  print -r -- 'let result = 6 * 7' > $d/run.kite
  out=$($REPO/_build/default/bin/kite.exe run $d/run.kite 2>&1); code=$?
  print -r -- "SB-G12 run exit=$code [$out]"
  [[ $code -eq 0 && $out == 'RUN-OK value=42' && -s $d/spine.kite.js ]] || failed=1
  $REPO/_build/default/bin/kite.exe fmt $d/spine.kite > $d/fmt1.out || failed=1
  $REPO/_build/default/bin/kite.exe fmt $d/fmt1.out > $d/fmt2.out || failed=1
  if cmp -s $d/fmt1.out $d/fmt2.out; then
    print -r -- "SB-G12 fmt exit=0 canonical=yes lines=$(wc -l < $d/fmt1.out | tr -d ' ')"
  else
    print -r -- "SB-G12 fmt exit=1 canonical=no"
    failed=1
  fi
  [[ -s $d/fmt1.out ]] || failed=1
  out=$($REPO/_build/default/bin/kite.exe version 2>&1); code=$?
  print -r -- "SB-G12 version exit=$code [$out]"
  [[ $code -eq 0 && $out == 'kite 0.1.0 ocaml 5.3.0 dune 3.24.0' ]] || failed=1
  out=$($REPO/_build/default/bin/kite.exe 2>&1); code=$?
  print -r -- "SB-G12 no_verb exit=$code [$out]"
  [[ $code -eq 2 ]] || failed=1
  return $failed
}

# === round B4 appends SB-G13 to SB-G20 and SB-M1 to SB-M6 =============

# --- SB-G13 the grown PARSE leg ----------------------------------------
g13 () {
  local out code n want
  # The wanted count lives in dev/gates.sh alone (F30).
  want=$(rg -o '^PARSE_FIXTURES=[0-9]+' $REPO/dev/gates.sh | sd 'PARSE_FIXTURES=' '')
  out=$(zsh $REPO/dev/gates.sh --leg parse 2>&1)
  code=$?
  print -r -- "$out" | tail -2
  n=$(print -r -- "$out" | rg -o 'fixtures=[0-9]+' | sd 'fixtures=' '' | tail -1)
  print -r -- "SB-G13 exit=$code fixtures=${n:-0} want=${want:-0}"
  [[ $code -eq 0 && -n $want && $n == $want ]] \
    && has_line "$out" "^PASS PARSE fixtures=$want\$"
}

# --- SB-G14 the TRUSTED-LINES budget -----------------------------------
g14 () {
  local out code
  out=$(zsh $REPO/dev/trusted-lines.sh --require $REPO 2>&1)
  code=$?
  print -r -- "$out"
  print -r -- "SB-G14 exit=$code"
  [[ $code -eq 0 ]] && has_line "$out" '^TRUSTED-LINES elaborator=[1-9][0-9]*/2400 OK$'
}

floor_evidence () {
  local out=$1 field line
  line=$(print -r -- "$out" | rg '^FLOOR ') || return 1
  for field in pipeline_ms_per_kloc floor_ms_per_kloc num_sha flo_sha \
               num_kloc flo_kloc host arch load_before load_after; do
    has_line "$line" "(^| )$field=[^ ]+" || return 1
  done
  has_line "$out" '^DENOM-FROZEN kanon_serial=1641.599 kanon_parallel=712.803$' \
    && has_line "$out" '^WASMGC-ONLY absent at M0$' \
    && has_line "$out" '^GATE-OK$'
}

# --- SB-G15 GATE M0, the ONE measurable gate ---------------------------
# The leg PRINTS its load and never moves a bound.  One named retry of
# D-B-25:  when the leg fails and load_after is more than 1.5 times
# load_before, the runner runs the leg ONCE more, both FLOOR lines are
# printed and the SECOND result stands.
g15 () {
  local out code line l1 l2 retry
  out=$(zsh $REPO/dev/gates.sh --leg floor 2>&1)
  code=$?
  line=$(print -r -- "$out" | rg -- '^FLOOR ' || true)
  print -r -- "$out" | rg -- '^(FLOOR |DENOM-FROZEN|WASMGC-ONLY|GATE-|PASS FLOOR|FAIL FLOOR)' || true
  print -r -- "SB-G15 attempt=1 exit=$code"
  if [[ $code -eq 0 ]]; then
    floor_evidence "$out"
    return $?
  fi
  l1=$(print -r -- "$line" | rg -o 'load_before=[0-9.]+' | sd 'load_before=' '')
  l2=$(print -r -- "$line" | rg -o 'load_after=[0-9.]+' | sd 'load_after=' '')
  retry=$(awk -v a="${l1:-0}" -v b="${l2:-0}" 'BEGIN { print (b > 1.5 * a) ? "yes" : "no" }')
  print -r -- "SB-G15 load_before=$l1 load_after=$l2 retry=$retry"
  if [[ $retry != "yes" ]]; then
    print -r -- "SB-G15 HALT-KITE-B-5 the gate failed and the load does not explain it"
    return 1
  fi
  out=$(zsh $REPO/dev/gates.sh --leg floor 2>&1)
  code=$?
  print -r -- "$out" | rg -- '^(FLOOR |DENOM-FROZEN|WASMGC-ONLY|GATE-|PASS FLOOR|FAIL FLOOR)' || true
  print -r -- "SB-G15 attempt=2 exit=$code (the second result stands, D-B-25)"
  [[ $code -eq 0 ]] && floor_evidence "$out"
}

# --- SB-G16 the whole battery ------------------------------------------
g16 () {
  local out code left leg failed=0
  out=$(zsh $REPO/dev/gates.sh 2>&1)
  code=$?
  print -r -- "$out" | rg -- '^(GATES |KANON-DENOM|PASS |FAIL |MEASURE |FLOOR |DENOM-FROZEN|WASMGC-ONLY|GATE-|GATES-)' || true
  left=$(fd -t d 'kite-(floor|denom|gates)-' ${TMPDIR:-/tmp} -d 1 | wc -l | tr -d ' ') || failed=1
  print -r -- "SB-G16 exit=$code leftover_dirs=$left"
  [[ $code -eq 0 && $left == 0 ]] || failed=1
  for leg in BUILD HOUSE PARSE CHECK TRUSTED-LINES DENOMINATORS FLOOR; do
    has_line "$out" "^PASS $leg($| )" || failed=1
  done
  has_line "$out" '^GATES-OK$' || failed=1
  has_line "$out" '^MEASURE ' || failed=1
  return $failed
}

# --- SB-G17 the four sidecars, the denominator record and the pin ------
g17 () {
  local out code failed=0 recorded measured pin_head pin_porcelain
  out=$(cd $REPO/examples && shasum -a 256 -c m0-spine.sha256 2>&1)
  code=$?
  print -r -- "SB-G17 spine_sha=[$out] exit=$code"
  [[ $code -eq 0 ]] || failed=1
  recorded=$(cat $REPO/examples/m0-spine.lines) || failed=1
  measured=$(wc -l < $REPO/examples/m0-spine.kite | tr -d ' ') || failed=1
  print -r -- "SB-G17 spine_lines=[$recorded] measured=[$measured]"
  [[ -n $recorded && $recorded == $measured ]] || failed=1
  out=$(cd $REPO/dev && shasum -a 256 -c floor-corpus.sha256 2>&1)
  code=$?
  print -r -- "SB-G17 floor_sha=[$out] exit=$code"
  [[ $code -eq 0 ]] || failed=1
  local -a paths
  paths=()
  local n
  for n in ${(f)"$(cat $REPO/dev/floor-corpus.txt)"}; do
    paths+=(/Users/oobi/Documents/affine-lang-tot-pin/lib/$n)
  done
  [[ ${#paths} -gt 0 ]] || return 1
  recorded=$(cat $REPO/dev/floor-corpus.lines) || failed=1
  measured=$(cat $paths | wc -l | tr -d ' ') || failed=1
  print -r -- "SB-G17 floor_lines=[$recorded] measured=[$measured]"
  [[ -n $recorded && $recorded == $measured ]] || failed=1
  out=$(cd $REPO/dev && shasum -a 256 -c DENOMINATORS.sha256 2>&1)
  code=$?
  print -r -- "SB-G17 denominators=[$out] exit=$code"
  [[ $code -eq 0 ]] || failed=1
  pin_head=$(git -C /Users/oobi/Documents/affine-lang-tot-pin rev-parse --short HEAD) || failed=1
  pin_porcelain=$(git -C /Users/oobi/Documents/affine-lang-tot-pin status --porcelain) || failed=1
  print -r -- "SB-G17 pin_head=$pin_head pin_porcelain=[$pin_porcelain]"
  [[ $pin_head == 6d0d48d && -z $pin_porcelain ]] || failed=1
  return $failed
}

# --- SB-G18 the git witness --------------------------------------------
g18 () {
  local history count porcelain builds kirs ignored
  history=$(git -C $REPO log --oneline) || return 1
  count=$(git -C $REPO rev-list --count HEAD) || return 1
  porcelain=$(git -C $REPO status --porcelain) || return 1
  builds=$(print -r -- "$porcelain" | rg -c '_build' || true)
  kirs=$(print -r -- "$porcelain" | rg -c '\.kir' || true)
  ignored=$(rg -c '^\*\.kir$' $REPO/.gitignore || true)
  print -r -- "SB-G18 log=[$history]"
  print -r -- "SB-G18 count=$count"
  print -r -- "SB-G18 porcelain_build=${builds:-0}"
  print -r -- "SB-G18 porcelain_kir=${kirs:-0}"
  print -r -- "SB-G18 gitignore_kir=$ignored"
  print -r -- "SB-G18 kir_on_disk=$(fd -e kir --no-ignore . $REPO --exclude _build --exclude .git | wc -l | tr -d ' ')"
  print -r -- "SB-G18 porcelain=[$porcelain]"
  [[ $count == 1 && $history == 'b5c1496 M0 Stage A: skeleton, lexer and parser' \
     && ${builds:-0} == 0 && ${kirs:-0} == 0 && $ignored == 1 ]]
}

# --- SB-G20 the em-dash count ------------------------------------------
g20 () {
  local out code
  out=$(zsh $REPO/dev/house.sh 2>&1)
  code=$?
  out=$(print -r -- "$out" | rg -- 'no-em-dash')
  print -r -- "SB-G20 [$out]"
  [[ $code -eq 0 && $out == 'HOUSE no-em-dash OK' ]]
}

# --- the six mutation checks of brief section 5 ------------------------
# Every mutation rides a COPY under SCRATCH, never a repository file.
# gates.sh takes its root from its own path, so the copy gates itself.
MUTWD=""
if command -v timeout > /dev/null 2>&1; then
  MUTWD=timeout
elif command -v gtimeout > /dev/null 2>&1; then
  MUTWD=gtimeout
fi

mut_prepare () {
  local n=$1
  [[ -n $MUTWD ]] || { print -r -- "SB-M$n SETUP-FAIL timeout unavailable"; return 1; }
  mkdir $SCRATCH/mut-$n || return 1
  rsync -a --exclude _build --exclude .git $REPO/ $SCRATCH/mut-$n/
}

mut_edit () {
  local n=$1 relative=$2 before=$3 after=$4 file
  file=$SCRATCH/mut-$n/$relative
  if ! rg -UFq -- "$before" "$file"; then
    print -r -- "SB-M$n EDIT-FAIL source pattern missing in $relative"
    return 1
  fi
  sd -F -n 1 -- "$before" "$after" "$file" || return 1
  if rg -UFq -- "$before" "$file" || ! rg -UFq -- "$after" "$file"; then
    print -r -- "SB-M$n EDIT-FAIL replacement not unique in $relative"
    return 1
  fi
  print -r -- "SB-M$n edit=[$after] file=$relative"
}

mut_build () {
  local n=$1 out code
  out=$(zsh $SCRATCH/mut-$n/dev/pin-dune.sh dune build @all 2>&1)
  code=$?
  print -r -- "SB-M$n build exit=$code output_bytes=${#out}"
  if [[ $code -ne 0 ]]; then
    print -r -- "$out"
    return 1
  fi
  return 0
}

# mut_verdict ID PATTERN OUTPUT EXIT SUMMARY_PATTERN
mut_verdict () {
  local id=$1 pattern=$2 out=$3 code=$4 summary=$5
  if [[ $code -eq 1 ]] && has_line "$out" "$pattern" \
      && has_line "$out" "$summary"; then
    print -r -- "$id KILLED exit=$code"
    return 0
  else
    print -r -- "$id SURVIVED exit=$code"
    return 1
  fi
}

m1 () {
  mut_prepare 1 || return 1
  mut_edit 1 lib/infer.ml 'let* () = check_uses e s p in' 'let* () = Ok () in' || return 1
  mut_build 1 || return 1
  local out code
  out=$($MUTWD 200 zsh $SCRATCH/mut-1/dev/gates.sh --leg check 2>&1)
  code=$?
  print -r -- "$out" | rg -- '^(CHECK-FAIL|CHECK files=|FAIL CHECK|PASS CHECK)' || true
  mut_verdict SB-M1 '^CHECK-FAIL .*/test/neg/check-affine.kite ' "$out" $code '^FAIL CHECK'
}

m2 () {
  mut_prepare 2 || return 1
  mut_edit 2 lib/unify.ml '| Types.RVar v -> v.rid = id' '| Types.RVar _v -> false' || return 1
  mut_build 2 || return 1
  local out code
  out=$($MUTWD 200 zsh $SCRATCH/mut-2/dev/gates.sh --leg check 2>&1)
  code=$?
  print -r -- "$out" | rg -- '^(REGRESS|CHECK-FAIL|CHECK files=|FAIL CHECK|PASS CHECK)' || true
  mut_verdict SB-M2 '^REGRESS-FAIL row-occurs($| )' "$out" $code '^FAIL CHECK'
}

m3 () {
  mut_prepare 3 || return 1
  mut_edit 3 lib/row.ml 'let hit = same && seen = want in' \
    'let rec later (tail : Types.row) : bool =
        match Subst.resolve_row st tail with
        | Types.REmpty -> false
        | Types.RVar _tail -> false
        | Types.RExt (next, _occ, _ty, more) -> Label.equal l next || later more in
      let hit = same && seen >= want && not (later rest) in' || return 1
  mut_build 3 || return 1
  local out code
  out=$($MUTWD 200 zsh $SCRATCH/mut-3/dev/gates.sh --leg check 2>&1)
  code=$?
  print -r -- "$out" | rg -- '^(CHECK-FAIL|CHECK files=|FAIL CHECK|PASS CHECK)' || true
  mut_verdict SB-M3 '^CHECK-FAIL .*/test/pos/scoped.kite ' "$out" $code '^FAIL CHECK'
}

m4 () {
  mut_prepare 4 || return 1
  mut_edit 4 lib/infer.ml 'let close = is_value v in' 'let close = true in' || return 1
  mut_build 4 || return 1
  local out code
  out=$($MUTWD 200 zsh $SCRATCH/mut-4/dev/gates.sh --leg check 2>&1)
  code=$?
  print -r -- "$out" | rg -- '^(CHECK-FAIL|CHECK files=|FAIL CHECK|PASS CHECK)' || true
  mut_verdict SB-M4 '^CHECK-FAIL .*/test/pos/value-restriction.kite ' "$out" $code '^FAIL CHECK'
}

m5 () {
  mut_prepare 5 || return 1
  mut_edit 5 lib/iface.ml \
    $'| () when String.equal (peek ts) "budget" ->\n    let* b = p_budget ts in\n    Ok { acc with budgets = List.append acc.budgets [ b ] }' \
    '| () when String.equal (peek ts) "budget" -> Ok acc' || return 1
  mut_build 5 || return 1
  local out code
  out=$($MUTWD 200 $SCRATCH/mut-5/_build/default/test/iface.exe $SCRATCH/mut-5/test/pos/budget-ok.kite 2>&1)
  code=$?
  print -r -- "$out"
  mut_verdict SB-M5 '^IFACE-FAIL .*/test/pos/budget-ok.kite ' "$out" $code '^IFACE files=1 ok=0 fail=1$'
}

m6 () {
  mut_prepare 6 || return 1
  [[ -f $SCRATCH/mut-6/examples/m0-spine.sha256 ]] || return 1
  rm $SCRATCH/mut-6/examples/m0-spine.sha256 || return 1
  [[ ! -e $SCRATCH/mut-6/examples/m0-spine.sha256 ]] || return 1
  print -r -- "SB-M6 edit=[removed examples/m0-spine.sha256, present=$(test -f $SCRATCH/mut-6/examples/m0-spine.sha256 && print yes || print no)]"
  mut_build 6 || return 1
  local out code
  out=$($MUTWD 300 zsh $SCRATCH/mut-6/dev/gates.sh --leg floor 2>&1)
  code=$?
  print -r -- "$out" | rg -- '^(GATE-|FAIL FLOOR|PASS FLOOR|floor sidecar)' || true
  print -r -- "SB-M6 gate_ok_lines=$(print -r -- "$out" | rg -c '^GATE-OK' || true)"
  if has_line "$out" '^GATE-OK$'; then
    print -r -- "SB-M6 SURVIVED contradictory GATE-OK exit=$code"
    return 1
  fi
  mut_verdict SB-M6 '^GATE-FAIL floor sidecar missing$' "$out" $code '^FAIL FLOOR$'
}

run_battery () {
  local label=$1 task failed=0
  shift
  for task in "$@"; do
    if "$task"; then
      print -r -- "$label task=$task PASS"
    else
      print -r -- "$label task=$task FAIL"
      failed=$(( failed + 1 ))
    fi
  done
  print -r -- "$label failures=$failed"
  [[ $failed -eq 0 ]]
}

run_gates () {
  local failed=0
  g19 start || failed=1
  run_battery STAGE-B-GATES "$@" || failed=1
  g19 end || failed=1
  gitw || failed=1
  return $failed
}

case ${1:-} in
  --gate)
    case ${2:-} in
      SB-G1) g1 ;;
      SB-G2) g2 ;;
      SB-G3) g3 ;;
      SB-G4) g4 ;;
      SB-G5) g5 ;;
      SB-G6) g6 ;;
      SB-G7) g7 ;;
      SB-G8) g8 ;;
      SB-G9) g9 ;;
      SB-G10) g10 ;;
      SB-G11) g11 ;;
      SB-G12) g12 ;;
      SB-G13) g13 ;;
      SB-G14) g14 ;;
      SB-G15) g15 ;;
      SB-G16) g16 ;;
      SB-G17) g17 ;;
      SB-G18) g18 ;;
      SB-G19) g19 ${3:-now} ;;
      SB-G20) g20 ;;
      GIT) gitw ;;
      *) print -r -- "run-stage-B: unknown gate ${2:-}"; exit 64 ;;
    esac ;;
  --gates-b1)
    run_gates g1 g3 g4 g8 ;;
  --gates-b2)
    run_gates g1 g2 g4 g5 g6 g7 g9 ;;
  --gates-b3)
    run_gates g1 g2 g4 g10 g11 g12 ;;
  --gates-b4)
    run_gates g13 g14 g15 g16 g17 g18 g20 ;;
  --gates-all)
    run_gates g1 g2 g3 g4 g5 g6 g7 g8 g9 g10 g11 g12 \
      g13 g14 g15 g16 g17 g18 g20 ;;
  --mutants)
    run_battery STAGE-B-MUTANTS m1 m2 m3 m4 m5 m6 ;;
  --mutant)
    case ${2:-} in
      SB-M1) m1 ;;
      SB-M2) m2 ;;
      SB-M3) m3 ;;
      SB-M4) m4 ;;
      SB-M5) m5 ;;
      SB-M6) m6 ;;
      *) print -r -- "run-stage-B: unknown mutant ${2:-}"; exit 64 ;;
    esac ;;
  *)
    print -r -- "usage: zsh dev/run-stage-B.sh [--gate ID | --mutant ID | --gates-b1 | --gates-b2 | --gates-b3 | --gates-b4 | --gates-all | --mutants]"
    exit 64 ;;
esac
