(** Command-line interface for the Rake compiler. *)

let usage =
  {|
rakec - compiler for the Rake vector-first CPU kernel language

Usage:
  rakec <file.rk>                     Parse and type-check
  rakec --emit-tokens <file.rk>       Emit tokens (for debugging)
  rakec --emit-ast <file.rk>          Emit AST (for debugging)
  rakec --emit-native-ir <file.rk>    Emit rack-preserving native SSA
  rakec --emit-c <file.rk>            Emit a C translation unit
  rakec --emit-asm <file.rk>          Emit physical-target kernel assembly
  rakec --emit-obj <file.rk>          Assemble Rake-owned code to an object
  rakec --verify-native <file.rk>     Verify and emit a Rake-owned object
  rakec --interpret <file.rk> [-- args...]  Run main in Rake's executable semantics
  rakec --print-capabilities          Print the frontend semantic contract
  rakec --print-targets               Print available native profiles
  rakec --version                     Show version
  rakec --help                        Show this help

Options:
  --target <p>   Select native, scalar, x86-sse2, x86-avx2, x86-avx512,
                 aarch64-neon, wasm-simd128 or wasm-simd128-relaxed
                 (default: native).
  --width <n>    Compatibility assertion. It must equal the selected profile's
                 f32 lane count; it never changes or splits a native rack.
  --wasm-addressing <a>  barrier (default) keeps run addresses opaque to
                 loop strength reduction with an empty i32 asm, so constant
                 offsets fold into load and store immediates; plain emits
                 wasm_simd128.h intrinsics alone.
  -o <file>      Write the selected emission product to <file>.

The production kernel backends are x86-sse2, x86-avx2, x86-avx512,
aarch64-neon and wasm-simd128. Rake owns
native SSA, instruction selection, no-spill allocation and assembly emission.
--emit-c writes C for WebAssembly or a native C unit embedding Rake-selected
assembly. The platform C compiler lowers slow code and implements its C ABI.
On wasm-simd128 each selected vector instruction is a wasm_simd128.h intrinsic.
--emit-asm writes only physical-target register-kernel assembly. Use --emit-c
for whole programs and WebAssembly. C output alone has not passed final-object
verification; --verify-native compiles, disassembles and checks the object.
Native programs call register kernels through f32/i32/u32/bool uniform C boundaries.
Native SSE2, AVX2, AVX-512 and NEON traverse f32/i32/u32 streams, including
explicit widening of byte and 16-bit columns and guarded partial racks.
General native runs remain WIP.

|}

let fail message =
  prerr_endline message;
  exit 1

let read_source filename =
  let ic = open_in_bin filename in
  Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
      let buffer = Buffer.create 4096 in
      let chunk = Bytes.create 4096 in
      let rec read () =
        match input ic chunk 0 (Bytes.length chunk) with
        | 0 -> Buffer.contents buffer
        | count ->
            Buffer.add_subbytes buffer chunk 0 count;
            read ()
      in
      read ())

let parse_file filename = Rake.Source.parse_file filename

let emit_tokens filename =
  let source = read_source filename in
  match Rake.Layout.validate ~filename source with
  | Error message -> fail message
  | Ok () ->
      let lexbuf = Lexing.from_string source in
      lexbuf.Lexing.lex_curr_p <-
        { lexbuf.Lexing.lex_curr_p with Lexing.pos_fname = filename };
      Rake.Lexer.emit lexbuf

type emit_mode =
  | Check
  | Tokens
  | Ast
  | Native_ir
  | C_source
  | Assembly
  | Object
  | Verify_native
  | Interpret

type opts = {
  mutable emit_mode : emit_mode;
  mutable target_selection : Rake.Target.selection option;
  mutable width : int option;
  mutable output : string option;
  mutable filename : string option;
  mutable program_arguments : string list option;
  mutable addressing : Rake.Tier_c.addressing;
}

let source_stem filename =
  if Filename.check_suffix filename ".rk" then Filename.chop_suffix filename ".rk"
  else filename

