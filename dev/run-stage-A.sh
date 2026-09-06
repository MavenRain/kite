#!/bin/zsh
# kite Stage A runner.  One script holds every gate command and every
# mutation command of the Stage A brief, because a subagent shell resets
# its working directory between calls and only an absolute path is
# repeatable (M0-PLAN.md:150).  Every path below is absolute.
#
# Use:
#   zsh /Users/oobi/Documents/kite/dev/run-stage-A.sh --gate SA-G5
#   zsh /Users/oobi/Documents/kite/dev/run-stage-A.sh --mut SA-M2
#   zsh /Users/oobi/Documents/kite/dev/run-stage-A.sh --gates-all
#
# The script never writes in the repository tree.  Every work file, probe
# and mutation copy lives under SCRATCH.  It runs no git add, no git
# commit and no git push.

set -u

REPO=/Users/oobi/Documents/kite
SCRATCH=${TMPDIR%/}/kite-stageA/judge
mkdir -p $SCRATCH

# --- SA-G1 the build ---------------------------------------------------
g1 () {
  local out code
  out=$(zsh $REPO/dev/pin-dune.sh dune build @all 2>&1)
  code=$?
  print -r -- "SA-G1 exit=$code output_bytes=${#out}"
  print -r -- "SA-G1 output=[$out]"
}

