(** The browser playground's compiler boundary.

    This is ordinary compiler-library code. The browser adapter converts its
    result to JavaScript values; the command line and the page therefore use
    the same parser, checker, interpreter and backend emitters. *)

type target = Wasm_simd128 | X86_sse2 | X86_avx2 | X86_avx512 | Aarch64_neon

type lane_trace = {
  name : string;
  line : int;
  column : int;
  kind : string;
  values : string list;
  active : int option;
}

type output = {
  result : string option;
  code : string;
  traces : lane_trace list;
}

let target_profile = function
  | Wasm_simd128 -> Target.Wasm_simd128
  | X86_sse2 -> Target.X86_sse2
  | X86_avx2 -> Target.X86_avx2
  | X86_avx512 -> Target.X86_avx512
  | Aarch64_neon -> Target.Aarch64_neon

let target_config target =
  match Target.make ~selection:(Explicit (target_profile target)) Cpu with
  | Ok config -> Ok config
  | Error message -> Error message

let is_whole_program (program : Ast.program) =
  List.exists
    (fun (module_ : Ast.module_) ->
      List.exists
        (fun (definition : Ast.def) ->
          match definition.v with
          | DSlow _ | DRun _ | DRecord _ | DState _ | DEmbed _ | DConst _
          | DExtern _ ->
              true
          | _ -> false)
        module_.mod_defs)
    program

let float_text value =
  if Float.is_nan value then "NaN"
  else if Float.is_infinite value then if value < 0.0 then "-inf" else "inf"
  else Printf.sprintf "%g" value

let trace_of_interpreter (trace : Tier_interp.trace) =
  let kind, values =
    match trace.trace_value with
    | Native_reference.F32_rack values ->
        ("f32", Array.to_list (Array.map float_text values))
    | Mask values ->
        ( "mask",
          Array.to_list
            (Array.map (fun value -> if value then "yes" else "no") values) )
    | U8_rack values ->
        ("u8", Array.to_list (Array.map string_of_int values))
    | I16_rack values ->
        ("i16", Array.to_list (Array.map string_of_int values))
    | I32_rack values ->
        ("i32", Array.to_list (Array.map string_of_int values))
    | I64_rack values ->
        ("i64", Array.to_list (Array.map Int64.to_string values))
    | F32_scalar value -> ("f32", [ float_text value ])
    | U32_scalar value -> ("u32", [ string_of_int value ])
    | Int_scalar (_, value) -> ("integer", [ Int64.to_string value ])
  in
  {
    name = trace.trace_name;
    line = trace.trace_loc.line;
    column = trace.trace_loc.col;
    kind;
    values;
    active = trace.trace_active;
  }

let checked_program source =
  let ( let* ) = Result.bind in
  let* program = Source.parse_string ~filename:"playground.rk" source in
  let* _ = Typecheck.check program in
  Ok program

let whole_program_code program =
  match Tier_check.check ~base_dir:"." program with
  | Error message -> Error message
  | Ok checked -> (
      match Tier_c.emit ~addressing:Barrier ~source:"playground.rk" checked with
      | code, _ -> Ok (checked, code)
      | exception Tier_c.Emission_error (loc, message) ->
          Error
            (Printf.sprintf "%s:%d:%d: wasm-simd128 emission: %s" loc.file
               loc.line loc.col message))

let vector_code target program =
  let ( let* ) = Result.bind in
  let* config = target_config target in
  Native_backend.emit_assembly ~source:"playground.rk" ~config program
  |> Result.map_error Native_backend.format_error

let compile ~source ~target =
  let ( let* ) = Result.bind in
  let* program = checked_program source in
  if is_whole_program program then
    if target <> Wasm_simd128 then
      Error
        "playground.rk:1:0: slow code, runs and module definitions compile for wasm-simd128"
    else
      let* checked, code = whole_program_code program in
      let traces = ref [] in
      let trace value =
        if List.length !traces < 256 then
          traces := trace_of_interpreter value :: !traces
      in
      let result =
        if
          checked.slows
          |> List.exists (fun (slow : Tier_ir.slow_func) -> slow.fname = "main")
        then
          Tier_interp.run_main ~trace checked
          |> Result.map (fun value -> Some (Int64.to_string value))
        else Ok None
      in
      let* result = result in
      Ok { result; code; traces = List.rev !traces }
  else
    let* code = vector_code target program in
    Ok { result = None; code; traces = [] }
