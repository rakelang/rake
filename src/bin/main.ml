(** Command-line interface for the Rake compiler. *)

let usage =
  {|
rakec - compiler for the Rake vector-first CPU kernel language

Usage:
  rakec <file.rk>                     Parse and type-check
  rakec --emit-tokens <file.rk>       Emit tokens (for debugging)
  rakec --emit-ast <file.rk>          Emit AST (for debugging)
  rakec --emit-native-ir <file.rk>    Emit rack-preserving native SSA
  rakec --emit-asm <file.rk>          Emit Rake-owned textual assembly
  rakec --emit-obj <file.rk>          Assemble Rake-owned code to an object
  rakec --verify-native <file.rk>     Verify and emit a Rake-owned object
  rakec --print-capabilities          Print the frontend semantic contract
  rakec --print-targets               Print available native profiles
  rakec --version                     Show version
  rakec --help                        Show this help

Options:
  --target <p>   Select native, scalar, x86-sse2, x86-avx2, x86-avx512,
                 or aarch64-neon (default: native).
  --width <n>    Compatibility assertion. It must equal the selected profile's
                 f32 lane count; it never changes or splits a native rack.
  -o <file>      Write the selected emission product to <file>.

The production backends currently accept x86-avx2 and aarch64-neon. Rake owns
native SSA, instruction selection, no-spill allocation, and textual assembly emission.
An external tool is invoked only to assemble Rake's text into an object file.

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

let parse_file filename =
  let source = read_source filename in
  let lexbuf = Lexing.from_string source in
  lexbuf.Lexing.lex_curr_p <-
    { lexbuf.Lexing.lex_curr_p with Lexing.pos_fname = filename };
  match Rake.Layout.validate ~filename source with
  | Error _ as failure -> failure
  | Ok () -> (
      try Ok (Rake.Parser.program Rake.Lexer.token lexbuf) with
      | Rake.Lexer.LexError (message, position) ->
          Error
            (Printf.sprintf "%s:%d:%d: Lexical error: %s"
               position.Lexing.pos_fname position.Lexing.pos_lnum
               (position.Lexing.pos_cnum - position.Lexing.pos_bol)
               message)
      | Rake.Parser.Error ->
          let position = lexbuf.Lexing.lex_curr_p in
          Error
            (Printf.sprintf "%s:%d:%d: Syntax error" position.Lexing.pos_fname
               position.Lexing.pos_lnum
               (position.Lexing.pos_cnum - position.Lexing.pos_bol)))

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
  | Assembly
  | Object
  | Verify_native

type opts = {
  mutable emit_mode : emit_mode;
  mutable target_selection : Rake.Target.selection option;
  mutable width : int option;
  mutable output : string option;
  mutable filename : string option;
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
        }
      in
      let select_mode mode option =
        match opts.emit_mode with
        | Check -> opts.emit_mode <- mode
        | _ -> fail (Printf.sprintf "Error: %s conflicts with another emission mode" option)
      in
      let rec parse = function
        | [] -> ()
        | "--emit-tokens" :: rest ->
            select_mode Tokens "--emit-tokens";
            parse rest
        | "--emit-ast" :: rest ->
            select_mode Ast "--emit-ast";
            parse rest
        | "--emit-native-ir" :: rest ->
            select_mode Native_ir "--emit-native-ir";
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
        | "--target" :: value :: rest ->
            (match opts.target_selection with
            | Some _ -> fail "Error: --target may be specified only once"
            | None -> (
                match Rake.Target.selection_of_string value with
                | Ok selection -> opts.target_selection <- Some selection
                | Error message -> fail ("Error: " ^ message)));
            parse rest
        | [ "--target" ] -> fail "Error: --target requires a profile"
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
      let filename =
        match opts.filename with
        | Some filename -> filename
        | None -> fail "Error: No input file specified"
      in
      (match (opts.emit_mode, opts.output) with
      | (Check | Tokens | Ast), Some _ ->
          fail "Error: -o requires an IR, assembly, or object emission mode"
      | _ -> ());
      match opts.emit_mode with
      | Tokens -> print_string (emit_tokens filename)
      | Ast ->
          let program = parse_program filename in
          print_endline (Rake.Ast.show_program program)
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
          Printf.printf "Parsed and type-checked %s successfully.\n" filename
      | (Native_ir | Assembly | Object | Verify_native) as mode ->
          let program = parse_program filename in
          let _ = typecheck program in
          let config = resolve_target_config opts in
          (match mode with
          | Native_ir ->
              let native_ir = report_backend (Rake.Native_backend.lower ~config program) in
              write_output (Rake.Native_ir.dump native_ir) opts.output
          | Assembly ->
              let assembly =
                report_backend (Rake.Native_backend.emit_assembly ~config program)
              in
              let output =
                Some
                  (match opts.output with
                  | Some path -> path
                  | None -> source_stem filename ^ ".s")
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
