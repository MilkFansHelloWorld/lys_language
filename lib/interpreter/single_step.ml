open Lys_ast
open Lys_substitutions
open Core
open Interpreter_common
open Lys_utils
open Lys_typing

module ReduceResult : sig
  type t =
    | NotReduced of Ast.Value.t
    | ReducedToVal of Ast.Value.t
    | ReducedToExpr of Ast.Expr.t
  [@@deriving sexp, show, equal, compare]

  val process :
    reduced:(Ast.Expr.t -> 'a) ->
    ?reduced_to_val:(Ast.Value.t -> 'a) ->
    not_reduced:(Ast.Value.t -> 'a) ->
    t ->
    'a
end = struct
  type t =
    | NotReduced of Ast.Value.t
    | ReducedToVal of Ast.Value.t
    | ReducedToExpr of Ast.Expr.t
  [@@deriving sexp, show, equal, compare]

  let process ~reduced ?reduced_to_val ~not_reduced res =
    match res with
    | NotReduced v -> not_reduced v
    | ReducedToExpr e -> e |> reduced
    | ReducedToVal v -> (
        match reduced_to_val with
        | None -> v |> Ast.Value.to_expr |> reduced
        | Some r -> v |> r)
end

module TypeCheckEachStep : sig
  type t =
    | NoCheck
    | CheckType of Ast.Typ.t
    | CheckRec of Ast.IdentifierDefn.t list * Ast.Typ.t

  val type_check_if_needed :
    EvaluationContext.t ->
    TypeConstrContext.t ->
    int ->
    Ast.Expr.t ->
    t ->
    unit Or_error.t
end = struct
  type t =
    | NoCheck
    | CheckType of Ast.Typ.t
    | CheckRec of Ast.IdentifierDefn.t list * Ast.Typ.t

  let type_check_if_needed top_level_context type_constr_context step_cnt expr
      type_to_check =
    match type_to_check with
    | NoCheck -> Ok ()
    | CheckType typ ->
        Typecore.type_check_expression
          (Typing_context.MetaTypingContext.create_empty_context ())
          (Interpreter_common.EvaluationContext.to_typing_obj_context
             top_level_context)
          type_constr_context
          (Typing_context.PolyTypeVarContext.create_empty_context ())
          ~allow_refs:true expr typ
        |> Or_error.tag
             ~tag:
               (Printf.sprintf
                  "SingleStepEvaluationTypeCheckError: Type preservation \
                   failed at step %i"
                  step_cnt)
    | CheckRec (iddefs, typ) ->
        Typecore.type_check_expression
          (Typing_context.MetaTypingContext.create_empty_context ())
          (Typing_context.ObjTypingContext.add_all_mappings
             (Interpreter_common.EvaluationContext.to_typing_obj_context
                top_level_context)
             (List.map iddefs ~f:(fun (x, typ) -> (x, (typ, 0)))))
          type_constr_context
          (Typing_context.PolyTypeVarContext.create_empty_context ())
          ~allow_refs:true expr typ
        |> Or_error.tag
             ~tag:
               (Printf.sprintf
                  "SingleStepEvaluationTypeCheckError: Type preservation \
                   failed at step %i"
                  step_cnt)
end

let rec reduce ~top_level_context ~type_constr_context expr =
  let open Or_error.Monad_infix in
  let rec process_exprs = function
    (*
      Utility function: 
      Given a list expressions, reduce one by one from left to right.  
      if reduced, then get a left list of expressions reduced up to the last reduced value; else get the right list of values
    *)
    (*Left list = reduced to expr or val;  right list = not reduced*)
    | [] -> Ok ([], [])
    | e :: es ->
        reduce ~top_level_context ~type_constr_context e >>= fun res ->
        ReduceResult.process res
          ~reduced:(fun new_e -> Ok (new_e :: es, []))
          ~not_reduced:(fun new_v ->
            process_exprs es >>= fun (new_es, new_vs) ->
            if List.is_empty new_es then Ok ([], new_v :: new_vs)
            else Ok (Ast.Value.to_expr new_v :: new_es, []))
  in
  let rec convert_to_values exprs =
    (*Utility: Convert list of expressions into values if it's a list of values, if not give None*)
    match exprs with
    | [] -> Some []
    | e :: es ->
        let open Option.Monad_infix in
        Ast.Expr.to_val e >>= fun v ->
        convert_to_values es >>= fun vs -> Some (v :: vs)
  in
  match Ast.Expr.to_val expr with
  | Some v -> Ok (ReduceResult.NotReduced v)
  | None -> (
      match expr with
      | Ast.Expr.Identifier id -> (
          (*No error if we're dealing with sth at top level context, otherwise error*)
          let index = Ast.ObjIdentifier.get_debruijn_index id in
          if not (Ast.DeBruijnIndex.equal index Ast.DeBruijnIndex.top_level)
          then
            (*Error*)
            error
              "SingleStepReductionError: Can only evaluate a top level \
               identifier. A non top-level identifier \n\
              \    must have been substituted already." id
              [%sexp_of: Ast.ObjIdentifier.t]
          else
            let id_str = Ast.ObjIdentifier.get_name id in
            EvaluationContext.find_or_error top_level_context id_str
            >>= fun { rec_preface; value; _ } ->
            (* if EvaluationContext.is_not_rec { typ; rec_preface; value } then
                 (*Substitution -- no need to worry about De Bruijn indices as there is no way they can go wrong*)
                 Ok (ReduceResult.ReducedToVal value)
               else
                 (* Recursion: handle once together. *)
                 Ast.DeBruijnIndex.create 0 >>= fun debruijn_index ->
                 Ok
                   (ReduceResult.ReducedToExpr
                      (Ast.Expr.LetRec
                         ( (Ast.ObjIdentifier.of_string id_str, typ),
                           Ast.Value.to_expr value,
                           Ast.Expr.Identifier
                             (Ast.ObjIdentifier.of_string_and_index id_str
                                debruijn_index) ))) *)
            Ast.DeBruijnIndex.create 0 >>= fun debruijn_index_0 ->
            match rec_preface with
            | [] -> Ok (ReduceResult.ReducedToVal value)
            | [ (iddef, ev) ] ->
                Ok
                  (ReduceResult.ReducedToExpr
                     (Ast.Expr.LetRec
                        ( iddef,
                          ev,
                          Ast.Expr.Identifier
                            (Ast.ObjIdentifier.of_string_and_index id_str
                               debruijn_index_0) )))
            | iddef_ev_list ->
                Ok
                  (ReducedToExpr
                     (Ast.Expr.LetRecMutual
                        ( iddef_ev_list,
                          Ast.Expr.Identifier
                            (Ast.ObjIdentifier.of_string_and_index id_str
                               debruijn_index_0) ))))
      | Ast.Expr.Constant c ->
          (*Constants don't reduce*)
          Ok (ReduceResult.NotReduced (Ast.Value.Constant c))
      | Ast.Expr.UnaryOp (op, expr) ->
          (*Check if value*)
          reduce ~top_level_context ~type_constr_context expr >>= fun res ->
          ReduceResult.process res
            ~reduced:(fun e ->
              Ok (ReduceResult.ReducedToExpr (Ast.Expr.UnaryOp (op, e))))
            ~not_reduced:(fun v ->
              (*Reduction*)
              match (op, v) with
              | ( Ast.UnaryOperator.NEG,
                  Ast.Value.Constant (Ast.Constant.Integer i) ) ->
                  Ok
                    (ReduceResult.ReducedToVal
                       (Ast.Value.Constant (Ast.Constant.Integer (-i))))
              | ( Ast.UnaryOperator.NOT,
                  Ast.Value.Constant (Ast.Constant.Boolean b) ) ->
                  Ok
                    (ReduceResult.ReducedToVal
                       (Ast.Value.Constant (Ast.Constant.Boolean (not b))))
              | ( Ast.UnaryOperator.DEREF,
                  Ast.Value.Constant (Ast.Constant.Reference r) ) ->
                  let open Ast.RefCell in
                  Ok (ReduceResult.ReducedToVal !r)
              | ( Ast.UnaryOperator.ARRAY_LEN,
                  Ast.Value.Constant (Ast.Constant.Array arr) ) ->
                  Ok
                    (ReduceResult.ReducedToVal
                       (Ast.Value.Constant
                          (Ast.Constant.Integer (Ast.ArrayCell.length arr))))
              | _, _ ->
                  error
                    "SingleStepReductionError: type mismatch at Unary \
                     operator. [FATAL] should not happen! Type check should \
                     have prevented this."
                    (Ast.Expr.UnaryOp (op, expr))
                    [%sexp_of: Ast.Expr.t])
      | Ast.Expr.BinaryOp (op, expr1, expr2) ->
          reduce ~top_level_context ~type_constr_context expr1 >>= fun res1 ->
          ReduceResult.process res1
            ~reduced:(fun e1 ->
              Ok
                (ReduceResult.ReducedToExpr (Ast.Expr.BinaryOp (op, e1, expr2))))
            ~not_reduced:(fun v1 ->
              match (op, v1) with
              | Ast.BinaryOperator.SEQ, Ast.Value.Constant Ast.Constant.Unit ->
                  reduce ~top_level_context ~type_constr_context expr2
              | ( Ast.BinaryOperator.AND,
                  Ast.Value.Constant (Ast.Constant.Boolean false) ) ->
                  Ok
                    (ReduceResult.ReducedToVal
                       (Ast.Value.Constant (Ast.Constant.Boolean false)))
              | ( Ast.BinaryOperator.OR,
                  Ast.Value.Constant (Ast.Constant.Boolean true) ) ->
                  Ok
                    (ReduceResult.ReducedToVal
                       (Ast.Value.Constant (Ast.Constant.Boolean true)))
              | _, _ ->
                  reduce ~top_level_context ~type_constr_context expr2
                  >>= fun res2 ->
                  ReduceResult.process res2
                    ~reduced:(fun e2 ->
                      Ok
                        (ReduceResult.ReducedToExpr
                           (Ast.Expr.BinaryOp (op, Ast.Value.to_expr v1, e2))))
                    ~not_reduced:(fun v2 ->
                      match (op, v1, v2) with
                      | ( Ast.BinaryOperator.ADD,
                          Ast.Value.Constant (Ast.Constant.Integer i1),
                          Ast.Value.Constant (Ast.Constant.Integer i2) ) ->
                          Ok
                            (ReduceResult.ReducedToVal
                               (Ast.Value.Constant
                                  (Ast.Constant.Integer (i1 + i2))))
                      | ( Ast.BinaryOperator.SUB,
                          Ast.Value.Constant (Ast.Constant.Integer i1),
                          Ast.Value.Constant (Ast.Constant.Integer i2) ) ->
                          Ok
                            (ReduceResult.ReducedToVal
                               (Ast.Value.Constant
                                  (Ast.Constant.Integer (i1 - i2))))
                      | ( Ast.BinaryOperator.MUL,
                          Ast.Value.Constant (Ast.Constant.Integer i1),
                          Ast.Value.Constant (Ast.Constant.Integer i2) ) ->
                          Ok
                            (ReduceResult.ReducedToVal
                               (Ast.Value.Constant
                                  (Ast.Constant.Integer (i1 * i2))))
                      | ( Ast.BinaryOperator.DIV,
                          Ast.Value.Constant (Ast.Constant.Integer i1),
                          Ast.Value.Constant (Ast.Constant.Integer i2) ) ->
                          Ok
                            (ReduceResult.ReducedToVal
                               (Ast.Value.Constant
                                  (Ast.Constant.Integer (i1 / i2))))
                      | ( Ast.BinaryOperator.MOD,
                          Ast.Value.Constant (Ast.Constant.Integer i1),
                          Ast.Value.Constant (Ast.Constant.Integer i2) ) ->
                          Ok
                            (ReduceResult.ReducedToVal
                               (Ast.Value.Constant
                                  (Ast.Constant.Integer (i1 % i2))))
                      | Ast.BinaryOperator.EQ, v1, v2 ->
                          Ok
                            (ReduceResult.ReducedToVal
                               (Ast.Value.Constant
                                  (Ast.Constant.Boolean (Ast.Value.equal v1 v2))))
                      | Ast.BinaryOperator.NEQ, v1, v2 ->
                          Ok
                            (ReduceResult.ReducedToVal
                               (Ast.Value.Constant
                                  (Ast.Constant.Boolean
                                     (not (Ast.Value.equal v1 v2)))))
                      | ( Ast.BinaryOperator.GTE,
                          Ast.Value.Constant (Ast.Constant.Integer i1),
                          Ast.Value.Constant (Ast.Constant.Integer i2) ) ->
                          Ok
                            (ReduceResult.ReducedToVal
                               (Ast.Value.Constant
                                  (Ast.Constant.Boolean (i1 >= i2))))
                      | ( Ast.BinaryOperator.GT,
                          Ast.Value.Constant (Ast.Constant.Integer i1),
                          Ast.Value.Constant (Ast.Constant.Integer i2) ) ->
                          Ok
                            (ReduceResult.ReducedToVal
                               (Ast.Value.Constant
                                  (Ast.Constant.Boolean (i1 > i2))))
                      | ( Ast.BinaryOperator.LT,
                          Ast.Value.Constant (Ast.Constant.Integer i1),
                          Ast.Value.Constant (Ast.Constant.Integer i2) ) ->
                          Ok
                            (ReduceResult.ReducedToVal
                               (Ast.Value.Constant
                                  (Ast.Constant.Boolean (i1 < i2))))
                      | ( Ast.BinaryOperator.LTE,
                          Ast.Value.Constant (Ast.Constant.Integer i1),
                          Ast.Value.Constant (Ast.Constant.Integer i2) ) ->
                          Ok
                            (ReduceResult.ReducedToVal
                               (Ast.Value.Constant
                                  (Ast.Constant.Boolean (i1 <= i2))))
                      | ( Ast.BinaryOperator.AND,
                          Ast.Value.Constant (Ast.Constant.Boolean i1),
                          Ast.Value.Constant (Ast.Constant.Boolean i2) ) ->
                          Ok
                            (ReduceResult.ReducedToVal
                               (Ast.Value.Constant
                                  (Ast.Constant.Boolean (i1 && i2))))
                      | ( Ast.BinaryOperator.OR,
                          Ast.Value.Constant (Ast.Constant.Boolean i1),
                          Ast.Value.Constant (Ast.Constant.Boolean i2) ) ->
                          Ok
                            (ReduceResult.ReducedToVal
                               (Ast.Value.Constant
                                  (Ast.Constant.Boolean (i1 || i2))))
                      | ( Ast.BinaryOperator.CHARSTRINGCONCAT,
                          Ast.Value.Constant (Ast.Constant.Character c),
                          Ast.Value.Constant (Ast.Constant.String s) ) ->
                          Ok
                            (ReducedToVal
                               (Ast.Value.Constant
                                  (Ast.Constant.String (String.of_char c ^ s))))
                      | ( Ast.BinaryOperator.STRINGCONCAT,
                          Ast.Value.Constant (Ast.Constant.String s),
                          Ast.Value.Constant (Ast.Constant.String s2) ) ->
                          Ok
                            (ReducedToVal
                               (Ast.Value.Constant
                                  (Ast.Constant.String (s ^ s2))))
                      | ( Ast.BinaryOperator.ASSIGN,
                          Ast.Value.Constant (Ast.Constant.Reference r1),
                          v ) ->
                          let open Ast.RefCell in
                          r1 := v;
                          Ok
                            (ReducedToVal (Ast.Value.Constant Ast.Constant.Unit))
                      | ( Ast.BinaryOperator.ARRAY_INDEX,
                          Ast.Value.Constant (Ast.Constant.Array arr),
                          Ast.Value.Constant (Ast.Constant.Integer index) ) ->
                          Ok (ReducedToVal (Ast.ArrayCell.get arr index))
                          (*arr.(index)*)
                      | _, _, _ ->
                          error
                            "SingleStepReductionError: type mismatch at Binary \
                             operator. [FATAL] should not happen! Type check \
                             should have prevented this."
                            (Ast.Expr.BinaryOp (op, expr1, expr2))
                            [%sexp_of: Ast.Expr.t]))
      | Ast.Expr.Prod exprs -> (
          process_exprs exprs >>= fun (new_es, new_vs) ->
          if List.is_empty new_es then
            Ok (ReduceResult.NotReduced (Ast.Value.Prod new_vs))
          else
            (* Check if all are values *)
            match convert_to_values new_es with
            | None -> Ok (ReduceResult.ReducedToExpr (Ast.Expr.Prod new_es))
            | Some vs -> Ok (ReduceResult.ReducedToVal (Ast.Value.Prod vs)))
      | Ast.Expr.Nth (expr, i) ->
          reduce ~top_level_context ~type_constr_context expr >>= fun res ->
          ReduceResult.process res
            ~reduced:(fun e ->
              Ok (ReduceResult.ReducedToExpr (Ast.Expr.Nth (e, i))))
            ~not_reduced:(fun v ->
              match v with
              | Ast.Value.Prod values -> (
                  match List.nth values i with
                  | None ->
                      error
                        "SingleStepReductionError: type mismatch at Nth: \
                         access out of bounds. [FATAL] should not happen! Type \
                         check should have prevented this."
                        (Ast.Expr.Nth (expr, i))
                        [%sexp_of: Ast.Expr.t]
                  | Some v -> Ok (ReduceResult.ReducedToVal v))
              | _ ->
                  error
                    "SingleStepReductionError: type mismatch at Nth. [FATAL] \
                     should not happen! Type check should have prevented this."
                    (Ast.Expr.Nth (expr, i))
                    [%sexp_of: Ast.Expr.t])
      | Ast.Expr.Left (t1, t2, expr) ->
          reduce ~top_level_context ~type_constr_context expr >>= fun res ->
          ReduceResult.process res
            ~reduced:(fun e ->
              Ok (ReduceResult.ReducedToExpr (Ast.Expr.Left (t1, t2, e))))
            ~reduced_to_val:(fun v ->
              Ok (ReduceResult.ReducedToVal (Ast.Value.Left (t1, t2, v))))
            ~not_reduced:(fun v ->
              Ok (ReduceResult.NotReduced (Ast.Value.Left (t1, t2, v))))
      | Ast.Expr.Right (t1, t2, expr) ->
          reduce ~top_level_context ~type_constr_context expr >>= fun res ->
          ReduceResult.process res
            ~reduced:(fun e ->
              Ok (ReduceResult.ReducedToExpr (Ast.Expr.Right (t1, t2, e))))
            ~reduced_to_val:(fun v ->
              Ok (ReduceResult.ReducedToVal (Ast.Value.Right (t1, t2, v))))
            ~not_reduced:(fun v ->
              Ok (ReduceResult.NotReduced (Ast.Value.Right (t1, t2, v))))
      | Ast.Expr.Case (e, (id1, t1), e1, (id2, t2), e2) ->
          reduce ~top_level_context ~type_constr_context e >>= fun res ->
          ReduceResult.process res
            ~reduced:(fun new_e ->
              Ok
                (ReduceResult.ReducedToExpr
                   (Ast.Expr.Case (new_e, (id1, t1), e1, (id2, t2), e2))))
            ~not_reduced:(fun v ->
              let new_expr_or_error =
                match v with
                | Ast.Value.Left (_, _, v) ->
                    Substitutions.substitute (Ast.Value.to_expr v) id1 e1
                | Ast.Value.Right (_, _, v) ->
                    Substitutions.substitute (Ast.Value.to_expr v) id2 e2
                | _ ->
                    error
                      "SingleStepReductionError: type mismatch at match \
                       clause. [FATAL] should not happen! Type check should \
                       have prevented this."
                      expr [%sexp_of: Ast.Expr.t]
              in
              new_expr_or_error >>= fun new_expr ->
              Ok (ReduceResult.ReducedToExpr new_expr))
      | Ast.Expr.Lambda (iddef, e) ->
          Ok (ReduceResult.NotReduced (Ast.Value.Lambda (iddef, e)))
      | Ast.Expr.Application (e1, e2) ->
          reduce ~top_level_context ~type_constr_context e1 >>= fun res1 ->
          ReduceResult.process res1
            ~reduced:(fun new_e1 ->
              Ok
                (ReduceResult.ReducedToExpr (Ast.Expr.Application (new_e1, e2))))
            ~not_reduced:(fun v1 ->
              reduce ~top_level_context ~type_constr_context e2 >>= fun res2 ->
              ReduceResult.process res2
                ~reduced:(fun new_e2 ->
                  Ok
                    (ReduceResult.ReducedToExpr
                       (Ast.Expr.Application (Ast.Value.to_expr v1, new_e2))))
                ~not_reduced:(fun v2 ->
                  match v1 with
                  | Ast.Value.Lambda ((id, _), e) ->
                      Substitutions.substitute (Ast.Value.to_expr v2) id e
                      >>= fun new_expr ->
                      Ok (ReduceResult.ReducedToExpr new_expr)
                  | _ ->
                      error
                        "SingleStepReductionError: type mismatch at Lambda. \
                         [FATAL] should not happen! Type check should have \
                         prevented this."
                        expr [%sexp_of: Ast.Expr.t]))
      | Ast.Expr.IfThenElse (b, e1, e2) ->
          reduce ~top_level_context ~type_constr_context b >>= fun res_b ->
          ReduceResult.process res_b
            ~reduced:(fun new_b ->
              Ok
                (ReduceResult.ReducedToExpr
                   (Ast.Expr.IfThenElse (new_b, e1, e2))))
            ~not_reduced:(fun bv ->
              match bv with
              | Ast.Value.Constant (Ast.Constant.Boolean v) ->
                  if v then Ok (ReducedToExpr e1) else Ok (ReducedToExpr e2)
              | _ ->
                  error
                    "SingleStepReductionError: type mismatch at IfThenElse. \
                     [FATAL] should not happen! Type check should have \
                     prevented this."
                    expr [%sexp_of: Ast.Expr.t])
      | Ast.Expr.LetBinding ((id, t), e, e2) ->
          reduce ~top_level_context ~type_constr_context e >>= fun res1 ->
          ReduceResult.process res1
            ~reduced:(fun new_e1 ->
              Ok
                (ReduceResult.ReducedToExpr
                   (Ast.Expr.LetBinding ((id, t), new_e1, e2))))
            ~not_reduced:(fun ev ->
              Substitutions.substitute (Ast.Value.to_expr ev) id e2 >>= fun e ->
              Ok (ReduceResult.ReducedToExpr e))
      | Ast.Expr.LetRec ((id, typ), e, e2) ->
          (* let rec f = v in e  ~~~~~> [([(let rec f = v in f)/f]v)/f]e

             Analysis
               let rec f = (0)
                   v (1 -- means that index 0 at top level = f)
               in
                   e (1)

               (fun f (0)-> e(1)) ((fun f (0) -> v(1)) (let rec f(0) = v(1) in f(1)))

             So Shifting is not really needed!
             However, I can't just translate it to the above, for it will easily stack overflow, in a very unfortunate way,
             do to my call by value semantics. Instead, I shall have to actually manually write the substitutions out.
          *)
          reduce ~top_level_context ~type_constr_context e >>= fun res ->
          ReduceResult.process res
            ~reduced:(fun e ->
              Ok
                (ReduceResult.ReducedToExpr (Ast.Expr.LetRec ((id, typ), e, e2))))
            ~not_reduced:(fun v ->
              Ast.DeBruijnIndex.create 0 >>= fun db_index_0 ->
              (*let v1 = [(let rec f = v in f)/f]v*)
              let ev = Ast.Value.to_expr v in
              let to_sub_in =
                Ast.Expr.LetRec
                  ( (id, typ),
                    ev,
                    Ast.Expr.Identifier
                      (Ast.ObjIdentifier.of_string_and_index
                         (Ast.ObjIdentifier.get_name id)
                         db_index_0) )
              in
              Substitutions.substitute to_sub_in id ev >>= fun ev1 ->
              (*[v1/f]e*)
              Substitutions.substitute ev1 id e2 >>= fun ev2 ->
              Ok (ReduceResult.ReducedToExpr ev2))
      | Ast.Expr.LetRecMutual (iddef_e_list, e2) ->
          (*
           Explanation: exactly the same thing as LetRec case, but with ALL the defns with it.
           let rec f = v and g = v2 in e2  ~~~~~> [([(let rec f = v and g = v2 in f)/f; (let rec f = v and g = v2 in g)/g]v)/f; (...v2)/g]e2
        *)
          Ast.DeBruijnIndex.create 0 >>= fun debruijn_index_0 ->
          let iddefs, exprs = List.unzip iddef_e_list in
          process_exprs exprs >>= fun (new_es, new_vs) ->
          if not (List.is_empty new_es) then
            match List.zip iddefs new_es with
            | List.Or_unequal_lengths.Ok zipped ->
                Ok
                  (ReduceResult.ReducedToExpr
                     (Ast.Expr.LetRecMutual (zipped, e2)))
            | List.Or_unequal_lengths.Unequal_lengths ->
                Or_error.error
                  "SingleStepReductionError: [FATAL]: at LetRecMutual, the \n\
                  \              length of the list of processed expressions \
                   is not equal to that of the id definitions, which implies a \
                   BUG in process_expr."
                  (Ast.Expr.LetRecMutual (iddef_e_list, e2))
                  [%sexp_of: Ast.Expr.t]
          else
            (* in this case we get a list of values (NOT REDUCED) *)
            new_vs |> List.map ~f:Ast.Value.to_expr |> List.zip iddefs
            |> fun iddef_e_list_or_unequal_lengths ->
            (match iddef_e_list_or_unequal_lengths with
            | List.Or_unequal_lengths.Unequal_lengths ->
                Or_error.error
                  "SingleStepReductionError: [FATAL]: at LetRecMutual, the \n\
                  \              length of the list of processed expressions \
                   is not equal to that of the id definitions, which implies a \
                   BUG in process_expr."
                  (Ast.Expr.LetRecMutual (iddef_e_list, e2))
                  [%sexp_of: Ast.Expr.t]
            | List.Or_unequal_lengths.Ok new_iddef_e_list -> Ok new_iddef_e_list)
            >>= fun new_iddef_e_list ->
            let iddefs, exprs =
              List.map new_iddef_e_list ~f:(fun ((id, typ), _) ->
                  ( (id, typ),
                    Ast.Expr.LetRecMutual
                      ( new_iddef_e_list,
                        Ast.Expr.Identifier
                          (Ast.ObjIdentifier.of_string_and_index
                             (Ast.ObjIdentifier.get_name id)
                             debruijn_index_0) ) ))
              |> List.unzip
            in
            List.map new_iddef_e_list ~f:(fun (_, e) ->
                Substitutions.sim_substitute exprs iddefs e)
            |> Or_error.combine_errors
            >>= fun substituted_expr_list ->
            (* [substituted_v/f; substituted_v2/g]e2 *)
            Substitutions.sim_substitute substituted_expr_list iddefs e2
            >>= fun ev2 -> Ok (ReduceResult.ReducedToExpr ev2)
      | Ast.Expr.Box (tvctx, ctx, e) ->
          Ok (ReduceResult.NotReduced (Ast.Value.Box (tvctx, ctx, e)))
      | Ast.Expr.LetBox (metaid, e, e2) ->
          reduce ~top_level_context ~type_constr_context e >>= fun box_res ->
          ReduceResult.process box_res
            ~reduced:(fun box_e ->
              Ok
                (ReduceResult.ReducedToExpr
                   (Ast.Expr.LetBox (metaid, box_e, e2))))
            ~not_reduced:(fun box_v ->
              match box_v with
              | Ast.Value.Box (tvctx, ctx, e_box) ->
                  Substitutions.meta_substitute tvctx ctx e_box metaid e2
                  |> fun or_error ->
                  Or_error.tag_arg or_error
                    "SingleStepReductionError: Meta substitution error: \
                     metaid, e->v, ctx, v"
                    (metaid, box_v, ctx, e2)
                    [%sexp_of:
                      Ast.MetaIdentifier.t
                      * Ast.Value.t
                      * Ast.Context.t
                      * Ast.Expr.t]
                  >>= fun res_meta_sub ->
                  Ok (ReduceResult.ReducedToExpr res_meta_sub)
              | _ ->
                  error
                    "SingleStepReductionError: type mismatch at LetBox. \
                     [FATAL] should not happen! Type check should have \
                     prevented this."
                    expr [%sexp_of: Ast.Expr.t])
      | Ast.Expr.Closure (_, _, _) ->
          error
            "SingleStepReductionError: One should never have to evaluate a raw \
             closure."
            expr [%sexp_of: Ast.Expr.t]
      | Ast.Expr.Lift (t, expr) ->
          reduce ~top_level_context ~type_constr_context expr >>= fun res ->
          ReduceResult.process res
            ~reduced:(fun new_e ->
              Ok (ReduceResult.ReducedToExpr (Ast.Expr.Lift (t, new_e))))
            ~not_reduced:(fun v ->
              let expr_v = Ast.Value.to_expr_intensional v in
              Ok (ReduceResult.ReducedToVal (Ast.Value.Box ([], [], expr_v))))
      | Ast.Expr.Constr (constr, tlist, e_opt) -> (
          if
            Option.is_none
              (TypeConstrContext.get_typ_from_constr type_constr_context constr)
          then
            error "SingleStepReductionError: FATAL: constructor undefined"
              constr [%sexp_of: Ast.Constructor.t]
          else
            match e_opt with
            | None ->
                Ok
                  (ReduceResult.NotReduced
                     (Ast.Value.Constr (constr, tlist, None)))
            | Some e ->
                reduce ~top_level_context ~type_constr_context e >>= fun res ->
                ReduceResult.process res
                  ~reduced:(fun new_e ->
                    Ok
                      (ReduceResult.ReducedToExpr
                         (Ast.Expr.Constr (constr, tlist, Some new_e))))
                  ~reduced_to_val:(fun v ->
                    Ok
                      (ReduceResult.ReducedToVal
                         (Ast.Value.Constr (constr, tlist, Some v))))
                  ~not_reduced:(fun v ->
                    Ok
                      (ReduceResult.NotReduced
                         (Ast.Value.Constr (constr, tlist, Some v)))))
      | Ast.Expr.Match (e, pattn_expr_list) ->
          reduce ~top_level_context ~type_constr_context e >>= fun res ->
          ReduceResult.process res
            ~reduced:(fun new_e ->
              Ok
                (ReduceResult.ReducedToExpr
                   (Ast.Expr.Match (new_e, pattn_expr_list))))
            ~not_reduced:(fun v ->
              let match_pattn_expr v (pattn, expr) =
                (* Processes the pattern: if not matched, return None; if matched return Some (Value.t Or_error.t) *)
                match (pattn, v) with
                | Ast.Pattern.Wildcard, _ -> Some (Ok expr)
                | Ast.Pattern.Id id, _ ->
                    let expr_of_v = Ast.Value.to_expr v in
                    Substitutions.substitute expr_of_v id expr
                    >>= (fun substituted_expr -> Ok substituted_expr)
                    |> Some
                | Ast.Pattern.Inl id, Ast.Value.Left (_, _, v) ->
                    let expr_of_v = Ast.Value.to_expr v in
                    Substitutions.substitute expr_of_v id expr
                    >>= (fun substituted_expr -> Ok substituted_expr)
                    |> Some
                | Ast.Pattern.Inr id, Ast.Value.Right (_, _, v) ->
                    let expr_of_v = Ast.Value.to_expr v in
                    Substitutions.substitute expr_of_v id expr
                    >>= (fun substituted_expr -> Ok substituted_expr)
                    |> Some
                | Ast.Pattern.Prod id_list, Ast.Value.Prod value_list ->
                    let expr_list = List.map value_list ~f:Ast.Value.to_expr in
                    let idstr_list =
                      List.map id_list ~f:Ast.ObjIdentifier.get_name
                    in
                    Utils.try_zip_list_or_error expr_list idstr_list
                      (Or_error.error
                         "SingleStepReductionError: argument number mismatch \
                          at match clause."
                         (pattn, expr) [%sexp_of: Ast.Pattern.t * Ast.Expr.t])
                    >>= (fun zipped_list ->
                          Substitutions.sim_substitute_from_zipped_list
                            zipped_list expr
                          >>= fun substituted_expr -> Ok substituted_expr)
                    |> Some
                | ( Ast.Pattern.Datatype (constr, []),
                    Ast.Value.Constr (constr2, _, None) ) ->
                    (* CHECK IF constr exists *)
                    if
                      Option.is_none
                        (TypeConstrContext.get_typ_from_constr
                           type_constr_context constr)
                    then
                      error
                        "SingleStepReductionError: FATAL: constructor undefined"
                        constr [%sexp_of: Ast.Constructor.t]
                      |> Some
                    else if not (Ast.Constructor.equal constr constr2) then None
                    else Ok expr |> Some
                | ( Ast.Pattern.Datatype (constr, [ id ]),
                    Ast.Value.Constr (constr2, _, Some v) ) ->
                    if
                      Option.is_none
                        (TypeConstrContext.get_typ_from_constr
                           type_constr_context constr)
                    then
                      error
                        "SingleStepReductionError: FATAL: constructor undefined"
                        constr [%sexp_of: Ast.Constructor.t]
                      |> Some
                    else if not (Ast.Constructor.equal constr constr2) then None
                    else
                      (* If constructors match, no of arguments should match too, otherwise error *)
                      let expr_to_sub_for = Ast.Value.to_expr v in
                      Substitutions.substitute expr_to_sub_for id expr
                      >>= (fun substituted_expr -> Ok substituted_expr)
                      |> Some
                | ( Ast.Pattern.Datatype (constr, id_list),
                    Ast.Value.Constr (constr2, _, Some (Ast.Value.Prod vlist)) )
                  ->
                    if
                      Option.is_none
                        (TypeConstrContext.get_typ_from_constr
                           type_constr_context constr)
                    then
                      error
                        "SingleStepReductionError: FATAL: constructor undefined"
                        constr [%sexp_of: Ast.Constructor.t]
                      |> Some
                    else if not (Ast.Constructor.equal constr constr2) then None
                    else
                      let expr_list = List.map vlist ~f:Ast.Value.to_expr in
                      let idstr_list =
                        List.map id_list ~f:Ast.ObjIdentifier.get_name
                      in
                      Utils.try_zip_list_or_error expr_list idstr_list
                        (Or_error.error
                           "SingleStepReductionError: argument number mismatch \
                            at match clause."
                           (pattn, expr) [%sexp_of: Ast.Pattern.t * Ast.Expr.t])
                      >>= (fun zipped_list ->
                            Substitutions.sim_substitute_from_zipped_list
                              zipped_list expr
                            >>= fun substituted_expr -> Ok substituted_expr)
                      |> Some
                | ( Ast.Pattern.String s,
                    Ast.Value.Constant (Ast.Constant.String s2) ) ->
                    if String.equal s s2 then Some (Ok expr) else None
                | ( Ast.Pattern.ConcatCharString (cid, sid),
                    Ast.Value.Constant (Ast.Constant.String s) ) ->
                    if String.is_empty s then None
                    else
                      let zipped_list =
                        [
                          ( Ast.Expr.Constant
                              (Ast.Constant.Character (String.get s 0)),
                            Ast.ObjIdentifier.get_name cid );
                          ( Ast.Expr.Constant
                              (Ast.Constant.String (String.drop_prefix s 1)),
                            Ast.ObjIdentifier.get_name sid );
                        ]
                      in
                      Substitutions.sim_substitute_from_zipped_list zipped_list
                        expr
                      |> Some
                | _ -> None
              in
              let match_and_exec_result =
                Utils.list_traverse_and_try pattn_expr_list
                  ~f:(fun (pattn, expr) -> match_pattn_expr v (pattn, expr))
              in
              match match_and_exec_result with
              | None ->
                  error
                    "SingleStepReductionError: Pattern matching non-exhaustive."
                    (Ast.Expr.Match (e, pattn_expr_list))
                    [%sexp_of: Ast.Expr.t]
              | Some res_expr_or_error ->
                  res_expr_or_error >>= fun res_expr ->
                  Ok (ReduceResult.ReducedToExpr res_expr))
      | Ast.Expr.EValue v -> Ok (ReduceResult.NotReduced v)
      | Ast.Expr.Ref e ->
          reduce ~top_level_context ~type_constr_context e
          >>= ReduceResult.process
                ~reduced:(fun reduced_e ->
                  Ok (ReduceResult.ReducedToExpr (Ast.Expr.Ref reduced_e)))
                ~not_reduced:(fun v ->
                  Ok
                    (ReduceResult.ReducedToVal
                       (Ast.Value.Constant
                          (Ast.Constant.Reference (Ast.RefCell.ref v)))))
      | Ast.Expr.While (p, e) ->
          Ok
            (ReduceResult.ReducedToExpr
               (Ast.Expr.IfThenElse
                  ( p,
                    Ast.Expr.BinaryOp
                      (Ast.BinaryOperator.SEQ, e, Ast.Expr.While (p, e)),
                    Ast.Expr.Constant Ast.Constant.Unit )))
      | Ast.Expr.Array es -> (
          process_exprs es >>= fun (new_es, new_vs) ->
          if List.is_empty new_es then
            (* Not reduced in the first place *)
            Ok
              (ReduceResult.NotReduced
                 (Ast.Value.Constant
                    (Ast.Constant.Array (Ast.ArrayCell.of_list new_vs))))
          else
            (* Check if all are values *)
            match convert_to_values new_es with
            | None -> Ok (ReduceResult.ReducedToExpr (Ast.Expr.Array new_es))
            | Some vs ->
                Ok
                  (ReduceResult.ReducedToVal
                     (Ast.Value.Constant
                        (Ast.Constant.Array (Ast.ArrayCell.of_list vs)))))
      | Ast.Expr.ArrayAssign (arr, index, expr) ->
          (*TODO: Check that this works.*)
          (*Reduce array*)
          reduce ~top_level_context ~type_constr_context arr
          >>= ReduceResult.process
                ~reduced:(fun e ->
                  Ok
                    (ReduceResult.ReducedToExpr
                       (Ast.Expr.ArrayAssign (e, index, expr))))
                ~not_reduced:(fun arr_v ->
                  (*Array check*)
                  match arr_v with
                  | Ast.Value.Constant (Ast.Constant.Array impl_arr) ->
                      (*Reduce index*)
                      reduce ~top_level_context ~type_constr_context index
                      >>= ReduceResult.process
                            ~reduced:(fun index_e ->
                              Ok
                                (ReduceResult.ReducedToExpr
                                   (Ast.Expr.ArrayAssign
                                      (Ast.Value.to_expr arr_v, index_e, expr))))
                            ~not_reduced:(fun index_v ->
                              (*Index check*)
                              match index_v with
                              | Ast.Value.Constant
                                  (Ast.Constant.Integer index_i) ->
                                  if
                                    index_i < 0
                                    || index_i > Ast.ArrayCell.length impl_arr
                                  then
                                    Or_error.error
                                      "SingleStepReductionError: index out of \
                                       bounds [array_len, index]"
                                      (Ast.ArrayCell.length impl_arr, index_i)
                                      [%sexp_of: int * int]
                                  else
                                    (*Reduce expr*)
                                    reduce ~top_level_context
                                      ~type_constr_context expr
                                    >>= ReduceResult.process
                                          ~reduced:(fun expr_e ->
                                            Ok
                                              (ReduceResult.ReducedToExpr
                                                 (Ast.Expr.ArrayAssign
                                                    ( Ast.Value.to_expr arr_v,
                                                      Ast.Value.to_expr index_v,
                                                      expr_e ))))
                                          ~not_reduced:(fun expr_v ->
                                            (*Set value in array and done.*)
                                            (* impl_arr.(index_i) <- expr_v; *)
                                            Ast.ArrayCell.set impl_arr index_i
                                              expr_v;
                                            Ok
                                              (ReduceResult.ReducedToVal
                                                 (Ast.Value.Constant
                                                    Ast.Constant.Unit)))
                              | _ ->
                                  Or_error.error
                                    "SingleStepReductionError: FATAL: array \
                                     index is not an integer [index]"
                                    index [%sexp_of: Ast.Expr.t])
                  | _ ->
                      Or_error.error
                        "SingleStepReductionError: FATAL: arr is not an array \
                         [arr]"
                        arr [%sexp_of: Ast.Expr.t])
      | Ast.Expr.BigLambda (typevar, e) ->
          Ok (ReduceResult.NotReduced (Ast.Value.BigLambda (typevar, e)))
      | Ast.Expr.TypeApply (e, typ) ->
          reduce ~top_level_context ~type_constr_context e
          >>= ReduceResult.process
                ~reduced:(fun e ->
                  Ok (ReduceResult.ReducedToExpr (Ast.Expr.TypeApply (e, typ))))
                ~not_reduced:(fun value ->
                  match value with
                  | BigLambda (tv, inner_e) ->
                      Substitutions.type_term_substitute typ tv inner_e
                      >>= fun substitued_e ->
                      Ok (ReduceResult.ReducedToExpr substitued_e)
                  | _ ->
                      Or_error.error
                        "SingleStepReductionError: FATAL: can only type apply \
                         on a big lambda. (term)"
                        (Ast.Expr.TypeApply (e, typ))
                        [%sexp_of: Ast.Expr.t])
      | Ast.Expr.Pack (interface, typ, e) ->
          reduce ~top_level_context ~type_constr_context e
          >>= ReduceResult.process
                ~reduced:(fun e ->
                  Ok
                    (ReduceResult.ReducedToExpr
                       (Ast.Expr.Pack (interface, typ, e))))
                ~not_reduced:(fun v ->
                  Ok
                    (ReduceResult.NotReduced
                       (Ast.Value.Pack (interface, typ, v))))
      | Ast.Expr.LetPack (tv, oid, e1, e2) ->
          reduce ~top_level_context ~type_constr_context e1
          >>= ReduceResult.process
                ~reduced:(fun e ->
                  Ok
                    (ReduceResult.ReducedToExpr
                       (Ast.Expr.LetPack (tv, oid, e, e2))))
                ~not_reduced:(fun v ->
                  match v with
                  | Ast.Value.Pack ((_, i_typ), typ, v) ->
                      (* Here we use tv and not i_tv because the actual type variable used is tv.
                         i_tv is only there to specify the interface and has no influence whatsoever to
                         what comes next because it doesn't act as a binder anywhere. *)
                      Substitutions.sim_substitute_with_types [ typ ] [ tv ]
                        [ Ast.Value.to_expr v ]
                        [ (oid, i_typ) ]
                        e2 (* Note: i_typ here serves as a dummy *)
                      >>= fun e2 -> Ok (ReduceResult.ReducedToExpr e2)
                  | _ ->
                      Or_error.error
                        "SingleStepReductionError: FATAL: value given to \
                         unpack doesn't reduce to a pack. (e_to_unpack)"
                        e1 [%sexp_of: Ast.Expr.t]))

let multi_step_reduce ~top_level_context ~type_constr_context ?(verbose = false)
    ?(type_to_check = TypeCheckEachStep.NoCheck) expr =
  let open Or_error.Monad_infix in
  if verbose then
    let rec multi_step_reduce_aux ~top_level_context ~type_constr_context
        ~steps_reversed expr =
      TypeCheckEachStep.type_check_if_needed top_level_context
        type_constr_context
        (List.length steps_reversed)
        expr type_to_check
      >>= fun () ->
      reduce ~top_level_context ~type_constr_context expr >>= fun res ->
      match res with
      | ReduceResult.NotReduced v -> Ok (v, steps_reversed)
      | ReduceResult.ReducedToExpr e ->
          multi_step_reduce_aux ~top_level_context ~type_constr_context
            ~steps_reversed:(e :: steps_reversed) e
      | ReduceResult.ReducedToVal v ->
          Ok (v, Ast.Value.to_expr v :: steps_reversed)
    in
    multi_step_reduce_aux ~top_level_context ~type_constr_context
      ~steps_reversed:[ expr ] expr
    >>= fun (v, expr_list) ->
    Ok (v, List.length expr_list - 1, Some (List.rev expr_list))
  else
    let rec multi_step_reduce_aux ~top_level_context ~type_constr_context ~count
        expr =
      TypeCheckEachStep.type_check_if_needed top_level_context
        type_constr_context count expr type_to_check
      >>= fun () ->
      reduce ~top_level_context ~type_constr_context expr >>= fun res ->
      match res with
      | ReduceResult.NotReduced v -> Ok (v, count)
      | ReduceResult.ReducedToExpr e ->
          multi_step_reduce_aux ~top_level_context ~type_constr_context
            ~count:(count + 1) e
      | ReduceResult.ReducedToVal v -> Ok (v, count + 1)
    in
    multi_step_reduce_aux ~top_level_context ~type_constr_context ~count:0 expr
    >>= fun (v, c) -> Ok (v, c, None)

let evaluate_top_level_defn ?(top_level_context = EvaluationContext.empty)
    ?(type_constr_context = TypeConstrContext.empty) ?(show_step_count = false)
    ?(verbose = false) ?(type_check_each_step = false) top_level_defn =
  let open Or_error.Monad_infix in
  match top_level_defn with
  | Ast.TypedTopLevelDefn.Definition (typ, (id, _), e) ->
      (if type_check_each_step then
       multi_step_reduce ~top_level_context ~type_constr_context ~verbose
         ~type_to_check:
           (if type_check_each_step then TypeCheckEachStep.CheckType typ
           else NoCheck)
         e
      else multi_step_reduce ~top_level_context ~type_constr_context ~verbose e)
      >>= fun (v, count, steps_opt) ->
      let new_context =
        EvaluationContext.set top_level_context
          ~key:(Ast.ObjIdentifier.get_name id)
          ~data:{ rec_preface = []; typ; value = v }
      in
      let count_opt = if show_step_count then Some count else None in
      let verbose_opt =
        let open Option.Monad_infix in
        steps_opt >>= fun steps ->
        Some { Interpreter_common.TopLevelEvaluationResult.steps }
      in
      Ok
        ( TopLevelEvaluationResult.Defn
            ((id, typ), v, None, count_opt, verbose_opt),
          new_context,
          type_constr_context )
  | Ast.TypedTopLevelDefn.RecursiveDefinition (typ, (id, _), e) ->
      multi_step_reduce ~top_level_context ~type_constr_context ~verbose
        ~type_to_check:
          (if type_check_each_step then
           TypeCheckEachStep.CheckRec ([ (id, typ) ], typ)
          else NoCheck)
        e
      >>= fun (v, count, steps_opt) ->
      let new_entry : EvaluationContext.single_record =
        { rec_preface = [ ((id, typ), Ast.Value.to_expr v) ]; typ; value = v }
      in
      let count_opt = if show_step_count then Some count else None in
      let verbose_opt =
        let open Option.Monad_infix in
        steps_opt >>= fun steps ->
        Some { Interpreter_common.TopLevelEvaluationResult.steps }
      in
      let key = Ast.ObjIdentifier.get_name id in
      let new_context =
        EvaluationContext.set top_level_context ~key ~data:new_entry
      in
      Ok
        ( TopLevelEvaluationResult.RecDefn
            ((id, typ), v, None, count_opt, verbose_opt),
          new_context,
          type_constr_context )
  | Ast.TypedTopLevelDefn.Expression (typ, e) ->
      (if type_check_each_step then
       multi_step_reduce ~top_level_context ~type_constr_context ~verbose
         ~type_to_check:(TypeCheckEachStep.CheckType typ) e
      else multi_step_reduce ~top_level_context ~type_constr_context ~verbose e)
      >>= fun (v, count, steps_opt) ->
      let count_opt = if show_step_count then Some count else None in
      let verbose_opt =
        let open Option.Monad_infix in
        steps_opt >>= fun steps ->
        Some { Interpreter_common.TopLevelEvaluationResult.steps }
      in
      Ok
        ( TopLevelEvaluationResult.ExprValue
            (typ, v, None, count_opt, verbose_opt),
          top_level_context,
          type_constr_context )
  | Ast.TypedTopLevelDefn.MutualRecursiveDefinition iddef_e_list ->
      let iddefs = List.map iddef_e_list ~f:(fun (_, iddef, _) -> iddef) in
      List.map iddef_e_list ~f:(fun (typ, iddef, e) ->
          multi_step_reduce ~top_level_context ~type_constr_context ~verbose
            ~type_to_check:
              (if type_check_each_step then
               TypeCheckEachStep.CheckRec (iddefs, typ)
              else NoCheck)
            e
          >>= fun (v, count, verbose_opt) ->
          let count_opt = if show_step_count then Some count else None in
          let verbose_opt =
            let open Option.Monad_infix in
            verbose_opt >>= fun steps ->
            Some { Interpreter_common.TopLevelEvaluationResult.steps }
          in
          Ok (iddef, v, None, count_opt, verbose_opt))
      |> Or_error.combine_errors
      (*Get final result*)
      >>= fun iddef_v_stats_list ->
      (* Add to context *)
      let iddef_v_list =
        List.map iddef_v_stats_list ~f:(fun (iddef, v, _, _, _) -> (iddef, v))
      in
      let rec_preface =
        List.map iddef_v_list ~f:(fun (iddef, v) ->
            (iddef, Ast.Value.to_expr v))
      in
      let kv_pairs =
        List.map iddef_v_list ~f:(fun ((id, typ), v) ->
            let new_entry : EvaluationContext.single_record =
              { rec_preface; typ; value = v }
            in
            (Ast.ObjIdentifier.get_name id, new_entry))
      in
      let new_context = EvaluationContext.set_all top_level_context kv_pairs in
      Ok
        ( TopLevelEvaluationResult.MutRecDefn iddef_v_stats_list,
          new_context,
          type_constr_context )
  | Ast.TypedTopLevelDefn.Directive d -> (
      match d with
      | Ast.Directive.Env ->
          let env = EvaluationContext.show top_level_context in
          let type_env = TypeConstrContext.show type_constr_context in
          let message =
            Printf.sprintf
              "ENV: \n\
               -------------------\n\
               \tVARIABLES: \n\
               %s\n\
               -------------------\n\
               \tDATATYPES: \n\
               %s"
              env type_env
          in
          Ok
            ( TopLevelEvaluationResult.Directive (d, message),
              top_level_context,
              type_constr_context )
      | Ast.Directive.Quit ->
          Ok
            ( TopLevelEvaluationResult.Directive (d, "User Quit."),
              top_level_context,
              type_constr_context )
      | Ast.Directive.Reset ->
          let message = "Cleared Env" in
          let new_env = EvaluationContext.empty in
          Ok
            ( TopLevelEvaluationResult.Directive (d, message),
              new_env,
              type_constr_context ))
  | Ast.TypedTopLevelDefn.DatatypeDecl id_constr_typ_list_list ->
      List.fold id_constr_typ_list_list ~init:(Ok type_constr_context)
        ~f:(fun acc (tvctx, tid, constructor_type_list) ->
          acc >>= fun new_typ_ctx ->
          TypeConstrContext.add_typ_from_decl new_typ_ctx
            (tvctx, tid, constructor_type_list))
      >>= fun new_typ_context ->
      Ok
        ( TopLevelEvaluationResult.DatatypeDecl id_constr_typ_list_list,
          top_level_context,
          new_typ_context )
