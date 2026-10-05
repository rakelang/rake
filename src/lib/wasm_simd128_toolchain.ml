(** Encoding and verification for the [wasm-simd128] profile.

    The C that {!Wasm_simd128_c} emits is compiled with every function given
    external linkage, then disassembled, so verification sees what Clang made
    of the intrinsics rather than the intrinsics themselves. Verification accepts a function only
    if its body is exactly local traffic, constants, and SIMD and scalar
    register instructions: no calls, no memory access, no control flow and no
    use of the C stack, which would appear as a global stack-pointer access. *)

type error = { message : string }

let format_error error = error.message

let compiler () = Option.value (Sys.getenv_opt "RAKE_WASM_CC") ~default:"clang"
let disassembler () = Option.value (Sys.getenv_opt "RAKE_WASM_OBJDUMP") ~default:"llvm-objdump"

let run command =
  let channel = Unix.open_process_in (command ^ " 2>&1") in
  let output = In_channel.input_all channel in
  match Unix.close_process_in channel with
  | Unix.WEXITED 0 -> Ok output
  | _ -> Error { message = Printf.sprintf "%s failed:\n%s" command output }

let ( let* ) = Result.bind

let assemble c_source =
  let source_path = Filename.temp_file "rake-wasm-" ".c" in
  let object_path = Filename.temp_file "rake-wasm-" ".o" in
  Out_channel.with_open_text source_path (fun channel -> output_string channel c_source);
  Fun.protect
    ~finally:(fun () -> Sys.remove source_path)
    (fun () ->
      let* _ =
        run
          (Printf.sprintf "%s --target=wasm32 -msimd128 -O2 -ffreestanding -DRAKE_WASM_LINKAGE= -c %s -o %s"
             (compiler ()) (Filename.quote source_path) (Filename.quote object_path))
      in
      let bytes = In_channel.with_open_bin object_path In_channel.input_all in
      Sys.remove object_path;
      Ok bytes)

let contains text part =
  let n = String.length part in
  let rec from index = index + n <= String.length text && (String.sub text index n = part || from (index + 1)) in
  from 0

(** Locals, constants and register-to-register work; no memory, calls or control flow. *)
let allowed_instruction ~relaxed name =
  ((not (contains name "relaxed")) || relaxed) && (
  List.mem name [ "local.get"; "local.set"; "local.tee"; "i32.const"; "i64.const"; "f32.const"; "f32.reinterpret_i32"; "end"; "select"; "i32.select"; "i64.select"; "f32.select"; "v128.select" ]
  (* Scalar register work: a uniform condition, and the scalar arithmetic
     clang substitutes for arithmetic on splats of uniforms. *)
  || List.exists (fun prefix -> String.starts_with ~prefix name)
       [ "i32."; "i64."; "f32."; "f64."; "v128."; "i8x16."; "i16x8."; "i32x4."; "i64x2."; "f32x4." ]
     && not (contains name "load" || contains name "store"))

(** Relaxed-SIMD opcodes after the 0xfd prefix, which LLVM 21's disassembler
    prints as <unknown>. *)
let relaxed_opcodes =
  [ (0x100, "i8x16.relaxed_swizzle"); (0x101, "i32x4.relaxed_trunc_f32x4_s"); (0x102, "i32x4.relaxed_trunc_f32x4_u");
    (0x103, "i32x4.relaxed_trunc_f64x2_s_zero"); (0x104, "i32x4.relaxed_trunc_f64x2_u_zero");
    (0x105, "f32x4.relaxed_madd"); (0x106, "f32x4.relaxed_nmadd"); (0x107, "f64x2.relaxed_madd");
    (0x108, "f64x2.relaxed_nmadd"); (0x109, "i8x16.relaxed_laneselect"); (0x10a, "i16x8.relaxed_laneselect");
    (0x10b, "i32x4.relaxed_laneselect"); (0x10c, "i64x2.relaxed_laneselect"); (0x10d, "f32x4.relaxed_min");
    (0x10e, "f32x4.relaxed_max"); (0x10f, "f64x2.relaxed_min"); (0x110, "f64x2.relaxed_max");
    (0x111, "i16x8.relaxed_q15mulr_s"); (0x112, "i16x8.relaxed_dot_i8x16_i7x16_s");
    (0x113, "i32x4.relaxed_dot_i8x16_i7x16_add_s") ]

(** The name of an instruction LLVM's disassembler couldn't name, from its bytes. *)
let decode_unknown bytes_text =
  let bytes = String.split_on_char ' ' (String.trim bytes_text) |> List.filter (( <> ) "") |> List.map (fun b -> int_of_string ("0x" ^ b)) in
  match bytes with
  | 0xfd :: rest ->
      let rec leb shift acc = function
        | b :: more -> let acc = acc lor ((b land 0x7f) lsl shift) in if b land 0x80 <> 0 then leb (shift + 7) acc more else acc
        | [] -> acc
      in
      Option.value (List.assoc_opt (leb 0 0 rest) relaxed_opcodes) ~default:"<unknown>"
  | _ -> "<unknown>"

