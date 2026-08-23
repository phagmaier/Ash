type binding_state = Unbound | Unfilled | Bound of Value.value

type name_lookup =
  | Name_unbound
  | Name_found of Value.cell
  | Name_ambiguous of Ident.t list

(* Lookup by identity *)

let rec lookup env ident =
  match env with
  | [] -> None
  | frame :: outer -> (
      match Ident.Map.find_opt ident frame.Value.bindings with
      | Some cell -> Some cell
      | None -> lookup outer ident)

let lookup_exn ~phase ~span ?level env ident =
  match lookup env ident with
  | Some cell -> cell
  | None -> Error.raise_cause ~phase ~span ?level (Error.Unbound_ident ident)

let state env ident =
  match lookup env ident with
  | None -> Unbound
  | Some cell -> (
      match Value.cell_contents cell with
      | None -> Unfilled
      | Some value -> Bound value)

let read_exn ~phase ~span ?level env ident =
  match state env ident with
  | Bound value -> value
  | Unbound -> Error.raise_cause ~phase ~span ?level (Error.Unbound_ident ident)
  | Unfilled -> Error.raise_cause ~phase ~span ?level (Error.Unfilled_binding ident)

(* Lookup by printed name *)

let frame_matches name frame =
  (* Collected in Map order, which is deterministic but ID-derived; the result is
     only used to detect and describe ambiguity, never to choose a winner. *)
  Ident.Map.fold
    (fun ident cell matches ->
      if String.equal (Ident.name ident) name then (ident, cell) :: matches
      else matches)
    frame.Value.bindings []

let rec lookup_by_name env name =
  match env with
  | [] -> Name_unbound
  | frame :: outer -> (
      match frame_matches name frame with
      | [] -> lookup_by_name outer name
      | [ (_, cell) ] -> Name_found cell
      | (_ :: _ :: _) as matches -> Name_ambiguous (List.map fst matches))

let lookup_by_name_exn ~phase ~span ?level env name =
  match lookup_by_name env name with
  | Name_found cell -> cell
  | Name_unbound -> Error.raise_cause ~phase ~span ?level (Error.Unbound_name name)
  | Name_ambiguous candidates ->
      Error.raise_cause ~phase ~span ?level (Error.Ambiguous_name { name; candidates })

(* Extension *)

let bind_cell ident cell env = Value.push_frame (Value.frame_of_list [ (ident, cell) ]) env
let bind ident value env = bind_cell ident (Value.cell value) env
let extend_cells bindings env = Value.push_frame (Value.frame_of_list bindings) env

let extend bindings env =
  extend_cells (List.map (fun (ident, value) -> (ident, Value.cell value)) bindings) env

let preallocate idents env =
  extend_cells (List.map (fun ident -> (ident, Value.preallocated_cell ())) idents) env

(* Assignment *)

let assign env ident value =
  match lookup env ident with
  | None -> false
  | Some cell ->
      Value.fill_cell cell value;
      true

let assign_exn ~phase ~span ?level env ident value =
  if not (assign env ident value) then
    Error.raise_cause ~phase ~span ?level (Error.Unbound_ident ident)

(* Description *)

let depth env = List.length env

let idents env =
  List.fold_left
    (fun set frame ->
      Ident.Map.fold (fun ident _ set -> Ident.Set.add ident set) frame.Value.bindings set)
    Ident.Set.empty env
