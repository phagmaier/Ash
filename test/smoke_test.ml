let () =
  if String.length Ash.Version.string = 0 then
    failwith "Ash version must not be empty"
