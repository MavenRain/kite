#!/bin/zsh
# Every sample emits source IR, its executable artifact and both browser bridges.
set -eu
# Background compilers retain the priority of the former foreground commands.
unsetopt BG_NICE
chpwd_functions=()
unfunction chpwd 2>/dev/null || true
root=${0:A:h:h}
destination=""
if [[ $# -eq 3 && $1 == --output ]]; then
  destination=${2:A}
  shift 2
fi
[[ $# -eq 1 ]] || { print -u2 -- 'usage: browser-pipeline.sh [--output DIR] SOURCE'; exit 64; }
if [[ -n $destination && ( -e $destination || -L $destination ) ]]; then
  print -u2 -- 'pipeline output already exists'
  exit 73
fi
work=$(mktemp -d "${TMPDIR:-/tmp}/kite-browser-pipeline.XXXXXX")
source_pid=0
model_pid=0
program_pid=0
reserved=0
retained=0
cleanup () {
  local result=$? child
  trap - EXIT HUP INT TERM
  for child in $source_pid $model_pid $program_pid; do
    if (( child > 0 )); then kill -TERM "$child" 2>/dev/null || true; fi
  done
  for child in $source_pid $model_pid $program_pid; do
    if (( child > 0 )); then wait "$child" 2>/dev/null || true; fi
  done
  rm -rf "$work"
  if (( reserved && !retained )); then rm -rf "$destination"; fi
  return $result
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
cp "$1" "$work/program.kite"
mkdir -p "$work/browser" "$work/_build/default/browser"
"$root/_build/default/bin/kite.exe" build "$work/program.kite" &
source_pid=$!
source_code=0
wait "$source_pid" || source_code=$?
source_pid=0
(( source_code == 0 )) || exit "$source_code"
# These fresh emissions consume independent bytecode and write distinct products.
zsh "$root/dev/pin-dune.sh" js_of_ocaml \
  "$root/_build/default/browser/model.bc" -o "$work/_build/default/browser/model.bc.js" &
model_pid=$!
zsh "$root/dev/pin-dune.sh" js_of_ocaml --effects=cps \
  "$root/_build/default/browser/program.bc" -o "$work/_build/default/browser/program.bc.js" &
program_pid=$!
cp "$root"/browser/*.js "$root/browser/index.html" "$work/browser/"
model_code=0
program_code=0
wait "$model_pid" || model_code=$?
model_pid=0
wait "$program_pid" || program_code=$?
program_pid=0
(( model_code == 0 )) || exit "$model_code"
(( program_code == 0 )) || exit "$program_code"
[[ -s "$work/program.kir" && -s "$work/program.kite.js" && \
   -s "$work/_build/default/browser/model.bc.js" && \
   -s "$work/_build/default/browser/program.bc.js" ]]
if [[ -n $destination ]]; then
  mkdir "$destination"
  reserved=1
  cp -R "$work/." "$destination/"
  retained=1
fi
