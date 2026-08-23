let usage = "ash [OPTIONS]\n\nAsh reflective tower development CLI."

let print_version () =
  print_endline Ash.Version.string;
  exit 0

let options =
  [ ( "--version",
      Arg.Unit print_version,
      " Print the Ash version and exit" ) ]

let () =
  Arg.parse options (fun argument -> raise (Arg.Bad ("unexpected argument: " ^ argument))) usage
