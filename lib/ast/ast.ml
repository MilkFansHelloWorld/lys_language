open Core
module StringMap = Map.Make (String)

(*Map from Past.Identifier to anything*)

module DeBruijnIndex : sig
  (*Implementation of De Bruijn Indices -- encapsulated*)
  type t [@@deriving sexp, show, compare, equal]

  val none : t
  val top_level : t
  val create : int -> t
  val shift : t -> int -> t Or_error.t
  val value : t -> default:int -> int
end = struct
  type t = NotSet | TopLevel | InExpr of int
  [@@deriving sexp, show, compare, equal]

  let none = NotSet
  let top_level = TopLevel

  let create v =
    if v >= 0 then InExpr v else failwith "De Bruijn Index must be >= 0."

  let shift i k =
    match i with
    | InExpr v ->
        if v + k >= 0 then Ok (InExpr (v + k))
        else
          error
            "DeBruijnIndexError: Shifting failed: the value of the index can't \
             be negative."
            (v, k) [%sexp_of: int * int]
    | _ -> Ok i

  let value x ~default = match x with InExpr v -> v | _ -> default
end

module type ObjIdentifier_type = sig
  type t [@@deriving sexp, show, compare, equal]

  val of_string : string -> t
  val of_past : Past.Identifier.t -> t
  val of_string_and_index : string -> DeBruijnIndex.t -> t
  val get_name : t -> string
  val get_debruijn_index : t -> DeBruijnIndex.t

  val populate_index :
    t ->
    current_ast_level:int ->
    current_identifiers:int StringMap.t ->
    current_meta_ast_level:int ->
    current_meta_identifiers:int StringMap.t ->
    t Or_error.t

  val shift : t -> offset:int -> t Or_error.t
end

module type TypeIdentifier_type = sig
  (*Unused for now*)
  type t [@@deriving sexp, show, compare, equal]

  val of_string : string -> t
  val of_past : Past.Identifier.t -> t
end

module type MetaIdentifier_type = sig
  type t [@@deriving sexp, show, compare, equal]

  val of_string : string -> t
  val of_past : Past.Identifier.t -> t
  val of_string_and_index : string -> DeBruijnIndex.t -> t
  val get_name : t -> string
  val get_debruijn_index : t -> DeBruijnIndex.t

  val populate_index :
    t ->
    current_ast_level:int ->
    current_identifiers:int StringMap.t ->
    current_meta_ast_level:int ->
    current_meta_identifiers:int StringMap.t ->
    t Or_error.t

  val shift : t -> offset:int -> t Or_error.t
end

