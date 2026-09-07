#!/bin/zsh
# dev/gates.sh
# The M0 gate battery and M1 native and browser runtime checks.  Example:
#   zsh /Users/oobi/Documents/kite/dev/gates.sh
#
# At Stage B seven legs run, BUILD, HOUSE, PARSE, CHECK, TRUSTED-LINES,
# DENOMINATORS and FLOOR, which are the legs of the stage row of the
# Stage B brief 3.17.  The four legs of Stage A are unchanged.  The
# CHECK leg, the TRUSTED-LINES leg and the FLOOR leg arrive here in
# round B4 with the corpora they read (D-B-26, D-B-28, D-B-24).  Every
# other leg of plan section 9 is absent, not stubbed:  a leg with
# nothing to check is a vacuous pass.
# M1-A adds RUNTIME for the planner and local Worker lifecycle models.
# M1-B adds BROWSER and js_of_ocaml emission to each FLOOR sample.
# M1-C adds source execution and full hidden-tab acceptance.
#
# Each leg prints one PASS or FAIL line.  A FAIL adds the leg's captured
# output under its line.  Every leg runs even when an earlier one failed,
# so one run names every failing leg.  After the last leg the script
# prints the MEASURE block, one line per leg, then GATES-OK and exit 0,
# or GATES-FAIL and exit 1.
#
# Line 1 of a run names the tree and line 2 carries the frozen kanon
# denominators, 1641.599 serial and 712.803 parallel.  Both come from
# dev/denominators.json and neither is ever gated (plan:76, plan:108).
#
# The root comes from this script's own path, so a copy of the repository
# under a scratch directory gates itself.  The work directory sits under
# $TMPDIR and not in the tree, so a gate run leaves the repository clean.
#
# The script also runs one leg alone, which is how the watchdog wraps a
# leg whose body is a shell function:
#   zsh dev/gates.sh --leg denominators
#
# ADAPTED from /Users/oobi/Documents/brisk/dev/gates.sh (393 lines).  The
# self-location, the watchdog choice, the named tiers, gate_timed, the
# field helper, the leg helper, the --leg dispatch, the MEASURE block and
# the GATES-OK and GATES-FAIL lines are unchanged.  The brisk SUITE-CHECK
# leg is dropped, because its driver arrives at Stage B;  the fixture
# extension becomes .kite and the fixture list is the three directories
# of the Stage A brief 3.9;  the DENOMINATORS leg reads kite_corpus in
# place of brisk_corpus;  the header and the frozen kanon line are new.

set -u

# The user shell startup files add a chpwd hook that reads an unset
# parameter.  Under set -u that hook fails and cd inherits its non-zero
# status, so the hooks are cleared before any cd.
chpwd_functions=()
unfunction chpwd 2>/dev/null

# EPOCHREALTIME carries microseconds, which is the resolution gate_timed
# reports in milliseconds.
zmodload zsh/datetime

SELF=${0:A}
ROOT=${0:A:h}/..
ROOT=${ROOT:A}
PY=/opt/homebrew/bin/python3
WORK=${TMPDIR:-/tmp}/kite-gates-$$
MEASURE_FILE=$WORK/measure.txt

# The watchdog.  GNU coreutils ships timeout as gtimeout on stock macOS.
watchdog=""
if command -v timeout > /dev/null 2>&1; then
  watchdog=timeout
elif command -v gtimeout > /dev/null 2>&1; then
  watchdog=gtimeout
fi

if [[ -z $watchdog ]]; then
  print -r -- "FAIL-WATCHDOG (no timeout or gtimeout on PATH)"
  print -r -- "GATES-FAIL"
  exit 1
fi

# The named tiers, in seconds.  A tier is a hang ceiling, not a budget:
# a leg that grows from one second to nine stays green at FAST and shows
# the growth in the MEASURE block.  These four lines hold every numeric
# watchdog literal in this file.
FAST=10
MED=30
SLOW=120
SUITE=300
# Includes the mandatory 306 second hidden aging period and six scenarios.
M1=600

# The fixture count of the PARSE leg.  D-B-27 pins the count EXACTLY at
# Stage B:  a short list is a FAIL and never a loose pass, so the leg
# tests equality and not a floor.  dev/run-stage-B.sh SB-G13 reads this
# same line, so the number lives in one place.
PARSE_FIXTURES=46

