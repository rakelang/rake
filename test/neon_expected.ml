open Rake
open Ast
open Native_semantics

let fail message =
  prerr_endline message;
  exit 1

let parse_file filename =
  match Source.parse_file filename with Ok program -> program | Error message -> fail message

let definitions = function
  | [ { mod_defs; _ } ] -> mod_defs
  | _ -> fail "native semantic fixture must contain exactly one module"

let find_definition predicate description program =
  match definitions program |> List.find_opt (fun definition -> predicate definition.v) with
  | Some definition -> definition
  | None -> fail ("missing definition " ^ description)

let find_scratch name =
  find_definition
    (function DScratch (candidate, _, _, _) -> String.equal candidate name | _ -> false)
    name

let find_rake name =
  find_definition
    (function DRake (candidate, _, _, _, _, _, _) -> String.equal candidate name | _ -> false)
    name

let rack_result = function
  | Ok (F32_rack values) -> values
  | Ok value ->
      fail ("expected rack result, got " ^ string_of_value_kind (value_kind value))
  | Error error -> fail (format_error error)

let evaluate definition arguments = eval_scratch ~lanes:4 definition arguments |> rack_result
let evaluate_rake definition arguments = eval_rake ~lanes:4 definition arguments |> rack_result
let print_bits value = Printf.printf "%08lx\n" (Int32.bits_of_float value)
let print values = Array.iter print_bits values

let () =
  match Array.to_list Sys.argv with
  | [ _; add_source; select_source; scalar_source; fma_source; predication_source ] ->
      find_scratch "lowering_add" (parse_file add_source)
      |> fun definition ->
      evaluate definition
        [ rack [| -8.0; -3.5; -0.0; 1024.0 |];
          rack [| 3.0; 1.5; 0.0; 0.5 |] ]
      |> print;
      find_scratch "choose_positive" (parse_file select_source)
      |> fun definition ->
      evaluate definition
        [ rack [| -8.0; 3.5; -0.0; 1024.0 |];
          rack [| 9.0; 9.0; 9.0; 9.0 |] ]
      |> print;
      find_scratch "scale_and_add" (parse_file scalar_source)
      |> fun definition ->
      evaluate definition
        [ rack [| -8.0; -3.5; -0.0; 1024.0 |]; scalar 0.5;
          rack [| 3.0; 1.5; 0.0; 0.5 |] ]
      |> print;
      find_scratch "fused_madd" (parse_file fma_source)
      |> fun definition ->
      evaluate definition
        [ rack [| 1.0000001192092896; -3.5; 16.0; -0.0 |];
          rack [| 1.0000001192092896; 2.0; 0.25; 8.0 |];
          rack [| -1.000000238418579; 7.0; -4.0; 0.0 |] ]
      |> print;
      let predication = parse_file predication_source in
      find_rake "guarded_partial" predication
      |> fun definition ->
      evaluate_rake definition
        [ rack [| 1.0; -1.0; 1.0; -1.0 |];
          rack [| 4.0; -1.0; 9.0; Int32.float_of_bits 0x7f7fffffl |];
          rack [| 2.0; 0.0; 3.0; 0.0 |];
          rack [| 1.0; infinity; 1.0; infinity |];
          rack [| 0.0; neg_infinity; 0.0; neg_infinity |] ]
      |> print;
      find_rake "overlap_priority_native" predication
      |> fun definition ->
      evaluate_rake definition [ rack [| -1.0; 0.0; 1.0; nan |] ] |> print
  | _ ->
      fail
        "usage: neon_expected ADD.rk SELECT.rk SCALAR.rk FMA.rk PREDICATION.rk"
