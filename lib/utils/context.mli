module type Context_type = sig
  type ('a, 'b) s [@@deriving sexp, equal, compare]

  module type Key_type = sig
    type t [@@deriving sexp, equal, compare]
  end

  module type S = sig
    module Key : Key_type

    type 'b t = (Key.t, 'b) s [@@deriving sexp, equal, compare]

    val create_empty_context : unit -> 'b t
    val add_mapping : 'b t -> Key.t -> 'b -> 'b t

    (* val delete_last_mapping : 'b t -> Key.t -> 'b t *)
    val get_last_mapping : 'b t -> Key.t -> 'b option
    val add_all_mappings : 'b t -> (Key.t * 'b) list -> 'b t
    val is_in_context : 'b t -> Key.t -> bool
    val get_all_mappings_as_list : 'b t -> (Key.t * 'b) list
  end

  module Make : functor (Key : Key_type) -> S with module Key = Key
end

module NaiveContext : Context_type
