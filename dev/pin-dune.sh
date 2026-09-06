#!/bin/zsh
# dev/pin-dune.sh [-C DIR] CMD [ARGS...]
# Runs CMD with the ctxcat-ocaml opam switch first on PATH, so every dune,
# ocamlfind, ocamldep and ocamlopt call of every stage reads OCaml 5.3.0,
# dune 3.24.0 and no third-party package.  Examples:
#   zsh /Users/oobi/Documents/kite/dev/pin-dune.sh dune build @all
#   zsh /Users/oobi/Documents/kite/dev/pin-dune.sh -C /tmp/copy ocamlfind ocamlopt -c a.ml
#
# The runner never cds into a read-only sibling tree (M0-PLAN.md:151).  The
# switch is the only thing it pins;  the corpus it measures is the scratch
# copy that dev/denominators.sh makes.  Without -C it works in the
# repository root, which it takes from its own path.
#
# ADAPTED from /Users/oobi/Documents/brisk/dev/pin-dune.sh (44 lines).
# The chpwd guard, the -C option and the free command are unchanged.  One
# line changes:  the exported PATH names the ctxcat-ocaml switch.

set -u

# The user shell startup files add a chpwd hook that reads an unset
# parameter.  Under set -u that hook fails and cd inherits its non-zero
# status, so the hooks are cleared before the cd.  Timing stays honest:
# no hook runs in a timed call.
chpwd_functions=()
unfunction chpwd 2>/dev/null

usage () {
  print -r -- "PIN-DUNE-USAGE pin-dune.sh [-C DIR] CMD [ARGS...]"
  exit 2
}

workdir=${0:A:h:h}

if [[ ${1:-} == -C ]]; then
  [[ $# -ge 2 ]] || usage
  workdir=$2
  shift 2
fi

[[ $# -ge 1 ]] || usage

export PATH=/Users/oobi/.opam/ctxcat-ocaml/bin:$PATH
cd $workdir || exit 3
exec "$@"
