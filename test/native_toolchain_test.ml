let assembly =
  {|
.intel_syntax noprefix
.text
.p2align 4
.globl rake_native_add
.hidden rake_native_add
.type rake_native_add, @function
rake_native_add:
    vaddps ymm0, ymm0, ymm1
    ret
.size rake_native_add, .-rake_native_add
.section .note.GNU-stack,"",@progbits
|}

let write_file path contents =
  let channel = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out_noerr channel) (fun () ->
      output_string channel contents)

let read_file path =
  let channel = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in_noerr channel) (fun () ->
      really_input_string channel (in_channel_length channel))

let inspect object_bytes =
  let object_ = Filename.temp_file "rake-native-test-" ".o" in
  let output = Filename.temp_file "rake-native-test-" ".objdump" in
  Fun.protect
    ~finally:(fun () ->
      List.iter
        (fun path -> try Sys.remove path with Sys_error _ -> ())
        [ object_; output ])
    (fun () ->
      write_file object_ object_bytes;
      let input = Unix.openfile "/dev/null" [ Unix.O_RDONLY ] 0 in
      let destination =
        Unix.openfile output [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600
      in
      let status =
        Fun.protect
          ~finally:(fun () ->
            Unix.close input;
            Unix.close destination)
          (fun () ->
            let argv =
              [|
                "objdump";
                "-d";
                "-M";
                "intel";
                "--no-show-raw-insn";
                object_;
              |]
            in
            let pid =
              Unix.create_process "objdump" argv input destination destination
            in
            snd (Unix.waitpid [] pid))
      in
      match status with
      | Unix.WEXITED 0 -> read_file output
      | _ -> failwith "objdump failed while inspecting native fixture")

let contains text needle =
  let pattern = Str.regexp_string needle in
  try
    ignore (Str.search_forward pattern text 0);
    true
  with Not_found -> false

let () =
  let object_bytes =
    match Rake.Native_toolchain.assemble ~source:"native-toolchain-test" assembly with
    | Ok bytes -> bytes
    | Error error -> failwith (Rake.Native_toolchain.format_error error)
  in
  if String.length object_bytes < 4 || String.sub object_bytes 0 4 <> "\x7fELF"
  then failwith "native assembler did not return an ELF object";
  let disassembly = inspect object_bytes in
  if not (contains disassembly "ymm") then
    failwith "objdump output did not contain a YMM operand";
  if not (contains disassembly "vaddps") then
    failwith "objdump output did not contain vaddps";
  (match
     Rake.Native_toolchain.assemble ~source:"broken-native-fixture"
       ".text\nthis_is_not_an_instruction\n"
   with
  | Ok _ -> failwith "invalid native assembly unexpectedly succeeded"
  | Error error ->
      if error.stage <> Rake.Native_toolchain.Assemble then
        failwith "invalid assembly reported the wrong failure stage";
      if
        not
          (String.starts_with ~prefix:"broken-native-fixture: native assembly failed:"
             (Rake.Native_toolchain.format_error error))
      then failwith "native assembly diagnostic omitted its source and stage");
  print_endline "native textual assembly toolchain test passed"
