open Ash_core
open Ash_syntax
open Ash_runtime
open Ash_tower

type t = { name : string; title : string; source : string }

let all =
  [
    {
      name = "tracing";
      title = "§5.3 — a program rewrites the evaluator running it";
      source = Sources.tracing;
    };
    {
      name = "level-2-counting";
      title = "§5.6 — level 2 counts the work level 1 does";
      source = Sources.level_2_counting;
    };
  ]

let find name = List.find_opt (fun demo -> String.equal demo.name name) all
let names = List.map (fun demo -> demo.name) all

type outcome = Answered of Value.value | Failed of Error.t

type report = {
  demo : t;
  output : string list;  (** Exactly what the program wrote, in order. *)
  outcome : outcome;
  materialized : int;  (** Levels the run brought into existence. *)
}

(* A demo runs on its own tower over a buffered stream, so its trace is a value
   rather than something that has already gone to a terminal. The CLI prints the
   buffer afterwards; the golden test compares it. Neither can observe anything
   the other does not. *)
let run demo =
  let io = Io.create () in
  let tower = Tower.create ~registry:(Primitives.create ~io ()) () in
  let named =
    Ident.Set.fold
      (fun ident collected -> (Ident.name ident, ident) :: collected)
      (Env.idents (Level.global (Tower.ground tower)))
      []
  in
  let outcome =
    match
      Desugar.program
        ~scope:(Desugar.scope_of_globals named)
        (Parser.program ~file:(demo.name ^ ".ash") demo.source)
    with
    | term -> (
        match Tower.run tower term with
        | value -> Answered value
        | exception Error.Ash_error error -> Failed error)
    | exception Error.Ash_error error -> Failed error
  in
  (* The lines that appeared on the stream, not the individual writes: a demo
     that used [print] rather than [println] would otherwise report its output
     split at call boundaries that nothing about the program chose. *)
  let output =
    match String.split_on_char '\n' (Io.text io) with
    | [ "" ] -> []
    | lines -> (
        match List.rev lines with "" :: rest -> List.rev rest | _ -> lines)
  in
  { demo; output; outcome; materialized = Tower.materialized tower }

(* One renderer, used by the CLI and by the golden test, so a demo's expected
   output cannot drift from what running it prints. *)
let report_to_string report =
  let buffer = Buffer.create 1024 in
  Buffer.add_string buffer (Printf.sprintf "== %s ==\n" report.demo.name);
  Buffer.add_string buffer (Printf.sprintf "%s\n\n" report.demo.title);
  Buffer.add_string buffer
    (Printf.sprintf "output (%d line(s)):\n" (List.length report.output));
  List.iter (fun line -> Buffer.add_string buffer (Printf.sprintf "  %s\n" line)) report.output;
  Buffer.add_string buffer
    (match report.outcome with
    | Answered value -> Printf.sprintf "\nvalue: %s\n" (Value.to_string value)
    | Failed error -> Printf.sprintf "\nfailed: %s\n" (Error.to_string error));
  Buffer.add_string buffer
    (Printf.sprintf "levels materialized: %d\n" report.materialized);
  Buffer.contents buffer
