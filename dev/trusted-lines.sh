#!/bin/zsh
# dev/trusted-lines.sh [--require] [ROOT]
# The TRUSTED-LINES leg of the gate battery (M0-PLAN.md:135 and :167).
# Example:
#   zsh /Users/oobi/Documents/kite/dev/trusted-lines.sh
#
# The trusted base of M0 is the believed elaborator of plan section 8:
# types.ml, row.ml, unify.ml, infer.ml, usage.ml, iface.ml, ir.ml and
# lower.ml, held at 2,400 lines together by D-M0-5.  A bug in one of the
# eight is a wrong program accepted.  lexer.ml, parser.ml and print.ml
# are NOT believed, because the PARSE gate re-checks them, so they are
# not in the list.
#
# The line prints the count against the bound:
#   TRUSTED-LINES elaborator=0/2400 OK
#
# A file that does not exist counts as zero lines, so the leg runs on a
# tree that does not hold the file yet.  At Stage A none of the eight
# exists, so the leg prints 0/2400 OK.  Under --require a missing file
# FAILS instead;  Stage B passes --require once the eight files exist.
#
# The root comes from this script's own path when no argument is given,
# so a copy of the repository under a scratch directory measures itself.
# wc and awk do the reading.
#
# The gate battery of Stage A does not call this script:  the
# TRUSTED-LINES leg arrives at Stage B (brief 3.10).
#
# ADAPTED from /Users/oobi/Documents/brisk/dev/trusted-lines.sh (100
# lines).  The self-location, the wc reading, the sum_lines helper, the
# --require flag and the output line shape are unchanged.  The brisk core
# and vm lists become one kite elaborator list of the eight files of plan
# section 8 with the single bound 2400, so the line names one count.

set -u

# The user shell startup files add a chpwd hook that reads an unset
# parameter.  Under set -u that hook fails, so the hooks are cleared.
chpwd_functions=()
unfunction chpwd 2>/dev/null

require=0
if [[ ${1:-} == "--require" ]]; then
  require=1
  shift
fi

root=${1:-${0:A:h:h}}

elab_bound=2400

elab_files=(
  $root/lib/types.ml
  $root/lib/row.ml
  $root/lib/unify.ml
  $root/lib/infer.ml
  $root/lib/usage.ml
  $root/lib/iface.ml
  $root/lib/ir.ml
  $root/lib/lower.ml
)

missing=()
for f in $elab_files; do
  [[ -f $f ]] || missing+=($f)
done

# wc -l over one file at a time, so a missing file contributes zero.
sum_lines () {
  local f total=0 n
  for f in "$@"; do
    n=0
    [[ -f $f ]] && n=$(wc -l < $f | awk '{ print $1 }')
    total=$(( total + n ))
  done
  print -r -- $total
}

elab=$(sum_lines $elab_files)

line="TRUSTED-LINES elaborator=$elab/$elab_bound"

if [[ $require == 1 && ${#missing} -gt 0 ]]; then
  print -r -- "trusted-lines: --require and a trusted file is missing under $root"
  print -r -- "${missing[@]}"
  print -r -- "$line FAIL"
  exit 1
fi

if [[ $elab -le $elab_bound ]]; then
  print -r -- "$line OK"
  exit 0
fi

print -r -- "$line FAIL"
exit 1
