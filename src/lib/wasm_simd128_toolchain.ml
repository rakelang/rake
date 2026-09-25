(** Encoding and verification for the [wasm-simd128] profile.

    The C that {!Wasm_simd128_c} emits is compiled with every function given
    external linkage, then disassembled, so verification sees what Clang made
    of the intrinsics rather than the intrinsics themselves. Verification accepts a function only
    if its body is exactly local traffic, constants and SIMD instructions: no
    calls, no memory access, no control flow and no use of the C stack, which
    would appear as a global stack-pointer access. *)

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

(** Locals, constants and register-to-register SIMD; no memory, calls or control flow. *)
let allowed_instruction name =
  List.mem name [ "local.get"; "local.set"; "local.tee"; "i32.const"; "f32.reinterpret_i32"; "end" ]
  || List.exists (fun prefix -> String.starts_with ~prefix name) [ "v128."; "i8x16."; "i32x4."; "f32x4." ]
     && not (contains name "load" || contains name "store")

(** Function name to instruction mnemonics, from llvm-objdump's wasm disassembly. *)
let disassembled_functions listing =
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
               let mnemonic =
                 match String.index_from_opt instruction 0 '\t' with
                 | Some tab -> String.sub instruction 0 tab
                 | None -> (
                     match String.index_opt instruction ' ' with
                     | Some space -> String.sub instruction 0 space
                     | None -> instruction)
               in
               if mnemonic <> "" then Hashtbl.replace functions name (Hashtbl.find functions name @ [ mnemonic ])
           | _ -> ());
  functions

let verify ~functions object_bytes =
  let object_path = Filename.temp_file "rake-wasm-verify-" ".o" in
  Out_channel.with_open_bin object_path (fun channel -> output_string channel object_bytes);
  Fun.protect
    ~finally:(fun () -> Sys.remove object_path)
    (fun () ->
      let* listing =
        run (Printf.sprintf "%s -d --no-show-raw-insn %s" (disassembler ()) (Filename.quote object_path))
      in
      let disassembled = disassembled_functions listing in
      List.fold_left
        (fun result name ->
          let* () = result in
          match Hashtbl.find_opt disassembled name with
          | None -> Error { message = Printf.sprintf "function %s is missing from the encoded object" name }
          | Some mnemonics -> (
              match List.find_opt (fun mnemonic -> not (allowed_instruction mnemonic)) mnemonics with
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
