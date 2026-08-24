(* Stored output for the packaged tower demos (to-do task 4.5).

   This runs the same demos `ash --demo NAME` runs, through the same renderer,
   so the file below is literally what the command prints. Two things it is
   watching for, both of which would otherwise pass silently:

   - The trace has one line per evaluated Core node. If open recursion (§D3)
     regressed, a replaced evaluator would fire once and the trace would collapse
     to a handful of lines while still producing the right answer — the exact
     failure mode the spec calls the most expensive mistake on its list.
   - The level-2 counts are the per-level cost of an unerased tower, which is the
     measurement Phase 5 exists to reduce. They are pinned so that a change in
     what a level costs is a visible diff rather than a number nobody compared. *)

open Ash_core

let report name =
  match Ash_examples.Demo.find name with
  | Some demo -> Ash_examples.Demo.run demo
  | None -> failwith (Printf.sprintf "no demo named `%s`" name)

(* The two acceptance criteria of task 4.5, computed from the runs above rather
   than asserted about them, so that the stored file states what the demos are
   evidence for and not merely what they printed. *)
let acceptance () =
  let tracing = report "tracing" in
  let counting = report "level-2-counting" in
  Printf.printf "\nacceptance\n";
  Printf.printf "  tracing logs every node, not only the outermost: %d lines\n"
    (List.length tracing.Ash_examples.Demo.output);
  match counting.Ash_examples.Demo.outcome with
  | Ash_examples.Demo.Answered
      (Value.List [ _answer; Value.Num program; Value.Num interpreter ]) ->
      Printf.printf
        "  level 2 counts level 1's work: %d interpreter steps for %d program steps\n"
        interpreter program;
      Printf.printf "  the level-1 evaluator costs %d.%02dx the program it runs\n"
        (interpreter / program)
        (interpreter * 100 / program mod 100)
  | Ash_examples.Demo.Answered _ | Ash_examples.Demo.Failed _ ->
      print_endline "  level-2 counting did not produce its two counters"

let () =
  print_endline "Ash packaged tower demos — golden output";
  print_endline "Regenerate with `dune runtest --auto-promote`; reproduce with `ash --demo NAME`.";
  List.iter
    (fun demo ->
      print_newline ();
      print_string (Ash_examples.Demo.report_to_string (Ash_examples.Demo.run demo)))
    Ash_examples.Demo.all;
  acceptance ()
