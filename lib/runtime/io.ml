open Ash_core

type event = Wrote of string | Read of string

type t = {
  (* Newest first while recording; reversed on the way out. *)
  mutable recorded : event list;
  mutable input : string list;
  echo : out_channel option;
}

let create ?echo ?(input = []) () = { recorded = []; input; echo }

let write io text =
  io.recorded <- Wrote text :: io.recorded;
  match io.echo with
  | None -> ()
  (* Flushed per write: an echoing stream is being watched by someone, and
     buffered output that appears after a later error is a lie about order. *)
  | Some channel ->
      output_string channel text;
      flush channel

let read_line io =
  match io.input with
  | [] -> None
  | line :: rest ->
      io.input <- rest;
      io.recorded <- Read line :: io.recorded;
      Some line

let feed io lines = io.input <- io.input @ lines
let events io = List.rev io.recorded

let written io =
  List.filter_map (function Wrote text -> Some text | Read _ -> None) (events io)

let text io = String.concat "" (written io)
let pending_input io = io.input
let clear io = io.recorded <- []

(* Escaped through the constant printer so a trace containing newlines stays one
   line and stays comparable. *)
let event_to_string = function
  | Wrote text -> "wrote " ^ Constant.to_string (Constant.Str text)
  | Read line -> "read " ^ Constant.to_string (Constant.Str line)

let event_equal a b =
  match (a, b) with
  | Wrote x, Wrote y -> String.equal x y
  | Read x, Read y -> String.equal x y
  | (Wrote _ | Read _), _ -> false

let trace io = String.concat "; " (List.map event_to_string (events io))
