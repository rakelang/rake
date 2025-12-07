(** Rake 0.2.0 Compiler

    Command-line interface for the rake compiler. *)

let usage =
  {|
rakec - compiler for the rake vector-first programming language for CPU SIMD and GPU

Usage:
  rakec <file.rk>                     Parse and type-check
  rakec --emit-tokens <file.rk>       Emit tokens (for debugging)
  rakec --emit-ast <file.rk>          Emit AST (for debugging)
  rakec --emit-mlir <file.rk>         Emit MLIR (CPU mode, default width 8)
  rakec --emit-mlir --gpu <file.rk>   Emit MLIR (GPU mode, scf.parallel)
  rakec --version                     Show version
  rakec --help                        Show this help

Options:
  --gpu          Target GPU (emit scf.parallel with scalar ops)
  --width <n>    Vector width for CPU mode:
                   1  = scalar (fallback)
                   4  = SSE/NEON (128-bit)
                   8  = AVX/AVX2 (256-bit) [default]
                   16 = AVX-512 (512-bit)

Emission modes:
  CPU (default): Explicit vectorization with vector<Nxf32> types.
                 Uses scf.for loops with vector.load/maskedstore.
                 Width determines SIMD register size.

  GPU (--gpu):   Scalar operations with scf.parallel loops.
                 Uses memref.load/store for memory access.
                 Suitable for SPIR-V/Vulkan/CUDA lowering.

Examples:
  rake --emit-mlir examples/raytracer.rk           # AVX2 (width 8)
  rake --emit-mlir --width 4 examples/raytracer.rk # SSE (width 4)
  rake --emit-mlir --width 16 examples/raytracer.rk # AVX-512
  rake --emit-mlir --gpu examples/raytracer.rk     # GPU scalar
|}

let version = "rake 0.2.0"

let parse_file filename =
  let ic = open_in filename in
  let lexbuf = Lexing.from_channel ic in
  lexbuf.Lexing.lex_curr_p <-
    { lexbuf.Lexing.lex_curr_p with Lexing.pos_fname = filename };
  try
    let program = Rake.Parser.program Rake.Lexer.token lexbuf in
    close_in ic;
    Ok program
  with
  | Rake.Lexer.LexError (msg, pos) ->
      close_in ic;
      Error
        (Printf.sprintf "%s:%d:%d: Lexical error: %s" pos.Lexing.pos_fname
           pos.Lexing.pos_lnum
           (pos.Lexing.pos_cnum - pos.Lexing.pos_bol)
           msg)
  | Rake.Parser.Error ->
      close_in ic;
      let pos = lexbuf.Lexing.lex_curr_p in
      Error
        (Printf.sprintf "%s:%d:%d: Syntax error" pos.Lexing.pos_fname
           pos.Lexing.pos_lnum
           (pos.Lexing.pos_cnum - pos.Lexing.pos_bol))

let emit_tokens filename =
  let ic = open_in filename in
  let lexbuf = Lexing.from_channel ic in
  lexbuf.Lexing.lex_curr_p <-
    { lexbuf.Lexing.lex_curr_p with Lexing.pos_fname = filename };
  let result = Rake.Lexer.emit lexbuf in
  close_in ic;
  result

let emit_ast program = Rake.Ast.show_program program

(** Emit MLIR with configurable target and width *)
let emit_mlir ~gpu ~width env program =
  if gpu then Rake.Mlir.emit_gpu env program
  else Rake.Mlir.emit ~width env program

type opts = {
  mutable emit_mode : [ `None | `Tokens | `Ast | `Mlir | `Check ];
  mutable gpu : bool;
  mutable width : int;
  mutable filename : string option;
}
(** Parse arguments into structured options *)

let () =
  let args = Array.to_list Sys.argv |> List.tl in

  (* Handle simple cases first *)
  match args with
  | [] | [ "--help" ] | [ "-h" ] -> print_endline usage
  | [ "--version" ] -> print_endline version
  | _ -> (
      (* Parse arguments *)
      let opts =
        { emit_mode = `None; gpu = false; width = 8; filename = None }
      in
      let rec parse = function
        | [] -> ()
        | "--emit-tokens" :: rest ->
            opts.emit_mode <- `Tokens;
            parse rest
        | "--emit-ast" :: rest ->
            opts.emit_mode <- `Ast;
            parse rest
        | "--emit-mlir" :: rest ->
            opts.emit_mode <- `Mlir;
            parse rest
        | "--gpu" :: rest ->
            opts.gpu <- true;
            parse rest
        | "--width" :: n :: rest ->
            (match int_of_string_opt n with
            | Some w when w = 1 || w = 4 || w = 8 || w = 16 -> opts.width <- w
            | _ ->
                Printf.eprintf "Invalid width: %s (must be 1, 4, 8, or 16)\n" n;
                exit 1);
            parse rest
        | "--width" :: [] ->
            prerr_endline "Error: --width requires a value";
            exit 1
        | arg :: rest when String.length arg > 0 && arg.[0] <> '-' ->
            opts.filename <- Some arg;
            parse rest
        | arg :: _ ->
            Printf.eprintf "Unknown option: %s\n" arg;
            prerr_endline usage;
            exit 1
      in
      parse args;

      match opts.filename with
      | None ->
          prerr_endline "Error: No input file specified";
          exit 1
      | Some filename -> (
          match opts.emit_mode with
          | `Tokens -> print_string (emit_tokens filename)
          | `Ast -> (
              match parse_file filename with
              | Ok program -> print_endline (emit_ast program)
              | Error msg ->
                  prerr_endline msg;
                  exit 1)
          | `Mlir -> (
              match parse_file filename with
              | Ok program -> (
                  match Rake.Typecheck.check program with
                  | Ok env ->
                      print_endline
                        (emit_mlir ~gpu:opts.gpu ~width:opts.width env program)
                  | Error msg ->
                      prerr_endline msg;
                      exit 1)
              | Error msg ->
                  prerr_endline msg;
                  exit 1)
          | `Check | `None ->
              (* Default: parse and type-check *)
              if
                String.length filename > 3
                && String.sub filename (String.length filename - 3) 3 = ".rk"
              then (
                match parse_file filename with
                | Ok program -> (
                    match Rake.Typecheck.check program with
                    | Ok _env ->
                        Printf.printf
                          "Parsed and type-checked %s successfully.\n" filename
                    | Error msg ->
                        prerr_endline msg;
                        exit 1)
                | Error msg ->
                    prerr_endline msg;
                    exit 1)
              else (
                Printf.eprintf "Unknown file type: %s (expected .rk)\n" filename;
                exit 1)))
