(* lib/sha256.ml:  the digest the .coi header carries (brief 3.9,
   D-B-13).  The header line source-sha256 holds sixty four hex digits
   over the source file the interface was written from, so a consumer of
   the interface never re-reads that source.

   The whole file is pure:  no cell, no array and no loop keyword, so
   every state of the compression rides in a record that a fold returns
   (dev/house.sh:131).  A word is an OCaml int held under a 32 bit mask,
   because an OCaml int is 63 bits wide and every operation below masks
   its own result.

   D-B-55:  the digest lives in its OWN lib file and not inside
   lib/iface.ml.  Reason:  dev/trusted-lines.sh:52-60 counts eight
   believed files against the 2,400 line bound of D-M0-5, iface.ml is
   one of the eight, and a byte level digest holds no typing rule, so it
   would spend that bound on code no wrong program can ride. *)

let mask : int = 0xFFFFFFFF

let rotr (x : int) (n : int) : int =
  ((x lsr n) lor (x lsl (32 - n))) land mask

let shr (x : int) (n : int) : int = (x lsr n) land mask

let ch (x : int) (y : int) (z : int) : int =
  (x land y) lxor (lnot x land z) land mask

let maj (x : int) (y : int) (z : int) : int =
  (x land y) lxor (x land z) lxor (y land z)

let bsig0 (x : int) : int = rotr x 2 lxor rotr x 13 lxor rotr x 22

let bsig1 (x : int) : int = rotr x 6 lxor rotr x 11 lxor rotr x 25

let ssig0 (x : int) : int = rotr x 7 lxor rotr x 18 lxor shr x 3

let ssig1 (x : int) : int = rotr x 17 lxor rotr x 19 lxor shr x 10

(* The sixty four round constants of FIPS 180-4, in round order. *)
let k_table : int list =
  [ 0x428a2f98;  0x71374491;  0xb5c0fbcf;  0xe9b5dba5;  0x3956c25b;
    0x59f111f1;  0x923f82a4;  0xab1c5ed5;  0xd807aa98;  0x12835b01;
    0x243185be;  0x550c7dc3;  0x72be5d74;  0x80deb1fe;  0x9bdc06a7;
    0xc19bf174;  0xe49b69c1;  0xefbe4786;  0x0fc19dc6;  0x240ca1cc;
    0x2de92c6f;  0x4a7484aa;  0x5cb0a9dc;  0x76f988da;  0x983e5152;
    0xa831c66d;  0xb00327c8;  0xbf597fc7;  0xc6e00bf3;  0xd5a79147;
    0x06ca6351;  0x14292967;  0x27b70a85;  0x2e1b2138;  0x4d2c6dfc;
    0x53380d13;  0x650a7354;  0x766a0abb;  0x81c2c92e;  0x92722c85;
    0xa2bfe8a1;  0xa81a664b;  0xc24b8b70;  0xc76c51a3;  0xd192e819;
    0xd6990624;  0xf40e3585;  0x106aa070;  0x19a4c116;  0x1e376c08;
    0x2748774c;  0x34b0bcb5;  0x391c0cb3;  0x4ed8aa4a;  0x5b9cca4f;
    0x682e6ff3;  0x748f82ee;  0x78a5636f;  0x84c87814;  0x8cc70208;
    0x90befffa;  0xa4506ceb;  0xbef9a3f7;  0xc67178f2
  ]

(* The eight working words.  The names run h0 to h7, so the round below
   reads as the standard does. *)
type words =
  { h0 : int;  h1 : int;  h2 : int;  h3 : int;
    h4 : int;  h5 : int;  h6 : int;  h7 : int
  }

let initial : words =
  { h0 = 0x6a09e667;  h1 = 0xbb67ae85;  h2 = 0x3c6ef372;  h3 = 0xa54ff53a;
    h4 = 0x510e527f;  h5 = 0x9b05688c;  h6 = 0x1f83d9ab;  h7 = 0x5be0cd19
  }

(* --- total list helpers --------------------------------------------- *)

(* D-B-68:  a list index rides a total recursion written here, never the
   indexed reader of the standard library.  Reason:  the partial-index
   leg of dev/house.sh reads a TEXT, and the option-returning name of the
   standard library carries that same text as a prefix, so the total
   spelling of the library reads to the guard as the partial one. *)
let rec at (i : int) (xs : int list) : int =
  match xs with
  | [] -> 0
  | x :: rest -> if i <= 0 then x else at (i - 1) rest

