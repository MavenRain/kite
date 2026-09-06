#!/bin/zsh
# dev/denominators.sh
# Re-measures the raw ocamlopt denominator inside every gate run, and
# takes a fresh digest of the numerator corpus.  Example:
#   zsh /Users/oobi/Documents/kite/dev/denominators.sh
#
# Method, fixed by M0-PLAN.md section 5:
#   1.  Read dev/denominators.json.
#   2.  List the pin corpus, PIN/lib/*.ml and PIN/lib/*.mli, as bare file
#       names under LC_ALL=C sort.  Hold the file count, the wc -l total
#       and the sha256 of the concatenation of the files in that order
#       against the tot_corpus keys.  A mismatch prints DENOM-ERROR with
#       both values and exits 3, before any copy.
#   3.  Copy the files to $TMPDIR/kite-denom-$$ and order the copy with
#       ocamldep -sort through dev/pin-dune.sh.  The pin is read, never
#       built in place.
#   4.  Warm the .cmi files with one untimed pass, then time five runs of
#       the same command through dev/bench.sh.  A non-zero exit prints
#       DENOM-ERROR and exits 4.
#   5.  Remove the copy and print exactly two lines:
#       DENOM raw_ms_per_kloc=.. median_ms=.. lines=.. files=.. sha=..
#       NUMSHA sha=.. lines=.. files=..
#
# The NUMSHA line is a fresh sha256 of examples/m0-spine.kite taken in
# this run, so the numerator pin is checked by the file and not by its
# own record.  At Stage A the spine is a placeholder that holds no
# declaration, and Stage B replaces it with the 1 kloc spine.
#
# ADAPTED from /Users/oobi/Documents/brisk/dev/denominators.sh (131
# lines).  The five steps, the frozen-record check, the scratch copy, the
# ocamldep order, the warm-up, the bench call and the two output lines
# are unchanged.  The paths become the kite paths, the brisk_corpus key
# becomes kite_corpus, the spine is examples/m0-spine.kite, the copy is
# $TMPDIR/kite-denom-$$ and the bench sidecar variable is
# KITE_DENOM_BENCH.

set -u

# The user shell startup files add a chpwd hook that reads an unset
# parameter.  Under set -u that hook fails, so the hooks are cleared.
chpwd_functions=()
unfunction chpwd 2>/dev/null

ROOT=${0:A:h:h}
JSON=$ROOT/dev/denominators.json
SPINE=$ROOT/examples/m0-spine.kite
PIN=/Users/oobi/Documents/affine-lang-tot-pin
PY=/opt/homebrew/bin/python3

COPY=""

cleanup () {
  [[ -n $COPY && -d $COPY ]] && rm -rf $COPY
  return 0
}

die () {
  cleanup
  print -r -- "DENOM-ERROR $1"
  exit $2
}

# --- 1  the frozen record ---------------------------------------------
meta=$($PY -P -c 'import json, sys
d = json.load(open(sys.argv[1]))
t = d["tot_corpus"]
b = d["kite_corpus"]
print(len(t["files"]))
print(t["lines"])
print(t["sha256"])
print(len(b["files"]))
print(b["lines"])
print(b["sha256"])
print("\n".join(t["files"]))' $JSON 2>&1)
[[ $? -eq 0 ]] || die "denominators.json unreadable out=[$meta]" 3

meta_rows=(${(f)meta})
want_files=$meta_rows[1]
want_lines=$meta_rows[2]
want_sha=$meta_rows[3]
want_nfiles=$meta_rows[4]
want_nlines=$meta_rows[5]
want_nsha=$meta_rows[6]
want_names=(${meta_rows[7,-1]})

# --- 2  the corpus on disk --------------------------------------------
paths=(${(f)"$(/bin/ls -1 $PIN/lib/*.ml $PIN/lib/*.mli | LC_ALL=C sort)"})
names=(${paths:t})
have_files=${#paths}
have_lines=$(wc -l $paths | tail -1 | awk '{ print $1 }')
have_sha=$(cat $paths | shasum -a 256 | awk '{ print $1 }')

[[ $have_files == $want_files ]] || die "files have=$have_files want=$want_files" 3
[[ "$names" == "$want_names" ]] || die "names have=[$names] want=[$want_names]" 3
[[ $have_lines == $want_lines ]] || die "lines have=$have_lines want=$want_lines" 3
[[ $have_sha == $want_sha ]] || die "sha have=$have_sha want=$want_sha" 3

# --- 3  the scratch copy and its build order ---------------------------
COPY=${TMPDIR:-/tmp}/kite-denom-$$
mkdir -p $COPY || die "mkdir $COPY failed" 4
cp $paths $COPY/ || die "copy to $COPY failed" 4

order=$(zsh $ROOT/dev/pin-dune.sh -C $COPY ocamldep -sort $names 2>&1)
[[ $? -eq 0 ]] || die "ocamldep -sort exit out=[$order]" 4
sorted=(${=order})
[[ ${#sorted} -eq $have_files ]] || die "ocamldep -sort returned ${#sorted} of $have_files" 4

# --- 4  the warm-up and the five timed runs ----------------------------
export RUNS=5
compile_args=(zsh $ROOT/dev/pin-dune.sh -C $COPY ocamlfind ocamlopt -c -package str $sorted)
quoted_args=("${(@q)compile_args}")
compile="${(j: :)quoted_args}"

warm=$(/bin/zsh -f -c "$compile" 2>&1)
[[ $? -eq 0 ]] || die "warm compile out=[$warm]" 4

bench=$(zsh $ROOT/dev/bench.sh raw_ocamlopt "$compile" 2>&1)
[[ $? -eq 0 ]] || die "bench out=[$bench]" 4

median=$(print -r -- "$bench" | awk '{ for (i = 1; i <= NF; i = i + 1) { if (index($i, "median_ms=") == 1) { print substr($i, 11) } } }')
[[ -n $median ]] || die "bench line without a median out=[$bench]" 4

# The bench line carries the min and the max, which the build log
# records.  It leaves stdout clean:  a caller that wants it names a file.
[[ -n ${KITE_DENOM_BENCH:-} ]] && print -r -- "$bench" > $KITE_DENOM_BENCH

raw=$(awk -v m="$median" -v l="$have_lines" 'BEGIN { printf "%.3f\n", (l + 0 > 0) ? (m + 0) / ((l + 0) / 1000) : 0 }')

# --- 5  the numerator digest and the two lines -------------------------
num_sha=$(shasum -a 256 $SPINE | awk '{ print $1 }')
num_lines=$(wc -l < $SPINE | awk '{ print $1 }')

[[ $num_lines == $want_nlines ]] || die "spine lines have=$num_lines want=$want_nlines" 3
[[ $num_sha == $want_nsha ]] || die "spine sha have=$num_sha want=$want_nsha" 3
[[ $want_nfiles == 1 ]] || die "kite_corpus holds $want_nfiles files and not 1" 3

cleanup

print -r -- "DENOM raw_ms_per_kloc=$raw median_ms=$median lines=$have_lines files=$have_files sha=$have_sha"
print -r -- "NUMSHA sha=$num_sha lines=$num_lines files=1"
exit 0