(** LLVM prints extending loads with their destination lane type. The
    WebAssembly text format uses v128 for these same six instructions. *)
let canonical_mnemonic = function
  | "i16x8.load8x8_s" -> "v128.load8x8_s"
  | "i16x8.load8x8_u" -> "v128.load8x8_u"
  | "i32x4.load16x4_s" -> "v128.load16x4_s"
  | "i32x4.load16x4_u" -> "v128.load16x4_u"
  | "i64x2.load32x2_s" -> "v128.load32x2_s"
  | "i64x2.load32x2_u" -> "v128.load32x2_u"
  | mnemonic -> mnemonic

(** Function name to instruction mnemonics, from llvm-objdump's wasm disassembly. *)
let disassembled_functions ~relaxed listing =
  let functions = Hashtbl.create 8 in
  let current = ref None in
  String.split_on_char '\n' listing
  |> List.iter (fun line ->
         let trimmed = String.trim line in
         if String.length trimmed > 2 && String.ends_with ~suffix:">:" trimmed then (
           match String.index_opt trimmed '<' with
           | Some start ->
               let name = String.sub trimmed (start + 1) (String.length trimmed - start - 3) in
               current := Some name;
               Hashtbl.replace functions name []
           | None -> ())
         else
           match (!current, String.index_opt trimmed ':') with
           | Some name, Some colon when colon > 0 && trimmed.[0] <> '.' && trimmed.[0] <> '#' ->
               let instruction = String.trim (String.sub trimmed (colon + 1) (String.length trimmed - colon - 1)) in
               (* With raw bytes shown (the relaxed profile), the bytes come first, then a tab. *)
               let raw, instruction =
                 if relaxed then
                   match String.index_opt instruction '\t' with
                   | Some tab -> (String.sub instruction 0 tab, String.trim (String.sub instruction (tab + 1) (String.length instruction - tab - 1)))
                   | None -> ("", instruction)
                 else ("", instruction)
               in
               let mnemonic =
                 match String.index_from_opt instruction 0 '\t' with
                 | Some tab -> String.sub instruction 0 tab
                 | None -> (
                     match String.index_opt instruction ' ' with
                     | Some space -> String.sub instruction 0 space
                     | None -> instruction)
               in
               let mnemonic = if String.trim mnemonic = "<unknown>" then decode_unknown raw else mnemonic in
               let mnemonic = canonical_mnemonic (String.trim mnemonic) in
               if mnemonic <> "" && not (String.starts_with ~prefix:"R_WASM_" mnemonic) then
                 Hashtbl.replace functions name (Hashtbl.find functions name @ [ mnemonic ])
           | _ -> ());
  functions

let verify ~relaxed ~functions object_bytes =
  let object_path = Filename.temp_file "rake-wasm-verify-" ".o" in
  Out_channel.with_open_bin object_path (fun channel -> output_string channel object_bytes);
  Fun.protect
    ~finally:(fun () -> Sys.remove object_path)
    (fun () ->
      let* listing =
        run (Printf.sprintf "%s -d%s %s" (disassembler ()) (if relaxed then "" else " --no-show-raw-insn") (Filename.quote object_path))
      in
      let disassembled = disassembled_functions ~relaxed listing in
      List.fold_left
        (fun result name ->
          let* () = result in
          match Hashtbl.find_opt disassembled name with
          | None -> Error { message = Printf.sprintf "function %s is missing from the encoded object" name }
          | Some mnemonics -> (
              match List.find_opt (fun mnemonic -> not (allowed_instruction ~relaxed mnemonic)) mnemonics with
              | Some forbidden ->
                  Error
                    {
                      message =
                        Printf.sprintf
                          "function %s contains %s, outside the wasm-simd128 register-only allow-list"
                          name forbidden;
                    }
              | None -> Ok ()))
        (Ok ()) functions)

(* ─── Whole programs ────────────────────────────────────────────────── *)

let extra_flags () = Option.value (Sys.getenv_opt "RAKE_WASM_CFLAGS") ~default:""

(** Compile a whole program's C, with scratches given external linkage so
    each is present to verify, and the source's directory on the include
    path for its extern headers. *)
let assemble_program ~include_dir c_source =
  let source_path = Filename.temp_file "rake-wasm-" ".c" in
  let object_path = Filename.temp_file "rake-wasm-" ".o" in
  Out_channel.with_open_text source_path (fun channel -> output_string channel c_source);
  Fun.protect
    ~finally:(fun () -> Sys.remove source_path)
    (fun () ->
      let* _ =
        run
          (Printf.sprintf "%s --target=wasm32 -msimd128 -O2 -ffreestanding -DRAKE_WASM_LINKAGE= -I%s %s -c %s -o %s"
             (compiler ()) (Filename.quote include_dir) (extra_flags ()) (Filename.quote source_path) (Filename.quote object_path))
      in
      let bytes = In_channel.with_open_bin object_path In_channel.input_all in
      Sys.remove object_path;
      Ok bytes)

(** Facts Rake recorded while emitting one run. *)
type run_facts = {
  loops : int;
  lane_operations : int;
  selected : string list;
  alternatives : string list;  (** exact substitutions proved from operand bounds *)
  slow_calls : string list;
}

(** Direct calls are authorized by their relocation symbol, never merely by
    the presence of a slow block somewhere in the function. Unresolved and
    indirect calls therefore remain forbidden in vector code. *)
let relocated_calls listing =
  let calls = Hashtbl.create 8 and current = ref None in
  String.split_on_char '\n' listing
  |> List.iter (fun line ->
         let line = String.trim line in
         if String.ends_with ~suffix:">:" line then (
           match String.index_opt line '<' with
           | Some start -> current := Some (String.sub line (start + 1) (String.length line - start - 3))
           | None -> ())
         else if contains line "R_WASM_FUNCTION_INDEX_LEB" then
           match (!current, Str.split (Str.regexp "[ \t]+") line |> List.rev) with
           | Some name, target :: _ ->
               let target =
                 if String.ends_with ~suffix:"+0" target then String.sub target 0 (String.length target - 2)
                 else target
               in
               Hashtbl.replace calls name (target :: Option.value (Hashtbl.find_opt calls name) ~default:[])
           | _ -> ());
  calls

let is_simd name =
  List.exists (fun prefix -> String.starts_with ~prefix name) [ "v128."; "i8x16."; "i16x8."; "i32x4."; "i64x2."; "f32x4."; "f64x2." ]

let is_lane_operation name =
  is_simd name
  && (List.exists (fun suffix -> String.ends_with ~suffix name) [ "extract_lane"; "extract_lane_s"; "extract_lane_u"; "replace_lane" ])

(** Scalar work a run may contain: Rake's loop counters, address formation
    and bounds checks, and its uniform scalars. *)
let run_scalar name =
  List.mem name
    [ "local.get"; "local.set"; "local.tee"; "i32.const"; "i64.const"; "f32.const"; "f64.const"; "block"; "loop";
      "br"; "br_if"; "br_table"; "if"; "else"; "end"; "return"; "unreachable"; "select"; "nop"; "drop";
      "i32.select"; "i64.select"; "f32.select"; "v128.select" ]
  || List.exists (fun prefix -> String.starts_with ~prefix name) [ "i32."; "i64."; "f32."; "f64." ]
     && not (List.exists (fun part -> contains name part) [ "store" ])

(** Clang's substitutions for an instruction Rake selected, each the same
    operation on the same racks: constants folded into a v128.const, a splat
    of a scalar load into a splatting load, and a zero-extending load for
    a lane load into a fresh rack. *)
let equivalent selected name =
  let any_of names = List.exists (fun n -> List.mem n selected) names in
  (* Clang picks the signed or unsigned twin of an operation when it proves
     the lanes it sees make them agree, such as converting widened bytes. *)
  let twin =
    let swap from into = Str.global_replace (Str.regexp_string from) into name in
    List.exists (fun n -> List.mem n selected)
      [ swap "_u" "_s"; swap "_s" "_u"; swap ".lt" ".gt"; swap ".gt" ".lt"; swap ".le" ".ge"; swap ".ge" ".le" ]
    (* A negated comparison folded into its complement. *)
    || (List.mem "v128.not" selected
        && List.exists (fun n -> List.mem n selected) [ swap ".ne" ".eq"; swap ".eq" ".ne"; swap ".lt" ".ge"; swap ".ge" ".lt"; swap ".gt" ".le"; swap ".le" ".gt" ])
  in
  (* Subtracting a constant folded into adding its negation, and multiplying
     by two into adding an operand to itself. *)
  let negated_constant =
    String.ends_with ~suffix:".add" name
    && (List.mem (String.sub name 0 (String.length name - 4) ^ ".sub") selected
        || List.mem (String.sub name 0 (String.length name - 4) ^ ".mul") selected)
  in
  let splat = List.exists (fun s -> String.ends_with ~suffix:".splat" s) selected in
  (* Scalar float arithmetic Rake emitted, computed by clang in a vector lane. *)
  let in_lane =
    List.exists
      (fun (vector, scalar) ->
        String.starts_with ~prefix:vector name
        && List.mem (scalar ^ String.sub name (String.length vector) (String.length name - String.length vector)) selected)
      [ ("f32x4.", "f32."); ("f64x2.", "f64.") ]
  in
  List.mem name selected
  || twin
  || in_lane
  || negated_constant
  || name = "v128.const"
  || (String.ends_with ~suffix:".splat" name && splat)
  || (List.mem name [ "v128.load8_splat"; "v128.load16_splat"; "v128.load32_splat"; "v128.load64_splat" ] && splat)
  || (List.mem name [ "v128.load32_zero"; "v128.load64_zero" ] && any_of [ "v128.load"; "v128.load32_lane"; "v128.load64_lane"; "v128.load32_zero"; "v128.load64_zero" ])
  || (List.mem name [ "v128.load8x8_u"; "v128.load8x8_s"; "v128.load16x4_u"; "v128.load16x4_s"; "v128.load32x2_u"; "v128.load32x2_s" ]
      && List.exists (fun s -> contains s "extend_low") selected)
  || (name = "v128.store" && any_of [ "v128.store" ])
  || (List.mem name [ "v128.not"; "v128.andnot"; "v128.and"; "v128.or" ] && any_of [ "v128.bitselect"; "v128.and"; "v128.or"; "v128.andnot"; "v128.not"; "v128.xor" ])

let verify_program ~relaxed ~scratches ~runs object_bytes =
  let object_path = Filename.temp_file "rake-wasm-verify-" ".o" in
  Out_channel.with_open_bin object_path (fun channel -> output_string channel object_bytes);
  Fun.protect
    ~finally:(fun () -> Sys.remove object_path)
    (fun () ->
      let* listing = run (Printf.sprintf "%s -dr%s %s" (disassembler ()) (if relaxed then "" else " --no-show-raw-insn") (Filename.quote object_path)) in
      let disassembled = disassembled_functions ~relaxed listing in
      let calls = relocated_calls listing in
      let find name =
        match Hashtbl.find_opt disassembled name with
        | Some mnemonics -> Ok mnemonics
        | None -> Error { message = Printf.sprintf "function %s is missing from the encoded object" name }
      in
      let* () =
        List.fold_left
          (fun result name ->
            let* () = result in
            let* mnemonics = find name in
            match List.find_opt (fun m -> not (allowed_instruction ~relaxed m)) mnemonics with
            | Some forbidden ->
                Error { message = Printf.sprintf "function %s contains %s, outside the wasm-simd128 register-only allow-list" name forbidden }
            | None -> Ok ())
          (Ok ()) scratches
      in
      List.fold_left
        (fun result (name, facts) ->
          let* () = result in
          let* mnemonics = find name in
          let fail what = Error { message = Printf.sprintf "run %s %s" name what } in
          let targets = Option.value (Hashtbl.find_opt calls name) ~default:[] in
          let* () =
            if List.length targets <> List.length (List.filter (( = ) "call") mnemonics)
               || List.exists (fun target -> not (List.mem target facts.slow_calls)) targets then
              fail "calls a function outside an explicit slow block"
            else Ok ()
          in
          match
            List.find_opt
              (fun m ->
                List.mem m [ "call_indirect"; "return_call"; "return_call_indirect"; "global.get"; "global.set" ]
                || (contains m "relaxed" && not relaxed))
              mnemonics
          with
          | Some m when contains m "relaxed" -> fail (Printf.sprintf "contains %s, a relaxed-SIMD instruction outside the wasm-simd128-relaxed profile" m)
          | Some m when String.starts_with ~prefix:"global" m ->
              fail (Printf.sprintf "contains %s: a run keeps no C stack frame, so no rack passes through memory Rake didn't name" m)
          | Some m -> fail (Printf.sprintf "contains %s: vector code calls nothing" m)
          | None -> (
              match List.find_opt (fun m -> not (m = "call" || run_scalar m
                || (is_simd m && (equivalent facts.selected m || List.mem m facts.alternatives))
                (* A scalar store Rake selected: a compaction's count. *)
                || ((not (is_simd m)) && List.mem m facts.selected))) mnemonics with
              | Some m -> fail (Printf.sprintf "contains %s, which none of its source operations selects" m)
              | None ->
                  let lane_operations = List.length (List.filter is_lane_operation mnemonics) in
                  let loops = List.length (List.filter (( = ) "loop") mnemonics) in
                  if lane_operations > facts.lane_operations then
                    fail (Printf.sprintf "has %d lane extractions or replacements; its source states %d" lane_operations facts.lane_operations)
                  else if loops > facts.loops then
                    fail (Printf.sprintf "has %d loops; its source has %d" loops facts.loops)
                  else Ok ()))
        (Ok ()) runs)