let write_output contents = function
  | None ->
      output_string stdout contents;
      flush stdout
  | Some path ->
      let channel = open_out_bin path in
      Fun.protect ~finally:(fun () -> close_out_noerr channel) (fun () ->
          output_string channel contents;
          flush channel)

let resolve_target_config opts =
  let selection =
    Option.value opts.target_selection ~default:Rake.Target.Native
  in
  match Rake.Target.make ?width:opts.width ~selection Rake.Target.Cpu with
  | Ok config -> config
  | Error message ->
      prerr_endline ("Error: " ^ message);
      exit 1

let parse_program filename =
  match parse_file filename with Ok program -> program | Error message -> fail message

let typecheck program =
  match Rake.Typecheck.check program with
  | Ok environment -> environment
  | Error message -> fail message

(** Slow code, runs and module definitions use the whole-program C emitter. *)
let is_whole_program (program : Rake.Ast.program) =
  List.exists
    (fun (m : Rake.Ast.module_) ->
      List.exists
        (fun (d : Rake.Ast.def) ->
          match d.v with
          | DSlow _ | DRun _ | DRecord _ | DUnion _ | DState _ | DEmbed _ | DConst _ | DExtern _ -> true
          | _ -> false)
        m.mod_defs)
    program

let tier_check filename program =
  match Rake.Tier_check.check ~base_dir:(Filename.dirname filename) program with
  | Ok checked -> checked
  | Error message -> fail message

let whole_program_c ~addressing ~profile filename program =
  let checked = tier_check filename program in
  let execution_target = Rake.Tier_c.execution_target profile in
  match Rake.Tier_c.emit ~addressing ~execution_target ~source:filename checked with
  | text, facts, native_kernels -> (checked, text, facts, native_kernels)
  | exception Rake.Tier_c.Emission_error (loc, message) ->
      fail (Printf.sprintf "%s:%d:%d: %s emission: %s" loc.file loc.line loc.col
              (Rake.Target.profile_name profile) message)

let whole_program_object filename c_source =
  match Rake.Wasm_simd128_toolchain.assemble_program ~include_dir:(Filename.dirname filename) c_source with
  | Ok bytes -> bytes
  | Error error -> fail ("native object assembly failed: " ^ Rake.Wasm_simd128_toolchain.format_error error)

let verify_whole_program ~profile (checked : Rake.Tier_ir.program) facts object_bytes =
  let scratches =
    List.filter_map
      (fun (d : Rake.Ast.def) -> match d.v with DScratch (name, _, _, _) | DRake (name, _, _, _, _, _, _) -> Some name | _ -> None)
      checked.vector_defs
  in
  let runs =
    Hashtbl.fold
      (fun name facts acc -> (name, facts) :: acc)
      facts []
  in
  match Rake.Wasm_simd128_toolchain.verify_program
          ~relaxed:(profile = Rake.Target.Wasm_simd128_relaxed) ~scratches ~runs object_bytes with
  | Ok () -> ()
  | Error error -> fail ("native object verification failed: " ^ Rake.Wasm_simd128_toolchain.format_error error)

let report_backend = function
  | Ok product -> product
  | Error error -> fail (Rake.Native_backend.format_error error)