# --- SA-G2 every path of brief 3 exists --------------------------------
g2 () {
  local p missing=0
  local -a want
  want=(
    dune-project .gitignore LICENSE-MIT LICENSE-APACHE README.md SPEC.md
    lib/dune lib/ident.ml lib/label.ml lib/literal.ml lib/error.ml
    surface/dune surface/ast.ml surface/lexer.ml surface/parser.ml
    surface/print.ml test/dune test/parse.ml
    dev/gates.sh dev/house.sh dev/pin-dune.sh dev/bench.sh
    dev/denominators.sh dev/denominators.json dev/DENOMINATORS.sha256
    dev/trusted-lines.sh dev/PROVENANCE.md dev/M0-BUILD-LOG.md
    dev/MUTATION-LOG.md dev/CARRY.md
  )
  for p in $want; do
    if [[ -f $REPO/$p ]]; then : ; else
      print -r -- "SA-G2 ABSENT $p"; missing=$(( missing + 1 ))
    fi
  done
  local kites fmts negs errs f
  kites=$(fd -e kite . $REPO/test/roundtrip | wc -l | tr -d ' ')
  fmts=$(fd -e fmt . $REPO/test/roundtrip | wc -l | tr -d ' ')
  negs=$(fd 'parse-.*\.kite' . $REPO/test/neg | wc -l | tr -d ' ')
  errs=$(fd 'parse-.*\.err' . $REPO/test/neg | wc -l | tr -d ' ')
  for f in $REPO/test/roundtrip/*.kite(N); do
    if [[ -f ${f:r}.fmt ]]; then : ; else
      print -r -- "SA-G2 ABSENT golden ${f:r}.fmt"; missing=$(( missing + 1 ))
    fi
  done
  for f in $REPO/test/neg/parse-*.kite(N); do
    if [[ -f ${f:r}.err ]]; then : ; else
      print -r -- "SA-G2 ABSENT golden ${f:r}.err"; missing=$(( missing + 1 ))
    fi
  done
  print -r -- "SA-G2 paths=${#want} roundtrip=$kites fmt=$fmts twins=$negs err=$errs missing=$missing"
}

# --- SA-G3 every named AST form has an arm -----------------------------
g3 () {
  local n found=0 missing=0
  local -a cons names
  cons=(
    TName TArrow TRec TVar TCode Many AtMostOnce
    PLit PVar PWild PInj PRec
    Add Sub Mul Div Mod Cat Eq Ne Lt Le Gt Ge And Or
    Lit Var Lam App Let LetRec If Rec RecExt RecRes Sel Inj Match Ann Bin
    DLet DLetRec DImport DBudget DProtocol DRole DFreeze DManifest
    DMilestone M1 M2 M3 M4
  )
  names=(
    ty mult trow fields tail pat binop expr arm bind decl prog
    proto pname states pstate sname legs compensate
    role rname clauses peer_lost abort
    import iname ity cost deadline_ms mentry kind ename milestone
  )
  for n in $cons; do
    if rg -q "\b$n\b" $REPO/surface/ast.ml; then found=$(( found + 1 ))
    else print -r -- "SA-G3 MISSING constructor $n"; missing=$(( missing + 1 )); fi
  done
  local nfound=0
  for n in $names; do
    if rg -q "\b$n\b" $REPO/surface/ast.ml; then nfound=$(( nfound + 1 ))
    else print -r -- "SA-G3 MISSING name $n"; missing=$(( missing + 1 )); fi
  done
  print -r -- "SA-G3 constructors=$found/${#cons} names=$nfound/${#names} missing=$missing"
}

# --- SA-G4 the house rules ---------------------------------------------
g4 () {
  local out code
  out=$(zsh $REPO/dev/house.sh 2>&1)
  code=$?
  print -r -- "$out"
  print -r -- "SA-G4 exit=$code"
}

# --- SA-G5 the ONE measurable gate, PARSE ------------------------------
g5 () {
  local out code
  out=$(zsh $REPO/dev/gates.sh --leg parse 2>&1)
  code=$?
  print -r -- "$out"
  print -r -- "SA-G5 exit=$code"
}

# --- SA-G6 the vacuous-pass trap, on the SCRATCH copy alone ------------
g6 () {
  local out code eout ecode fails
  eout=$($REPO/_build/default/test/parse.exe 2>&1)
  ecode=$?
  print -r -- "SA-G6 empty=[$eout] exit=$ecode"
  rm -rf $SCRATCH/g6
  mkdir -p $SCRATCH/g6/roundtrip
  cp $REPO/test/roundtrip/lit.kite $SCRATCH/g6/roundtrip/lit.kite
  cp $REPO/test/roundtrip/lit.fmt $SCRATCH/g6/roundtrip/lit.fmt
  print -n -- "x" >> $SCRATCH/g6/roundtrip/lit.fmt
  out=$($REPO/_build/default/test/parse.exe $SCRATCH/g6/roundtrip/lit.kite 2>&1)
  code=$?
  fails=$(print -r -- "$out" | rg -c '^PARSE-FAIL ' || true)
  print -r -- "SA-G6 edited=[$out] fail_lines=$fails exit=$code"
}

# --- SA-G7 each Parse twin alone ---------------------------------------
g7 () {
  local f out code first ok=0
  for f in $REPO/test/neg/parse-*.kite(N); do
    out=$($REPO/_build/default/test/parse.exe $f 2>&1)
    code=$?
    first=$(head -c 5 ${f:r}.err)
    print -r -- "SA-G7 ${f:t} line=[$out] exit=$code golden_first=$first"
    if [[ $code -eq 0 && $first == "Parse" ]]; then ok=$(( ok + 1 )); fi
  done
  print -r -- "SA-G7 twins_ok=$ok"
}

# --- SA-G8 the whole battery -------------------------------------------
g8 () {
  local code left
  zsh $REPO/dev/gates.sh > $SCRATCH/g8.txt 2>&1
  code=$?
  cat $SCRATCH/g8.txt
  left=0
  if [[ -d $REPO/.gatework ]]; then left=$(( left + 1 )); fi
  left=$(( left + $(fd -d 1 -t d "kite-gates-" ${TMPDIR%/} | wc -l | tr -d " ") ))
  print -r -- "SA-G8 exit=$code work_dirs_left=$left"
}

# --- SA-G9 no em-dash in the tree --------------------------------------
g9 () {
  local em hits
  em=$(printf '\342\200\224')
  hits=$(rg -l -e $em $REPO --glob '!.git' --glob '!_build' | wc -l | tr -d ' ')
  print -r -- "SA-G9 em_dash_files=$hits"
  zsh $REPO/dev/house.sh 2>&1 | rg 'em-dash'
}

# --- SA-G10 the refusal table ------------------------------------------
g10 () {
  local rows m1 m2
  rows=$(rg -c '^\| ' $REPO/SPEC.md || print -r -- 0)
  m1=$(rg -c 'arrives at M1' $REPO/SPEC.md || print -r -- 0)
  m2=$(rg -c 'arrives at M2' $REPO/SPEC.md || print -r -- 0)
  print -r -- "SA-G10 table_rows=$rows arrives_at_M1=$m1 arrives_at_M2=$m2"
}

# --- SA-G11 no _build path and ZERO commits ----------------------------
g11 () {
  local bp rl code staged
  bp=$(git -C $REPO status --porcelain | rg -c '_build' || print -r -- 0)
  rl=$(git -C $REPO rev-list --count HEAD 2>&1)
  code=$?
  staged=$(git -C $REPO status --porcelain | rg -c '^[AMD] ' || print -r -- 0)
  print -r -- "SA-G11 build_paths=$bp rev_list=[$rl] rev_list_exit=$code staged=$staged"
}

# --- SA-G12 the trusted-lines budget -----------------------------------
g12 () {
  local out code
  out=$(zsh $REPO/dev/trusted-lines.sh 2>&1)
  code=$?
  print -r -- "SA-G12 line=[$out] exit=$code"
}

# --- SA-G13 the read-only trees ----------------------------------------
g13 () {
  local t n
  for t in brisk kanon tot tally anvil-ocaml ocaml-tea tab-cluster-spike; do
    n=$(git -C /Users/oobi/Documents/$t status --porcelain 2>&1 | wc -l | tr -d ' ')
    print -r -- "SA-G13 $1 $t porcelain=$n"
  done
}

# --- the mutation checks, on a copy under SCRATCH alone ----------------
mut_copy () {
  local dst=$SCRATCH/mut-$1
  rm -rf $dst
  mkdir -p $dst
  rsync -a --exclude _build --exclude .git $REPO/ $dst/
  zsh $dst/dev/pin-dune.sh dune build @all > $SCRATCH/mut-$1-build.txt 2>&1
  print -r -- "MUT-$1 copy_build_exit=$? at=$dst"
}

mut_run () {
  local dst=$SCRATCH/mut-$1 out code
  out=$(zsh $dst/dev/gates.sh --leg parse 2>&1)
  code=$?
  print -r -- "$out"
  print -r -- "MUT-$1 leg_parse_exit=$code"
}

mut_applied () {
  local before=$1 after=$2
  if [[ $before == $after ]]; then print -r -- "MUT edit=NONE"
  else print -r -- "MUT edit=APPLIED"; fi
}

# SA-M1 the printer swaps the first two fields of a record literal.
m1 () {
  local dst=$SCRATCH/mut-SA-M1 b a
  mut_copy SA-M1
  b=$(shasum -a 256 $dst/surface/print.ml | cut -c1-12)
  sd -s $'       (fun (l, v) -> words [ Label.to_string l;  "=";  expr CArm v ])\n       fs)' \
     $'       (fun (l, v) -> words [ Label.to_string l;  "=";  expr CArm v ])\n       (match fs with | a :: b :: r -> b :: a :: r | o -> o))' \
     $dst/surface/print.ml
  a=$(shasum -a 256 $dst/surface/print.ml | cut -c1-12)
  mut_applied $b $a
  mut_run SA-M1
}

# SA-M2 the lexer drops the nested-comment arm, so a comment ends at the
# first close bracket.
m2 () {
  local dst=$SCRATCH/mut-SA-M2 b a
  mut_copy SA-M2
  b=$(shasum -a 256 $dst/surface/lexer.ml | cut -c1-12)
  sd -s $'  | () when Char.equal (head st.rest) \'(\' && Char.equal (after st.rest) \'*\' ->\n    comment (jump st 2) opened (depth + 1)\n' \
     '' \
     $dst/surface/lexer.ml
  a=$(shasum -a 256 $dst/surface/lexer.ml | cut -c1-12)
  mut_applied $b $a
  mut_run SA-M2
}

# SA-M3 one golden is removed, which is a failure and never a skip.
m3 () {
  local dst=$SCRATCH/mut-SA-M3 b a
  mut_copy SA-M3
  b=$(fd -e fmt . $dst/test/roundtrip | wc -l | tr -d ' ')
  rm -f $dst/test/roundtrip/ops.fmt
  a=$(fd -e fmt . $dst/test/roundtrip | wc -l | tr -d ' ')
  print -r -- "MUT goldens_before=$b goldens_after=$a"
  mut_run SA-M3
}

# SA-M4 the parser accepts a handler row that is not { store }.
m4 () {
  local dst=$SCRATCH/mut-SA-M4 b a
  mut_copy SA-M4
  b=$(shasum -a 256 $dst/surface/parser.ml | cut -c1-12)
  sd -s $'            Result.bind\n              (expect_sym "}"\n                 "the freeze handler row is { store } and no other" r2)\n              (fun r3 ->' \
     $'            let rec close (r : stream) : (stream, Error.t) result =\n              if at_sym "}" r then\n                expect_sym "}" "expected a closing brace" r\n              else Result.bind (take r) (fun (_tk, rr) -> close rr) in\n            Result.bind\n              (close r2)\n              (fun r3 ->' \
     $dst/surface/parser.ml
  a=$(shasum -a 256 $dst/surface/parser.ml | cut -c1-12)
  mut_applied $b $a
  mut_run SA-M4
}

case ${1:-} in
  --gate)
    case ${2:-} in
      SA-G1) g1 ;;
      SA-G2) g2 ;;
      SA-G3) g3 ;;
      SA-G4) g4 ;;
      SA-G5) g5 ;;
      SA-G6) g6 ;;
      SA-G7) g7 ;;
      SA-G8) g8 ;;
      SA-G9) g9 ;;
      SA-G10) g10 ;;
      SA-G11) g11 ;;
      SA-G12) g12 ;;
      SA-G13) g13 ${3:-now} ;;
      *) print -r -- "run-stage-A: unknown gate ${2:-}"; exit 64 ;;
    esac ;;
  --mut)
    case ${2:-} in
      SA-M1) m1 ;;
      SA-M2) m2 ;;
      SA-M3) m3 ;;
      SA-M4) m4 ;;
      *) print -r -- "run-stage-A: unknown mutant ${2:-}"; exit 64 ;;
    esac ;;
  --gates-all)
    g1; g2; g3; g4; g5; g6; g7; g8; g9; g10; g11; g12; g13 now ;;
  *)
    print -r -- "usage: zsh dev/run-stage-A.sh [--gate ID | --mut ID | --gates-all]"
    exit 64 ;;
esac
