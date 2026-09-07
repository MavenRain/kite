#!/bin/zsh
# dev/house.sh:  the HOUSE gate as one command.
#
# Usage:  zsh /Users/oobi/Documents/kite/dev/house.sh [ROOT]
#
# The gate has seven legs over the house rules of the Stage A brief 3.12
# and of M0-PLAN.md section 9.  Each leg prints HOUSE NAME OK, or HOUSE
# NAME FAIL and its hits.  The script then prints HOUSE OK and exits 0,
# or HOUSE FAIL and exits 1.
#
# The em-dash leg keeps the kanon note:  ripgrep on this machine does not
# honor the glob form '!vendor/**', so the leg writes both '!vendor' and
# '!**/vendor/**'.  The pattern is the octal byte escape \342\200\224 of
# the character, so the file that counts the character holds none of it.
#
# A source directory that does not exist is left out of the argument
# list, so ripgrep never reads a missing path.  At the first half of
# Stage A test/ does not exist, so its legs search lib/ and surface/.
#
# Leg 4 reads an OCaml loop HEADER and not a bare word, because the kite
# keyword list holds the iteration word as a language keyword (D-A-23).
# Leg 6 bans the raw index forms of brief 3.12, that is `.(`, `.[` and
# the Array accessors, as well as the partial list accessors.  It does
# NOT ban String.get and String.sub, because brief 3.12 does not ban
# them:  the leg now reads the brief and nothing more (D-A-25).
#
# Legs 1 to 6 read lib/, surface/, runtime/, test/ and bin/, including
# .ml sources and .mli interfaces (D-A-32, M1-A).  bin/ joins at the fix round
# of review 1:  the driver is OCaml code, so it holds to the OCaml rules.
# The rules of brief 3.12 are rules about OCaml code, and test/ holds
# kite fixtures and their goldens:  a fixture writes a wildcard pattern,
# a division and the words true and false as kite text, and reading them
# as OCaml would fail the gate on the language the gate exists to parse.
# Leg 7 keeps the whole tree, because the em-dash rule is a text rule.
#
# ADAPTED from /Users/oobi/Documents/brisk/dev/house.sh (131 lines).  The
# leg shape, the report_empty helper, the dirs_of and search helpers and
# the em-dash globs are unchanged.  The brisk directory lists become lib,
# surface, test and bin;  the brisk disclosed mutable window is dropped,
# because kite discloses none;  three legs are new:  no-option-match,
# no-bare-division and the raw index and sub members of leg 2.

set -u

# The user shell startup files add a chpwd hook that reads an unset
# parameter.  Under set -u that hook fails, so the hooks are cleared.
chpwd_functions=()
unfunction chpwd 2>/dev/null

root=${1:-${0:A:h:h}}
fail=0

emdash=$(printf '\342\200\224')
pat_exn='\braise\b|\bfailwith\b|\bassert\b|\bexception\b'
pat_try='\btry\b'
pat_partial='\|[[:space:]]*_[[:space:]]*->|List\.nth|List\.hd|List\.tl|\.\(|\.\[|Array\.get|Array\.set'
pat_state='\bref\b|\bmutable\b|Array\.|Hashtbl|Buffer\.'
pat_loop='true ->|false ->|\bwhile\b|\bfor[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*='
pat_optmatch='\|[[:space:]]*(Some|None|Ok|Error)[[:space:](]'
pat_div='[A-Za-z0-9_)\]] +/ +[A-Za-z0-9_(\[]'

report_empty () {
  local name=$1 out=$2
  if [[ -z $out ]]; then
    print -r -- "HOUSE $name OK"
  else
    print -r -- "HOUSE $name FAIL"
    print -r -- "$out"
    fail=1
  fi
}

# The directories that exist, in the order of the plan.
dirs_of () {
  local d out=()
  for d in "$@"; do
    [[ -d $d ]] && out+=($d)
  done
  print -rl -- "${out[@]}"
}

# Keep search errors in the captured report, even if rg emits no
# diagnostic.  Only exit 1 means that a successful search found no match.
search () {
  local out code
  out=$(rg "$@" 2>&1)
  code=$?
  [[ -n $out ]] && print -r -- "$out"
  if [[ $code -gt 1 ]]; then
    print -r -- "HOUSE SEARCH-ERROR exit=$code"
    return $code
  fi
  return 0
}

hits () {
  local pat=$1
  shift
  [[ $# -eq 0 ]] && return 0
  search -n -U --glob '*.ml' --glob '*.mli' -- $pat "$@"
}

# Leg 3 over test/ and bin/, with the one disclosed spelling of D-A-33
# taken out of the report.  The filter names the whole spelling, so any
# other use of the Array module in those directories still fails the leg.
hits_state_test () {
  [[ $# -eq 0 ]] && return 0
  local out
  out=$(rg -n -U --glob '*.ml' -- $pat_state "$@" 2>&1 \
    | rg -v -- 'Array\.to_list Sys\.argv')
  [[ -n $out ]] && print -r -- "$out"
  return 0
}

all_dirs=(${(f)"$(dirs_of $root/lib $root/surface $root/runtime $root/test $root/bin $root/browser)"})
core_dirs=(${(f)"$(dirs_of $root/lib $root/surface $root/runtime)"})
test_dirs=(${(f)"$(dirs_of $root/test)"})
bin_dirs=(${(f)"$(dirs_of $root/bin)"})

# Leg 1:  no exception anywhere in the tree.
leg1=$(hits $pat_exn $all_dirs; hits $pat_try $all_dirs)
report_empty "no-exception" "$leg1"

# Leg 2:  no wildcard arm, no partial list accessor, no raw index and no
# raw sub.  Every index goes through a total combinator.
leg2=$(hits $pat_partial $all_dirs)
report_empty "no-wildcard-no-partial" "$leg2"

# Leg 3:  no mutable state.  lib/ holds the rule and surface/, test/ and
# bin/ hold to it by choice (brief 3.12).  test/ and bin/ ride their own
# search, because argv is an array and Array.to_list Sys.argv is the one
# spelling that reads it (D-A-33).
# Only these two whole FFI conversion lines may name Array in either bridge.
hits_state_browser () {
  local out
  out=$(hits $pat_state $root/browser)
  print -r -- "$out" | rg -v \
    '/browser/(model|program).ml:[0-9]+:[[:space:]]*(traverse parser \(Array.to_list \(Js.to_array \(J.coerce value\)\)\)|J.inject \(Js.array \(Array.of_list \(List.map render values\)\)\))$'
}
leg3=$(hits $pat_state $core_dirs; hits_state_test $test_dirs $bin_dirs; hits_state_browser)
report_empty "no-mutable-state" "$leg3"

# Leg 4:  no bool match and no loop keyword.
leg4=$(hits $pat_loop $all_dirs)
report_empty "no-bool-match-no-loop" "$leg4"

# Leg 5:  option and result through fold, map and bind, never a match.
leg5=$(hits $pat_optmatch $all_dirs)
report_empty "no-option-match" "$leg5"

# Leg 6:  no bare division.  A division goes through a total helper that
# holds the zero case.
leg6=$(hits $pat_div $all_dirs)
report_empty "no-bare-division" "$leg6"

# Leg 7:  no em-dash outside the build tree and .git.
leg7=$(search -n \
  --glob '!vendor' --glob '!**/vendor/**' \
  --glob '!_build' --glob '!**/_build/**' \
  --glob '!.git' \
  -e $emdash $root)
report_empty "no-em-dash" "$leg7"

if [[ $fail == 0 ]]; then
  print -r -- "HOUSE OK"
  exit 0
fi
print -r -- "HOUSE FAIL"
exit 1
