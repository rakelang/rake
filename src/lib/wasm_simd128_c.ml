(** C emission for the [wasm-simd128] profile.

    Each Rake function becomes a C function that spells out Rake's selected
    instruction list, one [wasm_simd128.h] intrinsic per instruction, in order.
    The emitter replays the instruction list against a stack of C names:
    [local.get] and [i32.const] push a name or literal, an operation pops its
    operands and binds its intrinsic call to a new [const] name, and
    [local.tee] lets later gets reuse that name.

    Intrinsics instead of inline assembly keep the file acceptable to wasm32
    compilers that cannot pass [v128] values through inline-assembly operands,
    including the Clang build inside the unswbc judge, and let Clang inline each
    function into its caller. Clang still chooses locals and may exchange one
    vector instruction for an equivalent one; {!Wasm_simd128_toolchain.verify}
    checks that the compiled object holds nothing but locals, constants and SIMD
    instructions. *)

module I = Wasm_simd128_isel

let c_type = function I.V128 -> "v128_t" | I.I32 -> "uint32_t" | I.F32 -> "float"

exception Emission_error of string

(** The intrinsic for one selected instruction, and how many stack values it consumes. *)
let intrinsic text =
  let name, immediates =
    match String.index_opt text ' ' with
    | Some space -> (String.sub text 0 space, Some (String.sub text (space + 1) (String.length text - space - 1)))
    | None -> (text, None)
  in
  match (name, immediates) with
  | "i8x16.shuffle", Some indices -> (2, fun args -> Printf.sprintf "wasm_i8x16_shuffle(%s, %s)" (String.concat ", " args) indices)
  | _, Some _ -> raise (Emission_error ("unexpected immediates on " ^ text))
  | _ ->
      let call arity intrinsic = (arity, fun args -> Printf.sprintf "%s(%s)" intrinsic (String.concat ", " args)) in
      (match name with
      | "f32.reinterpret_i32" -> (1, fun args -> Printf.sprintf "__builtin_bit_cast(float, (uint32_t)%s)" (List.hd args))
      | "i8x16.splat" -> call 1 "wasm_i8x16_splat"
      | "i32x4.splat" -> call 1 "wasm_i32x4_splat"
      | "f32x4.splat" -> call 1 "wasm_f32x4_splat"
      | "f32x4.add" -> call 2 "wasm_f32x4_add"
      | "f32x4.sub" -> call 2 "wasm_f32x4_sub"
      | "f32x4.mul" -> call 2 "wasm_f32x4_mul"
      | "f32x4.div" -> call 2 "wasm_f32x4_div"
      | "f32x4.neg" -> call 1 "wasm_f32x4_neg"
      | "f32x4.sqrt" -> call 1 "wasm_f32x4_sqrt"
      | "f32x4.eq" -> call 2 "wasm_f32x4_eq"
      | "f32x4.lt" -> call 2 "wasm_f32x4_lt"
      | "f32x4.le" -> call 2 "wasm_f32x4_le"
      | "f32x4.gt" -> call 2 "wasm_f32x4_gt"
      | "f32x4.ge" -> call 2 "wasm_f32x4_ge"
      | "i8x16.eq" -> call 2 "wasm_i8x16_eq"
      | "i8x16.ne" -> call 2 "wasm_i8x16_ne"
      | "i8x16.lt_u" -> call 2 "wasm_u8x16_lt"
      | "i8x16.le_u" -> call 2 "wasm_u8x16_le"
      | "i8x16.gt_u" -> call 2 "wasm_u8x16_gt"
      | "i8x16.ge_u" -> call 2 "wasm_u8x16_ge"
      | "v128.and" -> call 2 "wasm_v128_and"
      | "v128.or" -> call 2 "wasm_v128_or"
      | "v128.xor" -> call 2 "wasm_v128_xor"
      | "v128.not" -> call 1 "wasm_v128_not"
      | "v128.bitselect" -> call 3 "wasm_v128_bitselect"
      | "i8x16.bitmask" -> call 1 "wasm_i8x16_bitmask"
      | "i32x4.bitmask" -> call 1 "wasm_i32x4_bitmask"
      | _ -> raise (Emission_error ("no intrinsic for " ^ text)))

let result_type text =
  if String.ends_with ~suffix:".bitmask" text then "uint32_t"
  else if text = "f32.reinterpret_i32" then "float"
  else "v128_t"

let emit_function (func : I.func) =
  let parameter_name index = (List.nth func.parameters index).I.parameter_name in
  let scratch_names = Hashtbl.create 8 in
  let local_name = function
    | I.Result_local -> "result"
    | I.Scratch_local _ as local -> Hashtbl.find scratch_names local
    | I.Parameter_local index -> parameter_name index
  in
  let statements = ref [] in
  let stack = ref [] in
  let steps = ref 0 in
  let pop () =
    match !stack with
    | top :: rest ->
        stack := rest;
        top
    | [] -> raise (Emission_error (func.name ^ ": the instruction list pops an empty stack"))
  in
  List.iter
    (function
      | I.Local_get local -> stack := local_name local :: !stack
      | I.I32_const value -> stack := Int32.to_string value :: !stack
      | I.Local_set local ->
          statements := Printf.sprintf "%s = %s;" (local_name local) (pop ()) :: !statements
      | I.Local_tee local ->
          (* The value already has a name; later gets of this local reuse it. *)
          let name = pop () in
          Hashtbl.replace scratch_names local name;
          stack := name :: !stack
      | I.Operation text ->
          let arity, build = intrinsic text in
          let args = List.rev (List.init arity (fun _ -> pop ())) in
          let name = Printf.sprintf "step%d" !steps in
          incr steps;
          statements := Printf.sprintf "%s const %s = %s;" (result_type text) name (build args) :: !statements;
          stack := name :: !stack)
    func.instructions;
  let parameters =
    List.map
      (fun (parameter : I.parameter) -> c_type parameter.parameter_class ^ " " ^ parameter.parameter_name)
      func.parameters
  in
  Printf.sprintf "RAKE_WASM_LINKAGE %s %s(%s)\n{\n    %s result;\n%s    return result;\n}\n"
    (c_type func.result_class) func.name
    (if parameters = [] then "void" else String.concat ", " parameters)
    (c_type func.result_class)
    (String.concat "" (List.rev_map (fun statement -> "    " ^ statement ^ "\n") !statements))

let emit ~source (functions : I.func list) =
  Printf.sprintf
    "/* Generated by rakec --target wasm-simd128 from %s. Every intrinsic below is one\n\
    \   Rake-selected WebAssembly SIMD instruction; compile this file for wasm32 with SIMD128. */\n\
     #include <stdint.h>\n\
     #include <wasm_simd128.h>\n\n\
     #ifndef RAKE_WASM_LINKAGE\n\
     #define RAKE_WASM_LINKAGE static inline __attribute__((always_inline))\n\
     #endif\n\n%s"
    (Filename.basename source)
    (String.concat "\n" (List.map emit_function functions))