# gate_timed TIER NAME CMD...
# Runs one leg under the named tier, records the elapsed wall time in
# milliseconds, and forwards the leg's output and exit code unchanged.
# It adds no policy:  a green leg stays green and a red leg stays red.
gate_timed () {
  local tier=$1
  local name=$2
  shift 2
  local seconds=${(P)tier}
  local t0=$EPOCHREALTIME
  local out
  out=$("$watchdog" "$seconds" "$@" 2>&1)
  local code=$?
  local t1=$EPOCHREALTIME
  printf 'MEASURE %s tier=%s elapsed_ms=%.3f exit=%d\n' \
    "$name" "$tier" "$(( (t1 - t0) * 1000 ))" "$code" >> $MEASURE_FILE
  print -r -- "$out"
  return $code
}

# field LINE KEY:  the value of one key=value word of one printed line.
field () {
  print -r -- "$1" | awk -v k="$2" \
    '{ for (i = 1; i <= NF; i = i + 1) { if (index($i, k "=") == 1) { print substr($i, length(k) + 2) } } }'
}

# --- the leg bodies that need more than one command -------------------
#
# Each one prints its own PASS or FAIL line, because its verdict line
# carries a value or its output is a report.  The battery below runs them
# through the watchdog as "zsh dev/gates.sh --leg NAME".

# BUILD (brief 3.9).  The whole tree builds under the pinned switch with
# warnings as errors, and the leg passes on exit 0 with no output at all,
# so a warning that dune prints is a failure.
leg_build () {
  local out code
  out=$(zsh $ROOT/dev/pin-dune.sh dune build @all 2>&1)
  code=$?
  if [[ $code -eq 0 && -z $out ]]; then
    print -r -- "PASS BUILD"
    return 0
  fi
  print -r -- "build exit=$code"
  print -r -- "$out"
  print -r -- "FAIL BUILD"
  return 1
}

# HOUSE (brief 3.9).  The seven legs of the house rules, from
# dev/house.sh.
leg_house () {
  local out code
  out=$(zsh $ROOT/dev/house.sh $ROOT 2>&1)
  code=$?
  print -r -- "$out"
  if [[ $code -eq 0 ]] && print -r -- "$out" | rg -q -- '^HOUSE OK$'; then
    print -r -- "PASS HOUSE"
    return 0
  fi
  print -r -- "FAIL HOUSE"
  return 1
}

