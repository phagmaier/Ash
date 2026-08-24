type t =
  | Identity
  | Lift

let is_identity = function Identity -> true | Lift -> false
let is_lift = function Lift -> true | Identity -> false

let name = function
  | Identity -> "identity"
  | Lift -> "lift"

let equal a b =
  match (a, b) with
  | Identity, Identity | Lift, Lift -> true
  | Identity, Lift | Lift, Identity -> false

let compare a b =
  match (a, b) with
  | Identity, Identity | Lift, Lift -> 0
  | Identity, Lift -> -1
  | Lift, Identity -> 1

let to_string = name
let pp fmt m = Format.pp_print_string fmt (name m)
