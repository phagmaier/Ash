type t =
  | Num of int
  | Bool of bool
  | Str of string
  | Sym of string
  | Unit
  | Nil

let equal a b =
  match (a, b) with
  | Num x, Num y -> Int.equal x y
  | Bool x, Bool y -> Bool.equal x y
  | Str x, Str y -> String.equal x y
  | Sym x, Sym y -> String.equal x y
  | Unit, Unit -> true
  | Nil, Nil -> true
  (* Enumerated rather than defaulted so a new constant shape forces this match
     to be revisited instead of silently comparing unequal. *)
  | (Num _ | Bool _ | Str _ | Sym _ | Unit | Nil), _ -> false

let shape_rank = function
  | Num _ -> 0
  | Bool _ -> 1
  | Str _ -> 2
  | Sym _ -> 3
  | Unit -> 4
  | Nil -> 5

let compare a b =
  match (a, b) with
  | Num x, Num y -> Int.compare x y
  | Bool x, Bool y -> Bool.compare x y
  | Str x, Str y -> String.compare x y
  | Sym x, Sym y -> String.compare x y
  | Unit, Unit -> 0
  | Nil, Nil -> 0
  | (Num _ | Bool _ | Str _ | Sym _ | Unit | Nil), _ ->
      Int.compare (shape_rank a) (shape_rank b)

let type_name = function
  | Num _ -> "number"
  | Bool _ -> "boolean"
  | Str _ -> "string"
  | Sym _ -> "symbol"
  | Unit -> "unit"
  | Nil -> "list"

let escape_string s =
  let buffer = Buffer.create (String.length s + 2) in
  Buffer.add_char buffer '"';
  String.iter
    (fun c ->
      match c with
      | '"' -> Buffer.add_string buffer "\\\""
      | '\\' -> Buffer.add_string buffer "\\\\"
      | '\n' -> Buffer.add_string buffer "\\n"
      | '\t' -> Buffer.add_string buffer "\\t"
      | '\r' -> Buffer.add_string buffer "\\r"
      | c when Char.code c < 0x20 || Char.code c = 0x7f ->
          Buffer.add_string buffer (Printf.sprintf "\\x%02x" (Char.code c))
      | c -> Buffer.add_char buffer c)
    s;
  Buffer.add_char buffer '"';
  Buffer.contents buffer

let to_string = function
  | Num n -> string_of_int n
  | Bool true -> "true"
  | Bool false -> "false"
  | Str s -> escape_string s
  | Sym s -> "'" ^ s
  | Unit -> "()"
  | Nil -> "[]"

let pp formatter constant = Format.pp_print_string formatter (to_string constant)