# PARSE (brief 3.9).  The leg builds first, so one leg alone is honest,
# then runs test/parse.exe over the round-trip fixtures, the positive
# fixtures, every twin of test/neg and the spine (D-B-27).  A list shorter than
# two entries is a failure, because an empty glob would otherwise pass
# with nothing checked.
leg_parse () {
  local out code line n
  out=$(zsh $ROOT/dev/pin-dune.sh dune build @all 2>&1)
  code=$?
  if [[ $code -ne 0 || -n $out ]]; then
    print -r -- "build exit=$code"
    print -r -- "$out"
    print -r -- "FAIL PARSE"
    return 1
  fi
  local files=(
    $ROOT/test/roundtrip/*.kite(N)
    $ROOT/test/pos/*.kite(N)
    $ROOT/test/neg/*.kite(N)
    $ROOT/examples/m0-spine.kite
  )
  if [[ ${#files} -lt 2 ]]; then
    print -r -- "parse fixtures=${#files}"
    print -r -- "FAIL PARSE"
    return 1
  fi
  out=$($ROOT/_build/default/test/parse.exe $files 2>&1)
  code=$?
  print -r -- "$out"
  line=$(print -r -- "$out" | rg -- '^PARSE files=')
  n=$(field "$line" files)
  if [[ $code -eq 0 && $n == $PARSE_FIXTURES ]]; then
    print -r -- "PASS PARSE fixtures=$n"
    return 0
  fi
  print -r -- "parse fixtures=${n:-0} want=$PARSE_FIXTURES"
  print -r -- "FAIL PARSE"
  return 1
}

# DENOMINATORS (brief 3.9, plan section 5).  The sidecar holds the
# record, the record holds every key, dev/denominators.sh re-measures the
# raw figure in this run, its DENOM corpus digest, file count and line
# count equal the tot_corpus keys, and its NUMSHA digest, line count and
# file count equal the kite_corpus keys.  The leg is never a timing gate:
# it reports the raw figure and gates the pins alone.
leg_denominators () {
  local json=$ROOT/dev/denominators.json
  local out code keys denom dline nline
  local have_sha have_files have_lines raw
  local num_sha num_lines num_files
  local want_sha want_files want_lines want_nsha want_nlines want_nfiles

  out=$(cd $ROOT/dev && shasum -a 256 -c DENOMINATORS.sha256 2>&1)
  code=$?
  if [[ $code -ne 0 || $out != "denominators.json: OK" ]]; then
    print -r -- "shasum exit=$code out=[$out]"
    print -r -- "FAIL DENOMINATORS"
    return 1
  fi
  print -r -- "$out"

  keys=$($PY -P -c 'import json, sys
d = json.load(open(sys.argv[1]))
top = ["date", "tot_pin", "tot_corpus", "raw_ocamlopt_ms_per_kloc",
       "kanon_ocamlopt_ms_per_kloc", "kanon_ocamlopt_ms_per_kloc_parallel",
       "kite_corpus", "ocaml_version", "dune_version", "method"]
inner = ["files", "lines", "sha256"]
miss = [k for k in top if k not in d]
miss = miss + ["tot_corpus." + k for k in inner if k not in d.get("tot_corpus", {})]
miss = miss + ["kite_corpus." + k for k in inner if k not in d.get("kite_corpus", {})]
print("KEYS OK" if not miss else "KEYS MISSING " + " ".join(miss))
print(d["tot_corpus"]["sha256"])
print(len(d["tot_corpus"]["files"]))
print(d["tot_corpus"]["lines"])
print(d["kite_corpus"]["sha256"])
print(d["kite_corpus"]["lines"])
print(len(d["kite_corpus"]["files"]))' $json 2>&1)
  if [[ $? -ne 0 ]]; then
    print -r -- "denominators.json unreadable out=[$keys]"
    print -r -- "FAIL DENOMINATORS"
    return 1
  fi
  local rows=(${(f)keys})
  if [[ $rows[1] != "KEYS OK" ]]; then
    print -r -- "$rows[1]"
    print -r -- "FAIL DENOMINATORS"
    return 1
  fi
  want_sha=$rows[2]
  want_files=$rows[3]
  want_lines=$rows[4]
  want_nsha=$rows[5]
  want_nlines=$rows[6]
  want_nfiles=$rows[7]

  denom=$(zsh $ROOT/dev/denominators.sh 2>&1)
  code=$?
  if [[ $code -ne 0 ]]; then
    print -r -- "denominators.sh exit=$code out=[$denom]"
    print -r -- "FAIL DENOMINATORS"
    return 1
  fi
  dline=$(print -r -- "$denom" | rg -- '^DENOM ')
  nline=$(print -r -- "$denom" | rg -- '^NUMSHA ')
  if [[ -z $dline || -z $nline ]]; then
    print -r -- "denominators.sh output=[$denom]"
    print -r -- "FAIL DENOMINATORS"
    return 1
  fi

  raw=$(field "$dline" raw_ms_per_kloc)
  have_sha=$(field "$dline" sha)
  have_files=$(field "$dline" files)
  have_lines=$(field "$dline" lines)
  num_sha=$(field "$nline" sha)
  num_lines=$(field "$nline" lines)
  num_files=$(field "$nline" files)

  if [[ $have_sha != $want_sha || $have_files != $want_files || $have_lines != $want_lines ]]; then
    print -r -- "denominator have sha=$have_sha files=$have_files lines=$have_lines"
    print -r -- "denominator want sha=$want_sha files=$want_files lines=$want_lines"
    print -r -- "FAIL DENOMINATORS"
    return 1
  fi
  if [[ $num_sha != $want_nsha || $num_lines != $want_nlines || $num_files != $want_nfiles ]]; then
    print -r -- "numerator have sha=$num_sha lines=$num_lines files=$num_files"
    print -r -- "numerator want sha=$want_nsha lines=$want_nlines files=$want_nfiles"
    print -r -- "FAIL DENOMINATORS"
    return 1
  fi

  print -r -- "$dline"
  print -r -- "$nline"
  print -r -- "PASS DENOMINATORS raw_ms_per_kloc=$raw"
  return 0
}

# CHECK (brief 3.9, D-B-26).  The leg builds first, so one leg alone is
# honest, then runs test/check.exe over the positive fixtures, the six
# Stage B twins and the spine.  A list shorter than two entries is a
# failure, because an empty glob would otherwise pass with nothing
# checked.  The name is CHECK and not SUITE-CHECK (D-B-26).
leg_check () {
  local out code line p q
  out=$(zsh $ROOT/dev/pin-dune.sh dune build @all 2>&1)
  code=$?
  if [[ $code -ne 0 || -n $out ]]; then
    print -r -- "build exit=$code"
    print -r -- "$out"
    print -r -- "FAIL CHECK"
    return 1
  fi
  local files=(
    $ROOT/test/pos/*.kite(N)
    $ROOT/test/neg/check-*.kite(N)
    $ROOT/test/neg/milestones.kite(N)
    $ROOT/examples/m0-spine.kite
  )
  if [[ ${#files} -lt 2 ]]; then
    print -r -- "check fixtures=${#files}"
    print -r -- "FAIL CHECK"
    return 1
  fi
  out=$($ROOT/_build/default/test/check.exe $files 2>&1)
  code=$?
  print -r -- "$out"
  line=$(print -r -- "$out" | rg -- '^CHECK files=')
  p=$(field "$line" pos)
  q=$(field "$line" neg)
  if [[ $code -ne 0 || ${p:-0} -lt 13 || ${q:-0} -lt 6 ]]; then
    print -r -- "FAIL CHECK"
    return 1
  fi
  out=$($ROOT/_build/default/test/regress.exe 2>&1)
  code=$?
  print -r -- "$out"
  if [[ $code -ne 0 ]] || ! print -r -- "$out" | rg -q '^REGRESS tests=[1-9][0-9]* ok=[1-9][0-9]* fail=0$'; then
    print -r -- "FAIL CHECK"
    return 1
  fi
  print -r -- "PASS CHECK positives=$p twins=$q"
  return 0
}

# RUNTIME checks both native suites.  An empty or failed suite cannot pass.
leg_runtime () {
  local out code suite line n ok bad
  out=$(zsh $ROOT/dev/pin-dune.sh dune build @all 2>&1)
  code=$?
  if [[ $code -ne 0 || -n $out ]]; then
    print -r -- "build exit=$code out=[$out]"
    print -r -- "FAIL RUNTIME"
    return 1
  fi
  for suite in cluster kubelet; do
    out=$($ROOT/_build/default/test/$suite.exe 2>&1)
    code=$?
    print -r -- "$out"
    line=$(print -r -- "$out" | rg "^RUNTIME suite=$suite tests=[1-9][0-9]* ok=[1-9][0-9]* fail=0$")
    n=$(field "$line" tests)
    ok=$(field "$line" ok)
    bad=$(field "$line" fail)
    if [[ $code -ne 0 || -z $line || $n != $ok || $bad != 0 ]]; then
      print -r -- "FAIL RUNTIME"
      return 1
    fi
  done
  print -r -- "PASS RUNTIME"
  return 0
}

leg_source () {
  local out code line n ok bad
  out=$(zsh $ROOT/dev/pin-dune.sh dune build bin/kite.exe test/eval_test.exe browser/program.bc.js 2>&1)
  code=$?
  if [[ $code -ne 0 ]]; then
    print -r -- "$out"
    print -r -- "FAIL SOURCE"
    return 1
  fi
  out=$($ROOT/_build/default/test/eval_test.exe 2>&1)
  code=$?
  print -r -- "$out"
  line=$(print -r -- "$out" | rg '^RUNTIME suite=eval ')
  n=$(field "$line" tests)
  ok=$(field "$line" ok)
  bad=$(field "$line" fail)
  if [[ $code -ne 0 || -z $line || $n != $ok || $bad != 0 || ${n:-0} -lt 32 ]]; then
    print -r -- "FAIL SOURCE"
    return 1
  fi
  out=$(node --test --test-reporter=tap $ROOT/test/program.test.mjs 2>&1)
  code=$?
  print -r -- "$out"
  if [[ $code -ne 0 ]]; then print -r -- "FAIL SOURCE"; return 1; fi
  print -r -- "EXECUTION-LINES evaluator=$(wc -l < $ROOT/runtime/eval.ml | tr -d ' ') encoder=$(wc -l < $ROOT/runtime/artifact.ml | tr -d ' ') bridge=$(wc -l < $ROOT/browser/program.ml | tr -d ' ')"
  print -r -- "PASS SOURCE"
  return 0
}

# Browser state races and actual Workers, Web Locks and IndexedDB.
leg_browser () {
  local out code
  out=$($PY $ROOT/dev/browser-audit.py 2>&1)
  code=$?
  print -r -- "$out"
  if [[ $code -ne 0 ]]; then print -r -- "FAIL BROWSER"; return 1; fi
  out=$($PY $ROOT/test/browser-audit.test.py 2>&1)
  code=$?
  print -r -- "$out"
  if [[ $code -ne 0 ]]; then print -r -- "FAIL BROWSER"; return 1; fi
  out=$(node --test --test-reporter=tap $ROOT/test/glue.test.mjs $ROOT/test/node-host.test.mjs $ROOT/test/control.test.mjs $ROOT/test/source.test.mjs $ROOT/test/acceptance-bridge-test.mjs 2>&1)
  code=$?
  print -r -- "$out"
  if [[ $code -ne 0 ]]; then print -r -- "FAIL BROWSER"; return 1; fi
  out=$(node $ROOT/dev/browser-test.mjs 2>&1)
  code=$?
  print -r -- "$out"
  if [[ $code -eq 0 ]] && print -r -- "$out" | rg -q '^BROWSER-OK$'; then
    print -r -- "PASS BROWSER"
    return 0
  fi
  print -r -- "FAIL BROWSER"
  return 1
}

# The source corpus controls every scenario. Quick mode cannot satisfy this leg.
leg_acceptance () {
  local out code
  out=$($ROOT/_build/default/bin/kite.exe build $ROOT/test/acceptance.kite 2>&1)
  code=$?
  print -r -- "$out"
  if [[ $code -ne 0 ]]; then print -r -- "FAIL ACCEPTANCE"; return 1; fi
  out=$(node $ROOT/dev/drive.mjs 2>&1)
  code=$?
  print -r -- "$out"
  if [[ $code -eq 0 ]] && print -r -- "$out" | rg -q '^M1-OK behaviors=6 hidden-threshold-ms=306000 pod-work-limit-ms=3000 leader-view-limit-ms=5000$'; then
    print -r -- "PASS ACCEPTANCE"
    return 0
  fi
  print -r -- "FAIL ACCEPTANCE"
  return 1
}

# TRUSTED-LINES retains the eight M0 elaborator files and 2,400-line bound.
# Under --require an absent elaborator is a failure (D-B-28, D-B-32).
leg_trusted_lines () {
  local out code
  out=$(zsh $ROOT/dev/trusted-lines.sh --require $ROOT 2>&1)
  code=$?
  print -r -- "$out"
  if [[ $code -eq 0 ]] && print -r -- "$out" | rg -q -- '^TRUSTED-LINES elaborator=[0-9]+/2400 OK$'; then
    print -r -- "PASS TRUSTED-LINES"
    return 0
  fi
  print -r -- "FAIL TRUSTED-LINES"
  return 1
}

# FLOOR, GATE M0 (brief 3.17, M0-PLAN.md:98-109).  The leg is the R3
# speed gate:  the whole pipeline of the numerator corpus per kloc
# against raw ocamlopt -c over the frozen floor corpus per kloc, both
# re-measured in this run.  The leg PRINTS the host load and it NEVER
# moves the bound (D-B-25).
FLOOR_PIN=/Users/oobi/Documents/affine-lang-tot-pin

# The load average, read by uptime.  sysctl -n vm.loadavg is denied in a
# sandboxed agent shell, so it is the fallback and never the first
# reader (brief section 2).
floor_load () {
  if command -v uptime > /dev/null 2>&1; then
    uptime | awk '{ n = split($0, a, ":");  s = a[n];  split(s, b, " ");  v = b[1];  gsub(/,/, "", v);  print v }'
  else
    sysctl -n vm.loadavg | awk '{ print $2 }'
  fi
}

# The median of one bench.sh line.
floor_median () {
  print -r -- "$1" | awk '{ for (i = 1; i <= NF; i = i + 1) { if (index($i, "median_ms=") == 1) { print substr($i, 11) } } }'
}

# One measured block:  the minute and the load before, five pipeline
# runs, five floor runs, then the minute and the load after.  It prints
# one line of six fields joined by a bar, and it removes the copy it
# made (D-M0-4).
floor_measure () {
  local copy=${TMPDIR:-/tmp}/kite-floor-$$
  local m1 m2 l1 l2 pipe flo out
  rm -rf $copy
  mkdir -p $copy || return 9
  cp $FLOOR_PATHS $copy/ || { rm -rf $copy;  return 9 }
  local compile_args=(zsh $ROOT/dev/pin-dune.sh -C $copy ocamlfind ocamlopt -c -package str $FLOOR_NAMES)
  local compile_quoted=("${(@q)compile_args}")
  local compile="${(j: :)compile_quoted}"
  local pipe_args=(zsh $ROOT/dev/browser-pipeline.sh $ROOT/examples/m0-spine.kite)
  local pipe_quoted=("${(@q)pipe_args}")
  local pipeline="${(j: :)pipe_quoted}"
  export RUNS=5
  l1=$(floor_load)
  m1=$(date -u +%Y-%m-%dT%H:%M)
  out=$(zsh $ROOT/dev/bench.sh pipeline "$pipeline" 2>&1)
  if [[ $? -ne 0 ]]; then
    rm -rf $copy
    print -r -- "BENCH-PIPELINE [$out]"
    return 9
  fi
  pipe=$(floor_median "$out")
  out=$(zsh $ROOT/dev/bench.sh floor "$compile" 2>&1)
  if [[ $? -ne 0 ]]; then
    rm -rf $copy
    print -r -- "BENCH-FLOOR [$out]"
    return 9
  fi
  flo=$(floor_median "$out")
  m2=$(date -u +%Y-%m-%dT%H:%M)
  l2=$(floor_load)
  rm -rf $copy
  print -r -- "$m1|$m2|$pipe|$flo|$l1|$l2"
  return 0
}

leg_floor () {
  local spine=$ROOT/examples/m0-spine.kite
  local out code s
  local -a cards
  cards=($ROOT/examples/m0-spine.sha256 $ROOT/examples/m0-spine.lines
         $ROOT/dev/floor-corpus.sha256 $ROOT/dev/floor-corpus.lines
         $ROOT/dev/floor-corpus.txt $spine)
  for s in $cards; do
    if [[ -f $s ]]; then : ; else
      print -r -- "floor sidecar detail=absent $s"
      print -r -- "GATE-FAIL floor sidecar missing"
      print -r -- "FAIL FLOOR"
      return 1
    fi
  done
  out=$(cd $ROOT/examples && shasum -a 256 -c m0-spine.sha256 2>&1)
  if [[ $? -ne 0 ]]; then
    print -r -- "floor sidecar detail=[$out]"
    print -r -- "GATE-FAIL floor sidecar missing"
    print -r -- "FAIL FLOOR"
    return 1
  fi
  print -r -- "$out"
  out=$(cd $ROOT/dev && shasum -a 256 -c floor-corpus.sha256 2>&1)
  if [[ $? -ne 0 ]]; then
    print -r -- "floor sidecar detail=[$out]"
    print -r -- "GATE-FAIL floor sidecar missing"
    print -r -- "FAIL FLOOR"
    return 1
  fi
  print -r -- "$out"

  FLOOR_NAMES=(${(f)"$(cat $ROOT/dev/floor-corpus.txt)"})
  FLOOR_PATHS=()
  for s in $FLOOR_NAMES; do
    if [[ -f $FLOOR_PIN/lib/$s ]]; then
      FLOOR_PATHS+=($FLOOR_PIN/lib/$s)
    else
      print -r -- "floor sidecar detail=absent $FLOOR_PIN/lib/$s"
      print -r -- "GATE-FAIL floor sidecar missing"
      print -r -- "FAIL FLOOR"
      return 1
    fi
  done

  local num_lines flo_lines want_num want_flo num_sha flo_sha
  num_lines=$(wc -l < $spine | tr -d ' ')
  flo_lines=$(cat $FLOOR_PATHS | wc -l | tr -d ' ')
  want_num=$(cat $ROOT/examples/m0-spine.lines | tr -d ' \n')
  want_flo=$(cat $ROOT/dev/floor-corpus.lines | tr -d ' \n')
  if [[ $num_lines != $want_num || $flo_lines != $want_flo ]]; then
    print -r -- "floor sidecar detail=lines have=$num_lines/$flo_lines want=$want_num/$want_flo"
    print -r -- "GATE-FAIL floor sidecar missing"
    print -r -- "FAIL FLOOR"
    return 1
  fi
  num_sha=$(awk '{ print $1 }' $ROOT/examples/m0-spine.sha256)
  flo_sha=$(cat $FLOOR_PATHS | shasum -a 256 | awk '{ print $1 }')

  local num_kloc flo_kloc sized
  num_kloc=$(awk -v n="$num_lines" 'BEGIN { printf "%.3f\n", n / 1000 }')
  flo_kloc=$(awk -v n="$flo_lines" 'BEGIN { printf "%.3f\n", n / 1000 }')
  sized=$(awk -v a="$num_kloc" -v b="$flo_kloc" 'BEGIN { print (b > 2 * a || b < a / 2) ? "no" : "yes" }')
  if [[ $sized != "yes" ]]; then
    print -r -- "GATE-FAIL floor size num_kloc=$num_kloc flo_kloc=$flo_kloc"
    print -r -- "FAIL FLOOR"
    return 1
  fi

  out=$(zsh $ROOT/dev/pin-dune.sh dune build @all 2>&1)
  code=$?
  if [[ $code -ne 0 ]]; then
    print -r -- "build exit=$code out=[$out]"
    print -r -- "FAIL FLOOR"
    return 1
  fi

  local block m1 m2 pipe flo l1 l2
  block=$(floor_measure)
  if [[ $? -ne 0 ]]; then
    print -r -- "floor measure detail=[$block]"
    print -r -- "FAIL FLOOR"
    return 1
  fi
  local -a f
  f=(${(s:|:)block})
  m1=$f[1];  m2=$f[2];  pipe=$f[3];  flo=$f[4];  l1=$f[5];  l2=$f[6]
  if [[ $m1 != $m2 ]]; then
    block=$(floor_measure)
    if [[ $? -ne 0 ]]; then
      print -r -- "floor measure detail=[$block]"
      print -r -- "FAIL FLOOR"
      return 1
    fi
    f=(${(s:|:)block})
    m1=$f[1];  m2=$f[2];  pipe=$f[3];  flo=$f[4];  l1=$f[5];  l2=$f[6]
    if [[ $m1 != $m2 ]]; then
      print -r -- "GATE-FAIL floor minute crossed twice"
      print -r -- "FAIL FLOOR"
      return 1
    fi
  fi

  local pipe_per flo_per pass
  pipe_per=$(awk -v m="$pipe" -v k="$num_kloc" 'BEGIN { printf "%.3f\n", (k + 0 > 0) ? m / k : 0 }')
  flo_per=$(awk -v m="$flo" -v k="$flo_kloc" 'BEGIN { printf "%.3f\n", (k + 0 > 0) ? m / k : 0 }')
  print -r -- "FLOOR pipeline_ms_per_kloc=$pipe_per floor_ms_per_kloc=$flo_per num_sha=$num_sha flo_sha=$flo_sha num_kloc=$num_kloc flo_kloc=$flo_kloc host=$(hostname) arch=$(uname -m) load_before=$l1 load_after=$l2 minute_before=$m1 minute_after=$m2"
  print -r -- "DENOM-FROZEN kanon_serial=1641.599 kanon_parallel=712.803"
  print -r -- "PIPELINE includes=check,lower,source-artifact,js_of_ocaml-control,js_of_ocaml-evaluator,browser-assets"
  print -r -- "WASMGC-ONLY not measured, M1 retains the fixed Stage 0 Wasm workload"
  pass=$(awk -v a="$pipe_per" -v b="$flo_per" 'BEGIN { print (a <= b) ? "yes" : "no" }')
  if [[ $pass == "yes" ]]; then
    print -r -- "GATE-OK"
    print -r -- "PASS FLOOR"
    return 0
  fi
  print -r -- "GATE-FAIL"
  print -r -- "FAIL FLOOR"
  return 1
}

# One leg alone, which is how the watchdog reaches a leg body.  A leg
# body writes nothing under $WORK:  gate_timed alone writes the MEASURE
# file, and gate_timed runs only in the battery below.  The work
# directory is therefore made after this dispatch, so a --leg run leaves
# no directory behind.
if [[ $# -ge 2 && $1 == "--leg" ]]; then
  case $2 in
    build) leg_build; exit $? ;;
    house) leg_house; exit $? ;;
    parse) leg_parse; exit $? ;;
    check) leg_check; exit $? ;;
    runtime) leg_runtime; exit $? ;;
    source) leg_source; exit $? ;;
    browser) leg_browser; exit $? ;;
    acceptance) leg_acceptance; exit $? ;;
    trusted-lines) leg_trusted_lines; exit $? ;;
    denominators) leg_denominators; exit $? ;;
    floor) leg_floor; exit $? ;;
    *) print -r -- "gates: unknown leg $2"; exit 64 ;;
  esac
fi

if [[ $# -ne 0 ]]; then
  print -r -- "usage: zsh dev/gates.sh [--leg NAME]"
  exit 64
fi

mkdir -p $WORK || exit 9
: > $MEASURE_FILE || exit 9
fail=0

# Line 1 names the tree and line 2 carries the frozen kanon denominators.
# Both figures come from the sidecar and neither is ever gated.
print -r -- "GATES kite stage=M1-C root=$ROOT"
print -r -- "KANON-DENOM serial_ms=$($PY -P -c 'import json, sys
d = json.load(open(sys.argv[1]))
print(d["kanon_ocamlopt_ms_per_kloc"])' $ROOT/dev/denominators.json) parallel_ms=$($PY -P -c 'import json, sys
d = json.load(open(sys.argv[1]))
print(d["kanon_ocamlopt_ms_per_kloc_parallel"])' $ROOT/dev/denominators.json)"

# leg TIER NAME ORACLE CMD...
#   ORACLE is a ripgrep pattern that the leg's output must hold when the
#   leg exits 0.  The word SELF means the leg prints its own verdict
#   line, because that line carries a value, and its whole output belongs
#   on stdout.
leg () {
  local tier=$1
  local name=$2
  local oracle=$3
  shift 3
  local out code
  out=$(gate_timed $tier $name "$@")
  code=$?
  if [[ $oracle == "SELF" ]]; then
    print -r -- "$out"
    if [[ $code -eq 0 ]]; then
      return 0
    fi
    if ! print -r -- "$out" | rg -q -- "^FAIL $name"; then
      print -r -- "FAIL $name"
    fi
    fail=1
    return 1
  fi
  if [[ $code -eq 0 ]] && print -r -- "$out" | rg -q -- "$oracle"; then
    print -r -- "PASS $name"
    return 0
  fi
  print -r -- "FAIL $name"
  print -r -- "$out"
  fail=1
  return 1
}

# The M0 legs retain their order, with RUNTIME and BROWSER after CHECK.
# Every leg runs even when an earlier one failed.
leg MED BUILD SELF zsh $SELF --leg build
leg FAST HOUSE SELF zsh $SELF --leg house
leg MED PARSE SELF zsh $SELF --leg parse
leg MED CHECK SELF zsh $SELF --leg check
leg MED RUNTIME SELF zsh $SELF --leg runtime
leg MED SOURCE SELF zsh $SELF --leg source
leg SLOW BROWSER SELF zsh $SELF --leg browser
leg M1 ACCEPTANCE SELF zsh $SELF --leg acceptance
leg FAST TRUSTED-LINES SELF zsh $SELF --leg trusted-lines
leg SLOW DENOMINATORS SELF zsh $SELF --leg denominators
leg SUITE FLOOR SELF zsh $SELF --leg floor

print -r -- ""
cat $MEASURE_FILE
print -r -- ""

rm -rf $WORK

if [[ $fail -eq 0 ]]; then
  print -r -- "GATES-OK"
  exit 0
fi
print -r -- "GATES-FAIL"
exit 1
