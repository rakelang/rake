(** Shell-free assembler boundary for Rake-owned native backends.

    This module owns only textual assembly -> relocatable object conversion.
    Instruction selection, register allocation, linking, and execution belong
    elsewhere.  GNU as is the encoding boundary: it does not select,
    allocate, schedule, or otherwise optimise instructions. *)

type stage = Assemble

type error = {
  source : string;
  stage : stage;
  detail : string;
}

let stage_name = function Assemble -> "native assembly"

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
  | Target.X86_avx2 -> ("as", [ "--64" ])
  | profile ->
      invalid_arg
        (Printf.sprintf "no assembler configured for profile '%s'"
           (Target.profile_name profile))

let run_assembler ~profile ~source ~assembly ~object_ ~log =
  let input = Unix.openfile "/dev/null" [ Unix.O_RDONLY ] 0 in
  let output =
    Unix.openfile log [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o600
  in
  Fun.protect
    ~finally:(fun () ->
      Unix.close input;
      Unix.close output)
    (fun () ->
      let program, prefix = assembler_command profile in
      let arguments = prefix @ [ "-o"; object_; assembly ] in
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
            Error { source; stage = Assemble; detail }
      with Unix.Unix_error (error, call, _) ->
        Error
          {
            source;
            stage = Assemble;
            detail =
              Printf.sprintf "cannot execute %s (%s: %s)" program call
                (Unix.error_message error);
          })

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
