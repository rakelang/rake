(* Prints each source's path and the capability features the type checkers
   admitted for it, comma-separated in catalogue order:

     capability_features SOURCE.rk...

   test/capability_profile_test.sh compares these with what each profile
   compiles. *)

open Rake

let () =
  Array.to_list Sys.argv |> List.tl
  |> List.iter (fun path ->
         let program =
           match Source.parse_file path with
           | Ok program -> program
           | Error message -> prerr_endline message; exit 1
         in
         match Tier_check.check ~base_dir:(Filename.dirname path) program with
         | Ok checked ->
             Printf.printf "%s\t%s\n" path
               (String.concat "," (List.map Capabilities.id checked.used_features))
         | Error message -> prerr_endline message; exit 1)
