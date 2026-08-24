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
  match Ash_examples.Demo.find name with
  | Some demo ->
      print_string (Ash_examples.Demo.report_to_string (Ash_examples.Demo.run demo));
      exit 0
  | None ->
      Printf.eprintf "ash: no demo named `%s`. Known demos: %s\n" name
        (String.concat ", " Ash_examples.Demo.names);
      exit 2

let options =
  [
    ("--version", Arg.Unit print_version, " Print the Ash version and exit");
    ("--demos", Arg.Unit list_demos, " List the packaged tower demos");
    ( "--demo",
      Arg.String run_demo,
      "NAME Run a packaged tower demo and print its trace, value, and levels" );
  ]

let () =
  Arg.parse options (fun argument -> raise (Arg.Bad ("unexpected argument: " ^ argument))) usage
