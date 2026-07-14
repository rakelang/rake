open Rake
open Ast
open Native_semantics

let fail message =
  prerr_endline message;
  exit 1

let parse_file filename =
  let channel = open_in filename in
  Fun.protect ~finally:(fun () -> close_in_noerr channel) (fun () ->
      let lexbuf = Lexing.from_channel channel in
      lexbuf.lex_curr_p <- { lexbuf.lex_curr_p with pos_fname = filename };
      try Parser.program Lexer.token lexbuf with
      | Lexer.LexError (message, _) -> fail ("lexical error: " ^ message)
      | Parser.Error -> fail ("syntax error in " ^ filename))

let definitions = function
  | [ { mod_defs; _ } ] -> mod_defs
  | _ -> fail "native semantic fixture must contain exactly one module"

let find_crunch name program =
  match
    definitions program
    |> List.find_opt (fun definition ->
           match definition.v with
           | DCrunch (candidate, _, _, _) -> String.equal candidate name
           | _ -> false)
  with
  | Some definition -> definition
  | None -> fail ("missing crunch definition " ^ name)

let find_rake name program =
  match
    definitions program
    |> List.find_opt (fun definition ->
           match definition.v with
           | DRake (candidate, _, _, _, _, _, _) -> String.equal candidate name
           | _ -> false)
  with
  | Some definition -> definition
  | None -> fail ("missing rake definition " ^ name)

let evaluate definition arguments =
  match eval_crunch ~lanes:8 definition arguments with
  | Ok (F32_rack values) -> values
  | Ok value ->
      fail
        ("expected rack result, got "
        ^ string_of_value_kind (value_kind value))
  | Error error -> fail (format_error error)

let evaluate_value definition arguments =
  match eval_crunch ~lanes:8 definition arguments with
  | Ok value -> value
  | Error error -> fail (format_error error)

let evaluate_rake definition arguments =
  match eval_rake ~lanes:8 definition arguments with
  | Ok (F32_rack values) -> values
  | Ok value ->
      fail
        ("expected rack result, got "
        ^ string_of_value_kind (value_kind value))
  | Error error -> fail (format_error error)

let print_bits value = Printf.printf "%08lx\n" (Int32.bits_of_float value)

let () =
  match Array.to_list Sys.argv with
  | [ _; add_source; select_source; scalar_source; predication_source;
      cross_lane_source ] ->
      let add = find_crunch "lowering_add" (parse_file add_source) in
      evaluate add
        [ rack [| -8.0; -3.5; -0.0; 1.0; 2.5; 8.0; 16.0; 1024.0 |];
          rack [| 3.0; 1.5; 0.0; -4.0; 2.5; 0.25; -8.0; 0.5 |] ]
      |> Array.iter print_bits;
      let select = find_crunch "choose_positive" (parse_file select_source) in
      evaluate select
        [ rack [| -8.0; 3.5; -0.0; 1.0; -2.5; 8.0; -16.0; 1024.0 |];
          rack [| 9.0; 9.0; 9.0; 9.0; 9.0; 9.0; 9.0; 9.0 |] ]
      |> Array.iter print_bits;
      let scalar_crunch = find_crunch "scale_and_add" (parse_file scalar_source) in
      evaluate scalar_crunch
        [ rack [| -8.0; -3.5; -0.0; 1.0; 2.5; 8.0; 16.0; 1024.0 |];
          scalar 0.5;
          rack [| 3.0; 1.5; 0.0; -4.0; 2.5; 0.25; -8.0; 0.5 |] ]
      |> Array.iter print_bits;
      let predication = parse_file predication_source in
      let guarded = find_rake "guarded_partial" predication in
      evaluate_rake guarded
        [ rack [| 1.0; -1.0; 1.0; -1.0; 1.0; -1.0; 1.0; -1.0 |];
          rack [| 4.0; -1.0; 9.0; Int32.float_of_bits 0x7f7fffffl; 16.0;
                  Int32.float_of_bits 0x7f800001l; 25.0; -4.0 |];
          rack [| 2.0; 0.0; 3.0; 0.0; 4.0; 0.0; 5.0; 0.0 |];
          rack [| 1.0; infinity; 1.0; infinity; 1.0; infinity; 1.0; infinity |];
          rack [| 0.0; neg_infinity; 0.0; neg_infinity; 0.0; neg_infinity; 0.0; neg_infinity |] ]
      |> Array.iter print_bits;
      let overlap = find_rake "overlap_priority_native" predication in
      evaluate_rake overlap
        [ rack [| -1.0; 0.0; 1.0; nan; -0.0; 5.0; -5.0; nan |] ]
      |> Array.iter print_bits;
      let cross_lane = parse_file cross_lane_source in
      let add_inputs =
        [| 16_777_216.0; 1.0; -16_777_216.0; 1.0; 2.0; 3.0; 4.0; 5.0 |]
      and mul_inputs = [| 1.5; 2.0; 0.5; -1.0; 2.0; 0.25; 4.0; 1.0 |]
      and extrema_inputs =
        [| 3.0; 0.0; -0.0; 5.0; nan; infinity; neg_infinity; 2.0 |]
      in
      [ ("strict_reduce_add", add_inputs);
        ("strict_reduce_mul", mul_inputs);
        ("strict_reduce_min", extrema_inputs);
        ("strict_reduce_max", extrema_inputs) ]
      |> List.iter (fun (name, inputs) ->
             match evaluate_value (find_crunch name cross_lane) [ rack inputs ] with
             | F32_scalar value -> print_bits value
             | value ->
                 fail
                   (name ^ " expected scalar, got "
                  ^ string_of_value_kind (value_kind value)));
      [ ("strict_scan_add", add_inputs);
        ("strict_scan_mul", mul_inputs);
        ("strict_scan_min", extrema_inputs);
        ("strict_scan_max", extrema_inputs) ]
      |> List.iter (fun (name, inputs) ->
             evaluate (find_crunch name cross_lane) [ rack inputs ]
             |> Array.iter print_bits)
  | _ ->
      fail
        "usage: native_expected ADD.rk SELECT.rk SCALAR.rk PREDICATION.rk REDUCTIONS_SCANS.rk"
