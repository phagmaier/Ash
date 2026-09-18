let usage = "ash [OPTIONS]\n\nAsh reflective tower development CLI."

let print_version () =
  print_endline Ash.Version.string;
  exit 0

(* The milestone-1 evidence is meant to be re-run, not read about, so each demo
   is one command. Output goes through the demo's buffered stream and is printed
   here, which is what lets the golden test compare exactly what this prints. *)
let list_demos () =
  List.iter
    (fun demo ->
      Printf.printf "  %-16s %s\n" demo.Ash_examples.Demo.name demo.Ash_examples.Demo.title)
    Ash_examples.Demo.all;
  exit 0

let run_demo name =
  let protect f =
    try f ()
    with
    | Ash_core.Error.Ash_error error ->
        Printf.eprintf "ash: %s\n" (Ash_core.Error.to_string error);
        exit 1
    | Stack_overflow ->
        Printf.eprintf "ash: host stack exhausted while running the demo\n";
        exit 1
  in
  protect (fun () ->
      match Ash_examples.Demo.find name with
      | Some demo ->
          print_string (Ash_examples.Demo.report_to_string (Ash_examples.Demo.run demo));
          exit 0
      | None ->
          Printf.eprintf "ash: no demo named `%s`. Known demos: %s\n" name
            (String.concat ", " Ash_examples.Demo.names);
          exit 2)

(* The collapse report (spec §9.4). The depth is an ordinary option, so it is
   collected first and acted on after parsing rather than depending on the order
   the two flags were written in. *)
let depth = ref 1
let collapse_file = ref None
let show_residual = ref false
let json = ref false

let read_file path =
  try
    let channel = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr channel)
      (fun () ->
        let length = in_channel_length channel in
        Some (really_input_string channel length))
  with Sys_error _ -> None

let run_collapse path =
  if !depth < 0 then (
    Printf.eprintf "ash: --depth must be non-negative, got %d\n" !depth;
    exit 2);
  match read_file path with
  | None ->
      Printf.eprintf "ash: cannot read `%s`\n" path;
      exit 2
  | Some source -> (
      (if !json && !show_residual then
         Printf.eprintf "ash: warning: --show-residual is ignored with --json\n");
      match
        (if !json then
           Ash_collapse.Collapse.json_report ~depth:!depth ~file:path ~name:path
             (Ash_collapse.Metrics.Surface source)
         else
           Ash_collapse.Collapse.report ~depth:!depth ~show_residual:!show_residual
             ~file:path ~name:path
             (Ash_collapse.Metrics.Surface source))
      with
      | report ->
          print_string report;
          exit 0
      | exception Ash_core.Error.Ash_error error ->
          Printf.eprintf "ash: %s\n" (Ash_core.Error.to_string error);
          exit 1
      | exception Stack_overflow ->
          Printf.eprintf "ash: host stack exhausted while collapsing `%s`\n" path;
          exit 1)

let options =
  [
    ("--version", Arg.Unit print_version, " Print the Ash version and exit");
    ("--demos", Arg.Unit list_demos, " List the packaged tower demos");
    ( "--demo",
      Arg.String run_demo,
      "NAME Run a packaged tower demo and print its trace, value, and levels" );
    ( "--collapse",
      Arg.String (fun path -> collapse_file := Some path),
      "FILE Specialize an Ash program and print its collapse report" );
    ( "--show-residual",
      Arg.Set show_residual,
      " Include canonical residual Core and exact output bytes in the collapse report" );
    ( "--json",
      Arg.Set json,
      " Emit the collapse report as one JSON object" );
    ( "--depth",
      Arg.Set_int depth,
      "N Tower depth the collapse report measures against (default 1)" );
  ]

let () =
  Arg.parse options (fun argument -> raise (Arg.Bad ("unexpected argument: " ^ argument))) usage;
  match !collapse_file with Some path -> run_collapse path | None -> ()
