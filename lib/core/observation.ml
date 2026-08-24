type t =
  | Whole_value
  | Shape_only
  | Unobserved

type signature = {
  positional : t list;
  remaining : t;
}

let whole_values = { positional = []; remaining = Whole_value }
let of_positional ?(remaining = Whole_value) positional = { positional; remaining }
let uniform observation = { positional = []; remaining = observation }

let at signature index =
  match List.nth_opt signature.positional index with
  | Some observation -> observation
  | None -> signature.remaining

let name = function
  | Whole_value -> "whole-value"
  | Shape_only -> "shape-only"
  | Unobserved -> "unobserved"

let equal a b =
  match (a, b) with
  | Whole_value, Whole_value | Shape_only, Shape_only | Unobserved, Unobserved -> true
  | (Whole_value | Shape_only | Unobserved), _ -> false
