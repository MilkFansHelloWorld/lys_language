open Lys_ast
open Lys_utils
open Core

module EvaluationContext : sig
  type single_record = { typ : Ast.Typ.t; is_rec : bool; value : Ast.Value.t }
  [@@deriving sexp, show, compare, equal]

  type t = single_record String_map.t [@@deriving sexp, compare, equal]

  (*Map from object id to record (expr and is_rec)*)
  val set : t -> key:string -> data:single_record -> t
  val find_or_error : t -> string -> single_record Or_error.t
  val empty : t
  val show : t -> string
end

(* val reduce : (* Single step *)
   top_level_context:EvaluationContext.t -> expr:Ast.Expr.t -> Ast.Expr.t *)

(* Glue multiple steps *)
val multi_step_reduce :
  top_level_context:EvaluationContext.t ->
  expr:Ast.Expr.t ->
  Ast.Value.t Or_error.t

(* val evaluate : (* Independent, big step *)
   top_level_context:EvaluationContext.t -> expr:Ast.Expr.t -> Ast.Expr.t *)
module TopLevelEvaluationResult : sig
  type t [@@deriving sexp, compare, equal, show]

  val get_str_output : t -> string
end

val evaluate_program :
  ?top_level_context:EvaluationContext.t ->
  Ast.TypedProgram.t ->
  TopLevelEvaluationResult.t list Or_error.t
