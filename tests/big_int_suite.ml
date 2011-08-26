open Arithmetic
open Big_int
open Big_int_convenience
open OUnit

type op = Mod | Div

let op_to_string = function
  | Mod -> "Mod"
  | Div -> "Div"

exception TestFail of op * int64 * int64

let truncating_division_test n =
  let () = Random.self_init () in
  let getrandsign () =
    match Random.int64 2L with
    | 0L -> 1L
    | 1L -> -1L
    | _ -> failwith "not possible"
  in
  let rec getrand ?(acc=[]) = function
    | 0 -> acc
    | n when n > 0 -> 
        getrand ~acc:((Int64.mul (getrandsign ()) (Random.int64 Int64.max_int),
                      Int64.mul (getrandsign ()) (Random.int64 Int64.max_int)) :: acc) (n-1)
    | _ -> failwith "getrand: negative value"
  in
  (* List.iter (fun (x,y) -> Printf.printf "woo: %Lx\n" x) (getrand [] 100) *)
  let testcases = getrand n in
  let test_a_case (x,y) =
    (* Printf.printf "Testing %Ld / %Ld\n" x y; *)
    let idiv = Int64.div x y in
    let imod = Int64.rem x y in
    let bdiv = Arithmetic.t_div (big_int_of_int64 x) (big_int_of_int64 y) in
    let bmod = Arithmetic.t_mod (big_int_of_int64 x) (big_int_of_int64 y) in
    let idiv = big_int_of_int64 idiv in
    let imod = big_int_of_int64 imod in
    if bdiv <>% idiv then raise TestFail(Div, x, y);
    if bmod <>% imod then raise TestFail(Mod, x, y)
  in
  try
    List.iter test_a_case testcases
  with TestFail(o, x, y) -> assert_failure (Printf.sprintf "Invalid truncating %s result: (%d,%d)" (op_to_string o) x y)
;;

let suite = "Bigint" >:::
  [
    "truncating_division_test" >:: truncating_division_test 100000
  ]
