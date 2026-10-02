(** Shell-free encoding boundaries for Rake-owned native backends.

    This module owns assembly and explicit slow C -> relocatable objects.
    Instruction selection, register allocation, linking, and execution belong
    elsewhere.  GNU as is the encoding boundary: it does not select,
    allocate, schedule, or otherwise optimise instructions. *)

type stage = Assemble | Compile_slow

type error = {
  source : string;
  stage : stage;
  detail : string;
}

let stage_name = function Assemble -> "native assembly" | Compile_slow -> "native slow C compilation"

let format_error error =
  Printf.sprintf "%s: %s failed: %s" error.source
    (stage_name error.stage) error.detail

let read_file path =
  let channel = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in_noerr channel) (fun () ->
      really_input_string channel (in_channel_length channel))

let write_file path contents =
  let channel = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out_noerr channel) (fun () ->
      output_string channel contents)

let status_text = function
  | Unix.WEXITED code -> Printf.sprintf "exit status %d" code
  | Unix.WSIGNALED signal -> Printf.sprintf "signal %d" signal
  | Unix.WSTOPPED signal -> Printf.sprintf "stop signal %d" signal

let assembler_command = function
  | Target.Aarch64_neon -> ("aarch64-unknown-linux-gnu-as", [])
  | Target.X86_sse2 | Target.X86_avx2 | Target.X86_avx512 -> ("as", [ "--64" ])
  | profile ->
      invalid_arg
        (Printf.sprintf "no assembler configured for profile '%s'"
           (Target.profile_name profile))

let run_encoder ~stage ~program ~arguments ~source ~log =
  let input = Unix.openfile "/dev/null" [ Unix.O_RDONLY ] 0 in
  let output =
    Unix.openfile log [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o600
  in
  Fun.protect
    ~finally:(fun () ->
      Unix.close input;
      Unix.close output)
    (fun () ->
      let argv = Array.of_list (program :: arguments) in
      try
        let pid = Unix.create_process program argv input output output in
        let _, status = Unix.waitpid [] pid in
        let diagnostic = String.trim (read_file log) in
        match status with
        | Unix.WEXITED 0 -> Ok ()
        | _ ->
            let detail =
              if diagnostic = "" then status_text status
              else Printf.sprintf "%s\n%s" (status_text status) diagnostic
            in
            Error { source; stage; detail }
      with Unix.Unix_error (error, call, _) ->
        Error
          {
            source;
            stage;
            detail =
              Printf.sprintf "cannot execute %s (%s: %s)" program call
                (Unix.error_message error);
          })

let run_assembler ~profile ~source ~assembly ~object_ ~log =
  let program, prefix = assembler_command profile in
  run_encoder ~stage:Assemble ~program
    ~arguments:(prefix @ [ "-o"; object_; assembly ]) ~source ~log

let assemble ?(profile = Target.X86_avx2) ~source assembly_text =
  let assembly = Filename.temp_file "rake-native-" ".s" in
  let object_ = Filename.temp_file "rake-native-" ".o" in
  let log = Filename.temp_file "rake-native-" ".log" in
  let files = [ assembly; object_; log ] in
  Fun.protect
    ~finally:(fun () ->
      List.iter
        (fun path -> try Sys.remove path with Sys_error _ -> ())
        files)
    (fun () ->
      try
        write_file assembly assembly_text;
        match run_assembler ~profile ~source ~assembly ~object_ ~log with
        | Ok () -> Ok (read_file object_)
        | Error _ as error -> error
      with Sys_error detail -> Error { source; stage = Assemble; detail })

(** Only explicit slow code enters this C boundary. Vector functions and runs
    must use Rake's instruction-selection and object-verification pipelines. *)
let compile_slow_program ~profile ~source ~include_dir c_source =
  let default_compiler, profile_flags =
    match profile with
    | Target.X86_sse2 -> ("gcc", [ "-march=x86-64"; "-msse2"; "-mno-avx" ])
    | Target.X86_avx2 -> ("gcc", [ "-march=x86-64"; "-mavx2"; "-mfma" ])
    | Target.X86_avx512 -> ("gcc", [ "-march=x86-64"; "-mavx512f" ])
    | Target.Aarch64_neon -> ("aarch64-unknown-linux-gnu-gcc", [ "-march=armv8-a" ])
    | _ -> invalid_arg "native slow C requires a physical SIMD profile"
  in
  let program = Option.value (Sys.getenv_opt "RAKE_NATIVE_CC") ~default:default_compiler in
  let c_path = Filename.temp_file "rake-native-slow-" ".c" in
  let object_ = Filename.temp_file "rake-native-slow-" ".o" in
  let log = Filename.temp_file "rake-native-slow-" ".log" in
  Fun.protect
    ~finally:(fun () ->
      List.iter (fun path -> try Sys.remove path with Sys_error _ -> ()) [ c_path; object_; log ])
    (fun () ->
      try
        write_file c_path c_source;
        let arguments =
          profile_flags
          @ [ "-std=gnu11"; "-O2"; "-ffp-contract=off"; "-fno-fast-math"; "-Werror";
              "-I"; include_dir; "-c"; c_path; "-o"; object_ ]
        in
        match run_encoder ~stage:Compile_slow ~program ~arguments ~source ~log with
        | Ok () -> Ok (read_file object_)
        | Error _ as error -> error
      with Sys_error detail -> Error { source; stage = Compile_slow; detail })