let rec take (n : int) (xs : int list) : int list =
  if n <= 0 then []
  else
    match xs with
    | [] -> []
    | y :: rest -> y :: take (n - 1) rest

let rec drop (n : int) (xs : int list) : int list =
  if n <= 0 then xs
  else
    match xs with
    | [] -> []
    | _y :: rest -> drop (n - 1) rest

(* --- the padded message ---------------------------------------------- *)

let bytes_of_string (s : string) : int list =
  List.map Char.code (List.of_seq (String.to_seq s))

let be64 (n : int) : int list =
  List.map (fun (i : int) -> (n lsr i) land 255)
    [ 56;  48;  40;  32;  24;  16;  8;  0 ]

let rec zeros (n : int) : int list =
  if n <= 0 then [] else 0 :: zeros (n - 1)

(* One 0x80 byte, then zero bytes to fifty six of every sixty four, then
   the bit length in eight big endian bytes. *)
let padded (bs : int list) : int list =
  let len = List.length bs in
  let filler = (56 - ((len + 1) land 63) + 64) land 63 in
  List.concat [ bs;  [ 0x80 ];  zeros filler;  be64 (len lsl 3) ]

(* --- one block -------------------------------------------------------- *)

let word_at (i : int) (block : int list) : int =
  ((at (4 * i) block lsl 24)
   lor (at ((4 * i) + 1) block lsl 16)
   lor (at ((4 * i) + 2) block lsl 8)
   lor at ((4 * i) + 3) block)
  land mask

let rec schedule (w : int list) (i : int) : int list =
  if i >= 64 then w
  else
    let v =
      (at (i - 16) w + ssig0 (at (i - 15) w) + at (i - 7) w
       + ssig1 (at (i - 2) w))
      land mask in
    schedule (List.append w [ v ]) (i + 1)

let round (st : words) (kt : int) (wt : int) : words =
  let t1 =
    (st.h7 + bsig1 st.h4 + ch st.h4 st.h5 st.h6 + kt + wt) land mask in
  let t2 = (bsig0 st.h0 + maj st.h0 st.h1 st.h2) land mask in
  { h0 = (t1 + t2) land mask;
    h1 = st.h0;
    h2 = st.h1;
    h3 = st.h2;
    h4 = (st.h3 + t1) land mask;
    h5 = st.h4;
    h6 = st.h5;
    h7 = st.h6
  }

(* The two tables ride by index and never by List.combine, which is
   partial on a length difference (D-B-56). *)
let rec rounds (st : words) (w : int list) (i : int) : words =
  if i >= 64 then st
  else rounds (round st (at i k_table) (at i w)) w (i + 1)

let add_words (a : words) (b : words) : words =
  { h0 = (a.h0 + b.h0) land mask;
    h1 = (a.h1 + b.h1) land mask;
    h2 = (a.h2 + b.h2) land mask;
    h3 = (a.h3 + b.h3) land mask;
    h4 = (a.h4 + b.h4) land mask;
    h5 = (a.h5 + b.h5) land mask;
    h6 = (a.h6 + b.h6) land mask;
    h7 = (a.h7 + b.h7) land mask
  }

let compress (st : words) (block : int list) : words =
  let w0 = List.map (fun (i : int) -> word_at i block) (List.init 16 Fun.id) in
  add_words st (rounds st (schedule w0 16) 0)

let rec blocks (st : words) (bs : int list) : words =
  match bs with
  | [] -> st
  | _y :: _rest -> blocks (compress st (take 64 bs)) (drop 64 bs)

(* --- the printed digest ----------------------------------------------- *)

let digits : string list =
  [ "0";  "1";  "2";  "3";  "4";  "5";  "6";  "7";
    "8";  "9";  "a";  "b";  "c";  "d";  "e";  "f"
  ]

let rec digit_at (i : int) (xs : string list) : string =
  match xs with
  | [] -> "0"
  | x :: rest -> if i <= 0 then x else digit_at (i - 1) rest

let hex_digit (n : int) : string = digit_at (n land 15) digits

let hex_word (x : int) : string =
  String.concat ""
    (List.map (fun (i : int) -> hex_digit ((x lsr i) land 15))
       [ 28;  24;  20;  16;  12;  8;  4;  0 ])

let of_string (s : string) : string =
  let st = blocks initial (padded (bytes_of_string s)) in
  String.concat ""
    (List.map hex_word
       [ st.h0;  st.h1;  st.h2;  st.h3;  st.h4;  st.h5;  st.h6;  st.h7 ])
