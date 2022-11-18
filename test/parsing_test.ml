(*Example tests*)

open OUnit2
open Lys_ast
open Lys_parsing.Lex_and_parse

let test_int _ =
  assert_equal (Some (Ast.Constant (Ast.Integer 2)))
    (parse_expression (Lexing.from_string "2"))

let test_bool_true _ =
  assert_equal (Some (Ast.Constant (Ast.Boolean true)))
    (parse_expression (Lexing.from_string "true"))

let test_bool_false _ =
  assert_equal (Some (Ast.Constant (Ast.Boolean false)))
    (parse_expression (Lexing.from_string "false"))

let test_prod _ =
  assert_equal
    (Some (Ast.Prod (Ast.Identifier "x", Ast.Identifier "y")))
    (parse_expression (Lexing.from_string "(x, y)"))

let test_fst _ =
  assert_equal
    (Some (Ast.Fst (Ast.Prod (Ast.Identifier "x", Ast.Identifier "y"))))
    (parse_expression (Lexing.from_string "fst (x, y)"))

let test_snd _ =
  assert_equal
    (Some (Ast.Snd (Ast.Prod (Ast.Identifier "x", Ast.Identifier "y"))))
    (parse_expression (Lexing.from_string "snd (x, y)"))

let test_fun _ =
  assert_equal
    (Some (Ast.Lambda (("x", Ast.TBool), Identifier "e")))
    (parse_expression (Lexing.from_string "fun (x: bool) -> e"))

let test_app _ =
  assert_equal
    (Some
       (Ast.Application
          ( Ast.Identifier "f",
            Ast.BinaryOp (Ast.ADD, Identifier "x", Identifier "y") )))
    (parse_expression (Lexing.from_string "f (x + y)"))

let test_box _ =
  assert_equal
    (Some (Ast.Box ([ ("x", Ast.TInt); ("y", Ast.TBool) ], Ast.Identifier "a")))
    (parse_expression (Lexing.from_string "box (x: int, y: bool |- a)"))

let test_unbox _ =
  assert_equal
    (Some
       (Ast.LetBox
          ( "u",
            Ast.Box ([ ("x", Ast.TInt); ("y", Ast.TBool) ], Ast.Identifier "a"),
            Ast.Identifier "e" )))
    (parse_expression
       (Lexing.from_string "let box u = box (x: int, y: bool |- a) in e"))

let test_with _ =
  assert_equal
    (Some
       (Ast.Closure
          ("u", [ Ast.Constant (Ast.Integer 1); Ast.Constant (Ast.Integer 2) ])))
    (parse_expression (Lexing.from_string "u with (1, 2)"))

(*TODO: Tests for Let, Let rec, Arithmetic, Boolean algebra, If then else, Sum types*)

(* Name the test cases and group them together *)
let suite =
  "suite"
  >::: [
         "test_int" >:: test_int;
         "test_bool_true" >:: test_bool_true;
         "test_prod" >:: test_prod;
         "test_fst" >:: test_fst;
         "test_snd" >:: test_snd;
         "test_fun" >:: test_fun;
         "test_app" >:: test_app;
         "test_box" >:: test_box;
         "test_unbox" >:: test_unbox;
         "test_with" >:: test_with;
       ]

let () = run_test_tt_main suite