module rec ObjIdentifier : ObjIdentifier_type = struct
  (*Here we identify the binder via the De Bruijn index.*)
  type t = string * DeBruijnIndex.t [@@deriving sexp, show, compare, equal]

  let of_string x = (x, DeBruijnIndex.none)
  (* Dummy init at -1. TODO: Change design *)

  let of_past (past_identifier : Past.Identifier.t) =
    (past_identifier, DeBruijnIndex.none)

  let of_string_and_index str index = (str, index)
  let get_name (id, _) = id
  let get_debruijn_index (_, index) = index

  let populate_index (id, _) ~current_ast_level ~current_identifiers
      ~current_meta_ast_level:_ ~current_meta_identifiers:_ =
    (* The concept of the De Bruijn index thing is to remember the current level. *)
    (* If ~current_ast_level or ~current_identifiers not given, assume that we're talking about an identifier definition, so the index returned should be Index.none *)
    let level_opt = StringMap.find current_identifiers id in
    match level_opt with
    | None ->
        Ok (id, DeBruijnIndex.top_level) (*Assume top level if not in context.*)
    | Some lvl -> Ok (id, DeBruijnIndex.create (current_ast_level - lvl - 1))

  (*-1 because we have levels as the number of binders the current construct is under e.g. fun x (level 0) -> fun y (level 1) -> x (level 2) + y (level 2)*)
  let shift (id, index) ~offset =
    let open Or_error.Monad_infix in
    DeBruijnIndex.shift index offset >>= fun new_index -> Ok (id, new_index)
end

and MetaIdentifier : MetaIdentifier_type = struct
  (*Here we shall identifier each variable by BOTH the index AND the variable name.*)
  type t = string * DeBruijnIndex.t [@@deriving sexp, show, compare, equal]

  let of_string x = (x, DeBruijnIndex.none)

  let of_past (past_identifier : Past.Identifier.t) =
    (past_identifier, DeBruijnIndex.none)

  let of_string_and_index str index = (str, index)
  let get_name (id, _) = id
  let get_debruijn_index (_, index) = index

  let populate_index (id, _) ~current_ast_level:_ ~current_identifiers:_
      ~current_meta_ast_level ~current_meta_identifiers =
    (* The concept of the De Bruijn index thing is to remember the current level. *)
    (* If ~current_ast_level or ~current_identifiers not given, assume that we're talking about an identifier definition, so the index returned should be Index.none *)
    let level_opt = StringMap.find current_meta_identifiers id in
    match level_opt with
    | None ->
        error
          (Printf.sprintf
             "DeBruijnPopulationError[META]: the identifier %s is not found in \
              the context HENCE not bound."
             id)
          (id, current_meta_identifiers)
          [%sexp_of: string * int StringMap.t]
        (* Here we do so because we postpone the error of not really finding the identifier in the context to type checking *)
    | Some lvl ->
        Ok (id, DeBruijnIndex.create (current_meta_ast_level - lvl - 1))

  (*-1 because we have levels as the number of binders the current construct is under e.g. fun x (level 0) -> fun y (level 1) -> x (level 2) + y (level 2)*)
  let shift (id, index) ~offset =
    let open Or_error.Monad_infix in
    DeBruijnIndex.shift index offset >>= fun new_index -> Ok (id, new_index)
end

and TypeIdentifier : TypeIdentifier_type = struct
  type t = string [@@deriving sexp, show, compare, equal]

  let of_string x = x
  let of_past (past_identifier : Past.Identifier.t) = past_identifier
end

and Typ : sig
  type t =
    | TUnit
    | TBool
    | TInt
    | TIdentifier of TypeIdentifier.t
    | TFun of t * t
    | TBox of Context.t * t
    | TProd of t * t
    | TSum of t * t
  [@@deriving sexp, show, compare, equal]

  val of_past : Past.Typ.t -> t
end = struct
  type t =
    | TUnit
    | TBool
    | TInt
    | TIdentifier of TypeIdentifier.t
    | TFun of t * t
    | TBox of Context.t * t
    | TProd of t * t
    | TSum of t * t
  [@@deriving sexp, show, compare, equal]

  let rec of_past = function
    | Past.Typ.TUnit -> TUnit
    | Past.Typ.TBool -> TBool
    | Past.Typ.TInt -> TInt
    | Past.Typ.TIdentifier id -> TIdentifier (TypeIdentifier.of_past id)
    | Past.Typ.TFun (t1, t2) -> TFun (of_past t1, of_past t2)
    | Past.Typ.TBox (ctx, t1) -> TBox (Context.of_past ctx, of_past t1)
    | Past.Typ.TProd (t1, t2) -> TProd (of_past t1, of_past t2)
    | Past.Typ.TSum (t1, t2) -> TSum (of_past t1, of_past t2)
end

and IdentifierDefn : sig
  type t = ObjIdentifier.t * Typ.t [@@deriving sexp, show, compare, equal]

  val of_past : Past.IdentifierDefn.t -> t
end = struct
  type t = ObjIdentifier.t * Typ.t [@@deriving sexp, show, compare, equal]

  let of_past (id, t1) = (ObjIdentifier.of_past id, Typ.of_past t1)
end

and Context : sig
  type t = IdentifierDefn.t list [@@deriving sexp, show, compare, equal]

  val of_past : Past.Context.t -> t
end = struct
  type t = IdentifierDefn.t list [@@deriving sexp, show, compare, equal]

  let of_past ident_defn_list =
    List.map ident_defn_list ~f:IdentifierDefn.of_past
end

and BinaryOperator : sig
  type t =
    | ADD
    | SUB
    | MUL
    | DIV
    | MOD
    | EQ
    | NEQ
    | GTE
    | GT
    | LTE
    | LT
    | AND
    | OR
  [@@deriving sexp, show, compare, equal]

  val of_past : Past.BinaryOperator.t -> t
end = struct
  type t =
    | ADD
    | SUB
    | MUL
    | DIV
    | MOD
    | EQ
    | NEQ
    | GTE
    | GT
    | LTE
    | LT
    | AND
    | OR
  [@@deriving sexp, show, compare, equal]

  let of_past = function
    | Past.BinaryOperator.ADD -> ADD
    | Past.BinaryOperator.SUB -> SUB
    | Past.BinaryOperator.MUL -> MUL
    | Past.BinaryOperator.DIV -> DIV
    | Past.BinaryOperator.MOD -> MOD
    | Past.BinaryOperator.EQ -> EQ
    | Past.BinaryOperator.NEQ -> NEQ
    | Past.BinaryOperator.GTE -> GTE
    | Past.BinaryOperator.GT -> GT
    | Past.BinaryOperator.LTE -> LTE
    | Past.BinaryOperator.LT -> LT
    | Past.BinaryOperator.AND -> AND
    | Past.BinaryOperator.OR -> OR
end

and UnaryOperator : sig
  type t = NEG | NOT [@@deriving sexp, show, compare, equal]

  val of_past : Past.UnaryOperator.t -> t
end = struct
  type t = NEG | NOT [@@deriving sexp, show, compare, equal]

  let of_past = function
    | Past.UnaryOperator.NEG -> NEG
    | Past.UnaryOperator.NOT -> NOT
end

and Constant : sig
  type t = Integer of int | Boolean of bool | Unit
  [@@deriving sexp, show, compare, equal]

  val of_past : Past.Constant.t -> t
end = struct
  type t = Integer of int | Boolean of bool | Unit
  [@@deriving sexp, show, compare, equal]

  let of_past = function
    | Past.Constant.Integer i -> Integer i
    | Past.Constant.Boolean b -> Boolean b
    | Past.Constant.Unit -> Unit
end

and Expr : sig
  type t =
    | Identifier of ObjIdentifier.t (*x*)
    | Constant of Constant.t (*c*)
    | UnaryOp of UnaryOperator.t * t (*unop e*)
    | BinaryOp of BinaryOperator.t * t * t (*e op e'*)
    | Prod of t * t (*(e, e')*)
    | Fst of t (*fst e*)
    | Snd of t (*snd e*)
    | Left of Typ.t * Typ.t * t (*L[A,B] e*)
    | Right of Typ.t * Typ.t * t (*R[A,B] e*)
    | Match of t * IdentifierDefn.t * t * IdentifierDefn.t * t
      (*match e with
        L (x: A) -> e' | R (y: B) -> e'' translates to 1 expr and 2 lambdas*)
    | Lambda of IdentifierDefn.t * t (*fun (x : A) -> e*)
    | Application of t * t (*e e'*)
    | IfThenElse of t * t * t (*if e then e' else e''*)
    | LetBinding of IdentifierDefn.t * t * t (*let x: A = e in e'*)
    | LetRec of IdentifierDefn.t * t * t
      (*let rec f: A->B =
        e[f] in e'*)
    | Box of Context.t * t (*box (x:A, y:B |- e)*)
    | LetBox of MetaIdentifier.t * t * t (*let box u = e in e'*)
    | Closure of MetaIdentifier.t * t list (*u with (e1, e2, e3, ...)*)
  [@@deriving sexp, show, compare, equal]

  val of_past : Past.Expr.t -> t

  val populate_index :
    t ->
    current_ast_level:int ->
    current_identifiers:int StringMap.t ->
    current_meta_ast_level:int ->
    current_meta_identifiers:int StringMap.t ->
    t Or_error.t

  val shift_indices : t -> obj_offset:int -> meta_offset:int -> t Or_error.t
end = struct
  type t =
    | Identifier of ObjIdentifier.t (*x*)
    | Constant of Constant.t (*c*)
    | UnaryOp of UnaryOperator.t * t (*unop e*)
    | BinaryOp of BinaryOperator.t * t * t (*e op e'*)
    | Prod of t * t (*(e, e')*)
    | Fst of t (*fst e*)
    | Snd of t (*snd e*)
    | Left of Typ.t * Typ.t * t (*L[A,B] e*)
    | Right of Typ.t * Typ.t * t (*R[A,B] e*)
    | Match of t * IdentifierDefn.t * t * IdentifierDefn.t * t
      (*match e with
        L (x: A) -> e' | R (y: B) -> e'' translates to 1 expr and 2 lambdas*)
    | Lambda of IdentifierDefn.t * t (*fun (x : A) -> e*)
    | Application of t * t (*e e'*)
    | IfThenElse of t * t * t (*if e then e' else e''*)
    | LetBinding of IdentifierDefn.t * t * t (*let x: A = e in e'*)
    | LetRec of IdentifierDefn.t * t * t
      (*let rec f: A->B =
        e[f] in e'*)
    | Box of Context.t * t (*box (x:A, y:B |- e)*)
    | LetBox of MetaIdentifier.t * t * t (*let box u = e in e'*)
    | Closure of MetaIdentifier.t * t list (*u with (e1, e2, e3, ...)*)
  [@@deriving sexp, show, compare, equal]

  let rec of_past = function
    | Past.Expr.Identifier id -> Identifier (ObjIdentifier.of_past id)
    | Past.Expr.Constant c -> Constant (Constant.of_past c)
    | Past.Expr.UnaryOp (op, expr) ->
        UnaryOp (UnaryOperator.of_past op, of_past expr)
    | Past.Expr.BinaryOp (op, expr, expr2) ->
        BinaryOp (BinaryOperator.of_past op, of_past expr, of_past expr2)
    | Past.Expr.Prod (expr1, expr2) -> Prod (of_past expr1, of_past expr2)
    | Past.Expr.Fst expr -> Fst (of_past expr)
    | Past.Expr.Snd expr -> Snd (of_past expr)
    | Past.Expr.Left (t1, t2, expr) ->
        Left (Typ.of_past t1, Typ.of_past t2, of_past expr)
    | Past.Expr.Right (t1, t2, expr) ->
        Right (Typ.of_past t1, Typ.of_past t2, of_past expr)
    | Past.Expr.Match (e, iddef1, e1, iddef2, e2) ->
        Match
          ( of_past e,
            IdentifierDefn.of_past iddef1,
            of_past e1,
            IdentifierDefn.of_past iddef2,
            of_past e2 )
    | Past.Expr.Lambda (iddef, e) ->
        Lambda (IdentifierDefn.of_past iddef, of_past e)
    | Past.Expr.Application (e1, e2) -> Application (of_past e1, of_past e2)
    | Past.Expr.IfThenElse (b, e1, e2) ->
        IfThenElse (of_past b, of_past e1, of_past e2)
    | Past.Expr.LetBinding (iddef, e, e2) ->
        LetBinding (IdentifierDefn.of_past iddef, of_past e, of_past e2)
    | Past.Expr.LetRec (iddef, e, e2) ->
        LetRec (IdentifierDefn.of_past iddef, of_past e, of_past e2)
    | Past.Expr.Box (ctx, e) -> Box (Context.of_past ctx, of_past e)
    | Past.Expr.LetBox (metaid, e, e2) ->
        LetBox (MetaIdentifier.of_past metaid, of_past e, of_past e2)
    | Past.Expr.Closure (metaid, exprs) ->
        Closure (MetaIdentifier.of_past metaid, List.map exprs ~f:of_past)

  let rec populate_index expr ~current_ast_level ~current_identifiers
      ~current_meta_ast_level ~current_meta_identifiers =
    let open Or_error.Monad_infix in
    match expr with
    | Identifier id ->
        ObjIdentifier.populate_index id ~current_ast_level ~current_identifiers
          ~current_meta_ast_level ~current_meta_identifiers
        >>= fun id -> Ok (Identifier id)
        (*Addition for De Bruijn*)
    | Constant c -> Ok (Constant c)
    | UnaryOp (op, expr) ->
        populate_index expr ~current_ast_level ~current_identifiers
          ~current_meta_ast_level ~current_meta_identifiers
        >>= fun expr -> Ok (UnaryOp (op, expr))
    | BinaryOp (op, expr, expr2) ->
        populate_index expr ~current_ast_level ~current_identifiers
          ~current_meta_ast_level ~current_meta_identifiers
        >>= fun expr ->
        populate_index expr2 ~current_ast_level ~current_identifiers
          ~current_meta_ast_level ~current_meta_identifiers
        >>= fun expr2 -> Ok (BinaryOp (op, expr, expr2))
    | Prod (expr1, expr2) ->
        populate_index expr1 ~current_ast_level ~current_identifiers
          ~current_meta_ast_level ~current_meta_identifiers
        >>= fun expr1 ->
        populate_index expr2 ~current_ast_level ~current_identifiers
          ~current_meta_ast_level ~current_meta_identifiers
        >>= fun expr2 -> Ok (Prod (expr1, expr2))
    | Fst expr ->
        populate_index expr ~current_ast_level ~current_identifiers
          ~current_meta_ast_level ~current_meta_identifiers
        >>= fun expr -> Ok (Fst expr)
    | Snd expr ->
        populate_index expr ~current_ast_level ~current_identifiers
          ~current_meta_ast_level ~current_meta_identifiers
        >>= fun expr -> Ok (Snd expr)
    | Left (t1, t2, expr) ->
        populate_index expr ~current_ast_level ~current_identifiers
          ~current_meta_ast_level ~current_meta_identifiers
        >>= fun expr -> Ok (Left (t1, t2, expr))
    | Right (t1, t2, expr) ->
        populate_index expr ~current_ast_level ~current_identifiers
          ~current_meta_ast_level ~current_meta_identifiers
        >>= fun expr -> Ok (Right (t1, t2, expr))
    | Match (e, iddef1, e1, iddef2, e2) ->
        (*Addition for De Bruijn*)
        let id1, _ = iddef1 and id2, _ = iddef2 in
        let new_current_identifiers_1 =
          StringMap.set current_identifiers
            ~key:(ObjIdentifier.get_name id1)
            ~data:current_ast_level
        in
        let new_current_identifiers_2 =
          StringMap.set current_identifiers
            ~key:(ObjIdentifier.get_name id2)
            ~data:current_ast_level
        in
        let new_level = current_ast_level + 1 in
        populate_index e ~current_ast_level ~current_identifiers
          ~current_meta_ast_level ~current_meta_identifiers
        >>= fun e ->
        populate_index e1 ~current_ast_level:new_level
          ~current_identifiers:new_current_identifiers_1 ~current_meta_ast_level
          ~current_meta_identifiers
        >>= fun e1 ->
        populate_index e2 ~current_ast_level:new_level
          ~current_identifiers:new_current_identifiers_2 ~current_meta_ast_level
          ~current_meta_identifiers
        >>= fun e2 ->
        (*We don't need to modify iddefs because the identifiers inside are already having the right index, i.e. None*)
        Ok (Match (e, iddef1, e1, iddef2, e2))
    | Lambda (iddef, e) ->
        (*Addition for De Bruijn*)
        let id, _ = iddef in
        let new_current_identifiers =
          StringMap.set current_identifiers
            ~key:(ObjIdentifier.get_name id)
            ~data:current_ast_level
        in
        let new_level = current_ast_level + 1 in
        populate_index e ~current_ast_level:new_level
          ~current_identifiers:new_current_identifiers ~current_meta_ast_level
          ~current_meta_identifiers
        >>= fun e -> Ok (Lambda (iddef, e))
    | Application (e1, e2) ->
        populate_index e1 ~current_ast_level ~current_identifiers
          ~current_meta_ast_level ~current_meta_identifiers
        >>= fun e1 ->
        populate_index e2 ~current_ast_level ~current_identifiers
          ~current_meta_ast_level ~current_meta_identifiers
        >>= fun e2 -> Ok (Application (e1, e2))
    | IfThenElse (b, e1, e2) ->
        populate_index b ~current_ast_level ~current_identifiers
          ~current_meta_ast_level ~current_meta_identifiers
        >>= fun b ->
        populate_index e1 ~current_ast_level ~current_identifiers
          ~current_meta_ast_level ~current_meta_identifiers
        >>= fun e1 ->
        populate_index e2 ~current_ast_level ~current_identifiers
          ~current_meta_ast_level ~current_meta_identifiers
        >>= fun e2 -> Ok (IfThenElse (b, e1, e2))
    | LetBinding (iddef, e, e2) ->
        let id, _ = iddef in
        let new_current_identifiers =
          StringMap.set current_identifiers
            ~key:(ObjIdentifier.get_name id)
            ~data:current_ast_level
        in
        let new_level = current_ast_level + 1 in
        populate_index e ~current_ast_level ~current_identifiers
          ~current_meta_ast_level ~current_meta_identifiers
        >>= fun e ->
        populate_index e2 ~current_ast_level:new_level
          ~current_identifiers:new_current_identifiers ~current_meta_ast_level
          ~current_meta_identifiers
        >>= fun e2 -> Ok (LetBinding (iddef, e, e2))
    | LetRec (iddef, e, e2) ->
        (*Addition for De Bruijn indices:
          Importantly, we have let rec f (level n) = e (level n+1) in e'(level n+1)*)
        let id, _ = iddef in
        let new_level = current_ast_level + 1 in
        let new_current_identifiers =
          StringMap.set current_identifiers
            ~key:(ObjIdentifier.get_name id)
            ~data:current_ast_level
        in
        populate_index e ~current_ast_level:new_level
          ~current_identifiers:new_current_identifiers ~current_meta_ast_level
          ~current_meta_identifiers
        >>= fun e ->
        populate_index e2 ~current_ast_level:new_level
          ~current_identifiers:new_current_identifiers ~current_meta_ast_level
          ~current_meta_identifiers
        >>= fun e2 -> Ok (LetRec (iddef, e, e2))
    | Box (ctx, e) ->
        (*
          Explanation: ctx is a list of iddefn so no need to populate indices; we create a fresh context with nothing in it like for a closure, and
          base all our De Bruijn indices from that, starting from 0, ignoring whatever is outside completely.
          However, the box still has access to meta variables from outside; just not object variables. TODO: Generalise
        *)
        Or_error.tag
          ~tag:
            "DeBruijnPopulationError[OBJECT]: There are duplicated identifier \
             definitions in the box context."
          (StringMap.of_alist_or_error
             (List.map ctx ~f:(fun (id, _) -> (ObjIdentifier.get_name id, 0))))
        >>= fun new_current_identifiers ->
        populate_index e ~current_ast_level:1
          ~current_identifiers:new_current_identifiers ~current_meta_ast_level
          ~current_meta_identifiers
        >>= fun e -> Ok (Box (ctx, e))
    | LetBox (metaid, e, e2) ->
        let new_current_meta_identifiers =
          StringMap.set current_meta_identifiers
            ~key:(MetaIdentifier.get_name metaid)
            ~data:current_meta_ast_level
        in
        let new_meta_ast_level = current_meta_ast_level + 1 in
        populate_index e ~current_ast_level ~current_identifiers
          ~current_meta_ast_level ~current_meta_identifiers
        >>= fun e ->
        populate_index e2 ~current_ast_level ~current_identifiers
          ~current_meta_ast_level:new_meta_ast_level
          ~current_meta_identifiers:new_current_meta_identifiers
        >>= fun e2 -> Ok (LetBox (metaid, e, e2))
    | Closure (metaid, exprs) ->
        let populated_expr_or_error_list =
          List.map exprs ~f:(fun e ->
              populate_index e ~current_ast_level ~current_identifiers
                ~current_meta_ast_level ~current_meta_identifiers)
        in
        Or_error.tag
          ~tag:
            "DeBruijnPopulationError[OBJECT]: Error in explicit substitution \
             of a closure"
          (Or_error.combine_errors populated_expr_or_error_list)
        >>= fun exprs ->
        MetaIdentifier.populate_index metaid ~current_ast_level
          ~current_identifiers ~current_meta_ast_level ~current_meta_identifiers
        >>= fun metaid -> Ok (Closure (metaid, exprs))

  let rec shift_indices expr ~obj_offset ~meta_offset =
    let open Or_error.Monad_infix in
    match expr with
    | Identifier id ->
        Or_error.tag
          ~tag:"DeBruijnShiftingError[OBJECT]: Shifting object index failed."
          (ObjIdentifier.shift id ~offset:obj_offset)
        >>= fun id -> Ok (Identifier id)
    | Constant c -> Ok (Constant c)
    | UnaryOp (op, expr) ->
        shift_indices expr ~obj_offset ~meta_offset >>= fun expr ->
        Ok (UnaryOp (op, expr))
    | BinaryOp (op, expr, expr2) ->
        shift_indices expr ~obj_offset ~meta_offset >>= fun expr ->
        shift_indices expr2 ~obj_offset ~meta_offset >>= fun expr2 ->
        Ok (BinaryOp (op, expr, expr2))
    | Prod (expr1, expr2) ->
        shift_indices expr1 ~obj_offset ~meta_offset >>= fun expr1 ->
        shift_indices expr2 ~obj_offset ~meta_offset >>= fun expr2 ->
        Ok (Prod (expr1, expr2))
    | Fst expr ->
        shift_indices expr ~obj_offset ~meta_offset >>= fun expr ->
        Ok (Fst expr)
    | Snd expr ->
        shift_indices expr ~obj_offset ~meta_offset >>= fun expr ->
        Ok (Snd expr)
    | Left (t1, t2, expr) ->
        shift_indices expr ~obj_offset ~meta_offset >>= fun expr ->
        Ok (Left (t1, t2, expr))
    | Right (t1, t2, expr) ->
        shift_indices expr ~obj_offset ~meta_offset >>= fun expr ->
        Ok (Right (t1, t2, expr))
    | Match (e, iddef1, e1, iddef2, e2) ->
        shift_indices e ~obj_offset ~meta_offset >>= fun e ->
        shift_indices e1 ~obj_offset ~meta_offset >>= fun e1 ->
        shift_indices e2 ~obj_offset ~meta_offset >>= fun e2 ->
        Ok (Match (e, iddef1, e1, iddef2, e2))
    | Lambda (iddef, e) ->
        shift_indices e ~obj_offset ~meta_offset >>= fun e ->
        Ok (Lambda (iddef, e))
    | Application (e1, e2) ->
        shift_indices e1 ~obj_offset ~meta_offset >>= fun e1 ->
        shift_indices e2 ~obj_offset ~meta_offset >>= fun e2 ->
        Ok (Application (e1, e2))
    | IfThenElse (b, e1, e2) ->
        shift_indices b ~obj_offset ~meta_offset >>= fun b ->
        shift_indices e1 ~obj_offset ~meta_offset >>= fun e1 ->
        shift_indices e2 ~obj_offset ~meta_offset >>= fun e2 ->
        Ok (IfThenElse (b, e1, e2))
    | LetBinding (iddef, e, e2) ->
        shift_indices e ~obj_offset ~meta_offset >>= fun e ->
        shift_indices e2 ~obj_offset ~meta_offset >>= fun e2 ->
        Ok (LetBinding (iddef, e, e2))
    | LetRec (iddef, e, e2) ->
        shift_indices e ~obj_offset ~meta_offset >>= fun e ->
        shift_indices e2 ~obj_offset ~meta_offset >>= fun e2 ->
        Ok (LetRec (iddef, e, e2))
    | Box (ctx, e) ->
        shift_indices e ~obj_offset ~meta_offset >>= fun e -> Ok (Box (ctx, e))
    | LetBox (metaid, e, e2) ->
        shift_indices e ~obj_offset ~meta_offset >>= fun e ->
        shift_indices e2 ~obj_offset ~meta_offset >>= fun e2 ->
        Ok (LetBox (metaid, e, e2))
    | Closure (metaid, exprs) ->
        let populated_expr_or_error_list =
          List.map exprs ~f:(fun e -> shift_indices e ~obj_offset ~meta_offset)
        in
        Or_error.tag
          ~tag:
            "DeBruijnShiftingError[OBJECT]: Error in the explicit substitution \
             term of a closure"
          (Or_error.combine_errors populated_expr_or_error_list)
        >>= fun exprs ->
        Or_error.tag
          ~tag:"DeBruijnShiftingError[META]: Shifting meta index failed."
          (MetaIdentifier.shift metaid ~offset:meta_offset)
        >>= fun metaid -> Ok (Closure (metaid, exprs))
end

and Directive : sig
  type t = Reset | Env | Quit [@@deriving sexp, show, compare, equal]

  val of_past : Past.Directive.t -> t
end = struct
  type t = Reset | Env | Quit [@@deriving sexp, show, compare, equal]

  let of_past = function
    | Past.Directive.Reset -> Reset
    | Past.Directive.Env -> Env
    | Past.Directive.Quit -> Quit
end

and TopLevelDefn : sig
  type t =
    | Definition of IdentifierDefn.t * Expr.t
    | RecursiveDefinition of IdentifierDefn.t * Expr.t
    | Expression of Expr.t
    | Directive of Directive.t
  [@@deriving sexp, show, compare, equal]

  val of_past : Past.TopLevelDefn.t -> t
end = struct
  (*Note added type for defns (not useful for now but useful for when adding inference) and exprs for the REPL*)
  type t =
    | Definition of IdentifierDefn.t * Expr.t
    | RecursiveDefinition of IdentifierDefn.t * Expr.t
    | Expression of Expr.t
    | Directive of Directive.t
  [@@deriving sexp, show, compare, equal]

  let of_past = function
    | Past.TopLevelDefn.Definition (iddef, e) ->
        Definition (IdentifierDefn.of_past iddef, Expr.of_past e)
    | Past.TopLevelDefn.RecursiveDefinition (iddef, e) ->
        RecursiveDefinition (IdentifierDefn.of_past iddef, Expr.of_past e)
    | Past.TopLevelDefn.Expression e -> Expression (Expr.of_past e)
    | Past.TopLevelDefn.Directive d -> Directive (Directive.of_past d)
end

and Program : sig
  type t = TopLevelDefn.t list [@@deriving sexp, show, compare, equal]

  val of_past : Past.Program.t -> t
end = struct
  type t = TopLevelDefn.t list [@@deriving sexp, show, compare, equal]

  let of_past progs = List.map progs ~f:TopLevelDefn.of_past
end

module TypedTopLevelDefn : sig
  type t =
    | Definition of Typ.t * IdentifierDefn.t * Expr.t
    | RecursiveDefinition of Typ.t * IdentifierDefn.t * Expr.t
    | Expression of Typ.t * Expr.t
    | Directive of Directive.t
  [@@deriving sexp, show, compare, equal]

  val populate_index : t -> t Or_error.t
  (* Top level = fold over each defn and step the current_identifiers with the top level context. The meta identifier context starts always at empty. *)
end = struct
  (*Note added type for defns (not useful for now but useful for when adding inference) and exprs for the REPL*)
  type t =
    | Definition of Typ.t * IdentifierDefn.t * Expr.t
    | RecursiveDefinition of Typ.t * IdentifierDefn.t * Expr.t
    | Expression of Typ.t * Expr.t
    | Directive of Directive.t
  [@@deriving sexp, show, compare, equal]

  let populate_index typed_defn =
    let open Or_error.Monad_infix in
    match typed_defn with
    | Definition (typ, (id, typ2), expr) ->
        Expr.populate_index expr ~current_ast_level:0
          ~current_identifiers:StringMap.empty ~current_meta_ast_level:0
          ~current_meta_identifiers:StringMap.empty
        >>= fun expr -> Ok (Definition (typ, (id, typ2), expr))
    | RecursiveDefinition (typ, (id, typ2), expr) ->
        let new_current_identifiers =
          StringMap.set StringMap.empty ~key:(ObjIdentifier.get_name id) ~data:0
        in
        Expr.populate_index expr ~current_ast_level:1
          ~current_identifiers:new_current_identifiers ~current_meta_ast_level:0
          ~current_meta_identifiers:StringMap.empty
        >>= fun expr -> Ok (RecursiveDefinition (typ, (id, typ2), expr))
    | Expression (typ, expr) ->
        Expr.populate_index expr ~current_ast_level:0
          ~current_identifiers:StringMap.empty ~current_meta_ast_level:0
          ~current_meta_identifiers:StringMap.empty
        >>= fun expr -> Ok (Expression (typ, expr))
    | Directive d -> Ok (Directive d)
end

module TypedProgram : sig
  type t = TypedTopLevelDefn.t list [@@deriving sexp, show, compare, equal]

  val populate_index : t -> t Or_error.t
end = struct
  type t = TypedTopLevelDefn.t list [@@deriving sexp, show, compare, equal]

  let populate_index program =
    List.map program ~f:TypedTopLevelDefn.populate_index
    |> Or_error.combine_errors
end
