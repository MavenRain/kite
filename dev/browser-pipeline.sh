#!/bin/zsh
# Every sample emits source IR, its executable artifact and both browser bridges.
set -eu
chpwd_functions=()
unfunction chpwd 2>/dev/null || true
root=${0:A:h:h}
[[ $# -eq 1 ]] || exit 64
work=$(mktemp -d "${TMPDIR:-/tmp}/kite-browser-pipeline.XXXXXX")
trap 'rm -rf "$work"' EXIT
cp "$1" "$work/program.kite"
mkdir -p "$work/browser" "$work/_build/default/browser"
"$root/_build/default/bin/kite.exe" build "$work/program.kite"
zsh "$root/dev/pin-dune.sh" js_of_ocaml \
  "$root/_build/default/browser/model.bc" -o "$work/_build/default/browser/model.bc.js"
zsh "$root/dev/pin-dune.sh" js_of_ocaml \
  "$root/_build/default/browser/program.bc" -o "$work/_build/default/browser/program.bc.js"
cp "$root"/browser/*.js "$root/browser/index.html" "$work/browser/"
[[ -s "$work/program.kir" && -s "$work/program.kite.js" && \
   -s "$work/_build/default/browser/model.bc.js" && \
   -s "$work/_build/default/browser/program.bc.js" ]]