let () =
  let arguments = Array.to_list Sys.argv |> List.tl in
  match arguments with
  | [] | [ "--help" ] | [ "-h" ] -> print_endline usage
  | [ "--version" ] -> print_endline Rake.Version.display
  | [ "--print-capabilities" ] -> Rake.Capabilities.print stdout
  | [ "--print-targets" ] -> print_endline (Rake.Target.profile_list ())
  | _ ->
      let opts =
        {
          emit_mode = Check;
          target_selection = None;
          width = None;
          output = None;
          filename = None;
          program_arguments = None;
          addressing = Rake.Tier_c.Barrier;
        }
      in
      let select_mode mode option =
        match opts.emit_mode with
        | Check -> opts.emit_mode <- mode
        | _ -> fail (Printf.sprintf "Error: %s conflicts with another emission mode" option)
      in
      let rec parse = function
        | [] -> ()
        | "--" :: rest -> opts.program_arguments <- Some rest
        | "--emit-tokens" :: rest ->
            select_mode Tokens "--emit-tokens";
            parse rest
        | "--emit-ast" :: rest ->
            select_mode Ast "--emit-ast";
            parse rest
        | "--emit-native-ir" :: rest ->
            select_mode Native_ir "--emit-native-ir";
            parse rest
        | "--emit-c" :: rest ->
            select_mode C_source "--emit-c";
            parse rest
        | "--emit-asm" :: rest ->
            select_mode Assembly "--emit-asm";
            parse rest
        | "--emit-obj" :: rest ->
            select_mode Object "--emit-obj";
            parse rest
        | "--verify-native" :: rest ->
            select_mode Verify_native "--verify-native";
            parse rest
        | "--interpret" :: rest ->
            select_mode Interpret "--interpret";
            parse rest
        | "--target" :: value :: rest ->
            (match opts.target_selection with
            | Some _ -> fail "Error: --target may be specified only once"
            | None -> (
                match Rake.Target.selection_of_string value with
                | Ok selection -> opts.target_selection <- Some selection
                | Error message -> fail ("Error: " ^ message)));
            parse rest
        | [ "--target" ] -> fail "Error: --target requires a profile"
        | "--wasm-addressing" :: value :: rest ->
            (match value with
            | "barrier" -> opts.addressing <- Rake.Tier_c.Barrier
            | "plain" -> opts.addressing <- Rake.Tier_c.Plain
            | _ -> fail "Error: --wasm-addressing is barrier or plain");
            parse rest
        | "--width" :: value :: rest ->
            (match int_of_string_opt value with
            | Some width when width > 0 -> opts.width <- Some width
            | _ ->
                fail
                  (Printf.sprintf
                     "Invalid width: %s (must be a positive integer)" value));
            parse rest
        | [ "--width" ] -> fail "Error: --width requires a value"
        | ("-o" | "--output") :: path :: rest ->
            opts.output <- Some path;
            parse rest
        | [ ("-o" | "--output") ] -> fail "Error: -o requires a path"
        | argument :: rest
          when String.length argument > 0 && argument.[0] <> '-' ->
            (match opts.filename with
            | None -> opts.filename <- Some argument
            | Some _ -> fail "Error: more than one input file was specified");
            parse rest
        | option :: _ ->
            Printf.eprintf "Unknown option: %s\n%s" option usage;
            exit 1
      in
      parse arguments;
      if opts.program_arguments <> None && opts.emit_mode <> Interpret then
        fail "Error: arguments after -- require --interpret";
      let filename =
        match opts.filename with
        | Some filename -> filename
        | None -> fail "Error: No input file specified"
      in
      (match (opts.emit_mode, opts.output) with
      | (Check | Tokens | Ast), Some _ ->
          fail "Error: -o requires an IR, C, assembly, or object emission mode"
      | _ -> ());
      match opts.emit_mode with
      | Tokens -> print_string (emit_tokens filename)
      | Ast ->
          let program = parse_program filename in
          print_endline (Rake.Ast.show_program program)
      | Interpret -> (
          let program = parse_program filename in
          let _ = typecheck program in
          let checked = tier_check filename program in
          let profile = match opts.target_selection, opts.width with
            | None, None -> Rake.Target.Wasm_simd128
            | _ -> (resolve_target_config opts).profile in
          match Rake.Tier_interp.run_main ~profile ~program_name:filename
            ~arguments:(Option.value opts.program_arguments ~default:[]) checked with
          | Ok value -> Printf.printf "%Ld\n" value
          | Error message -> fail message)
      | Check ->
          if not (Filename.check_suffix filename ".rk") then
            fail (Printf.sprintf "Unknown file type: %s (expected .rk)" filename);
          let program = parse_program filename in
          let _ =
            match (opts.target_selection, opts.width) with
            | None, None -> None
            | _ -> Some (resolve_target_config opts)
          in
          let _ = typecheck program in
          if is_whole_program program then ignore (tier_check filename program);
          Printf.printf "Parsed and type-checked %s successfully.\n" filename
      | (Native_ir | C_source | Assembly | Object | Verify_native) as mode ->
          let program = parse_program filename in
          let _ = typecheck program in
          let config = resolve_target_config opts in
          let whole_program = is_whole_program program in
          if mode = Assembly && (whole_program || Rake.Target.is_wasm config.profile) then
            fail "Error: --emit-asm requires physical-target register kernels; use --emit-c for whole programs or WebAssembly";
          if whole_program || (mode = C_source && not (Rake.Target.is_wasm config.profile)) then (
            let checked, c_source, facts, native_kernels = whole_program_c ~addressing:opts.addressing ~profile:config.profile filename program in
            let default extension = Some (match opts.output with Some path -> path | None -> source_stem filename ^ extension) in
            match mode with
            | Native_ir ->
                let native = report_backend (Rake.Native_backend.lower ~config [ { Rake.Ast.mod_name = "main"; mod_defs = checked.vector_defs } ]) in
                write_output (Rake.Native_ir.dump native ^ Rake.Tier_ir.dump checked) opts.output
            | C_source -> write_output c_source (default ".c")
            | (Object | Verify_native) when not (Rake.Target.is_wasm config.profile) ->
                if mode = Verify_native && native_kernels = None then
                  fail "Error: native slow-only code has no vector functions to verify; use --emit-obj for its platform C compilation";
                let bytes = match Rake.Native_toolchain.compile_program ~profile:config.profile
                         ~source:filename ~include_dir:(Filename.dirname filename) c_source with
                  | Ok bytes -> bytes
                  | Error error -> fail (Rake.Native_toolchain.format_error error) in
                Option.iter (fun selection ->
                  Option.iter (fun allocated -> ignore (report_backend
                    (Rake.Native_backend.verify_allocated_object ~source:filename ~config allocated bytes))) selection.Rake.Tier_c.registers;
                  Option.iter (fun traversals ->
                    let expected = match Rake.Native_toolchain.assemble ~profile:config.profile
                      ~source:filename traversals.Rake.Native_traversal.assembly with
                      | Ok bytes -> bytes | Error e -> fail (Rake.Native_toolchain.format_error e) in
                    match Rake.Native_verify.fixed_native_functions ~profile:config.profile ~source:filename
                      ~functions:traversals.functions ~expected bytes with
                    | Ok () -> () | Error e -> fail (Rake.Native_verify.format_error e)) selection.traversals) native_kernels;
                write_output bytes (default ".o")
            | Object -> write_output (whole_program_object filename c_source) (default ".o")
            | _ ->
                let object_bytes = whole_program_object filename c_source in
                verify_whole_program ~profile:config.profile checked facts object_bytes;
                write_output object_bytes (default ".o"))
          else
          (match mode with
          | Native_ir ->
              let native_ir = report_backend (Rake.Native_backend.lower ~config program) in
              write_output (Rake.Native_ir.dump native_ir) opts.output
          | C_source | Assembly ->
              let assembly =
                report_backend (Rake.Native_backend.emit_assembly ~source:filename ~config program)
              in
              let extension = if mode = C_source then ".c" else ".s" in
              let output =
                Some
                  (match opts.output with
                  | Some path -> path
                  | None -> source_stem filename ^ extension)
              in
              write_output assembly output
          | Object ->
              let object_bytes =
                report_backend
                  (Rake.Native_backend.emit_object ~source:filename ~config program)
              in
              let output =
                Some
                  (match opts.output with
                  | Some path -> path
                  | None -> source_stem filename ^ ".o")
              in
              write_output object_bytes output
          | Verify_native ->
              let object_bytes =
                report_backend
                  (Rake.Native_backend.emit_verified_object ~source:filename
                     ~config program)
              in
              let output =
                Some
                  (match opts.output with
                  | Some path -> path
                  | None -> source_stem filename ^ ".o")
              in
              write_output object_bytes output
          | _ -> assert false)
