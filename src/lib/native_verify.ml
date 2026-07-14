(** Object-code contract verification for Rake-owned native backends.

    Each profile has a separate allow-list.  Widening one emitter therefore
    cannot silently weaken the machine contract of another target. *)

type error = {
  source : string;
  function_name : string option;
  obligation : string;
  detail : string;
}

let format_error error =
  let subject =
    match error.function_name with
    | None -> error.source
    | Some function_name -> Printf.sprintf "%s: %s" error.source function_name
  in
  Printf.sprintf "%s: native object verification failed (%s): %s" subject
    error.obligation error.detail

let error ?function_name ~source ~obligation detail =
  Error { source; function_name; obligation; detail }

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

type run_result = Ran of Unix.process_status | Missing | Failed of string

let run program arguments ~output =
  let input = Unix.openfile "/dev/null" [ Unix.O_RDONLY ] 0 in
  let destination =
    Unix.openfile output [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o600
  in
  Fun.protect
    ~finally:(fun () ->
      Unix.close input;
      Unix.close destination)
    (fun () ->
      let argv = Array.of_list (program :: arguments) in
      try
        let pid = Unix.create_process program argv input destination destination in
        let _, status = Unix.waitpid [] pid in
        Ran status
      with
      | Unix.Unix_error (Unix.ENOENT, _, _) -> Missing
      | Unix.Unix_error (unix_error, call, _) ->
          Failed
            (Printf.sprintf "%s: %s" call (Unix.error_message unix_error)))

let disassembler_command = function
  | Target.X86_avx2 ->
      ("objdump", [ "-d"; "-M"; "intel"; "--no-show-raw-insn" ])
  | Target.Aarch64_neon ->
      ("aarch64-unknown-linux-gnu-objdump", [ "-d"; "--no-show-raw-insn" ])
  | profile ->
      invalid_arg
        (Printf.sprintf "no disassembler configured for profile '%s'"
           (Target.profile_name profile))

let disassemble ~profile ~source ~object_ ~output =
  let program, prefix = disassembler_command profile in
  let arguments = prefix @ [ object_ ] in
  match run program arguments ~output with
  | Missing ->
      error ~source ~obligation:"disassembler"
        "GNU objdump could not be executed"
  | Failed detail ->
      error ~source ~obligation:"disassembler"
        (Printf.sprintf "cannot execute GNU objdump (%s)" detail)
  | Ran (Unix.WEXITED 0) -> Ok (read_file output)
  | Ran status ->
      error ~source ~obligation:"disassembler"
        (Printf.sprintf "GNU objdump failed with %s" (status_text status))

type decoded = { mnemonic : string; operands : string }

let all_hex text =
  String.length text > 0
  && String.for_all
       (function '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' -> true | _ -> false)
       text

let header_name line =
  match (String.index_opt line '<', String.rindex_opt line '>') with
  | Some left, Some right
    when left > 1 && right = String.length line - 2
         && line.[String.length line - 1] = ':'
         && all_hex (String.sub line 0 (left - 1)) ->
      Some (String.sub line (left + 1) (right - left - 1))
  | _ -> None

let instruction_of_line line =
  match String.index_opt line ':' with
  | None -> None
  | Some colon when all_hex (String.sub line 0 colon) ->
      let body =
        String.sub line (colon + 1) (String.length line - colon - 1)
        |> String.trim
      in
      if body = "" then None
      else
        let boundary =
          let rec find index =
            if index = String.length body then index
            else if body.[index] = ' ' || body.[index] = '\t' then index
            else find (index + 1)
          in
          find 0
        in
        Some
          {
            mnemonic =
              String.sub body 0 boundary |> String.lowercase_ascii;
            operands =
              String.sub body boundary (String.length body - boundary)
              |> String.trim |> String.lowercase_ascii;
          }
  | Some _ -> None

let decode_functions text =
  let functions = Hashtbl.create 16 in
  let current = ref None in
  String.split_on_char '\n' text
  |> List.iter (fun line ->
         let line = String.trim line in
         match header_name line with
         | Some name ->
           current := Some name;
           if not (Hashtbl.mem functions name) then Hashtbl.add functions name []
         | None -> (
             match (!current, instruction_of_line line) with
             | Some name, Some decoded ->
                 Hashtbl.replace functions name
                   (decoded :: Hashtbl.find functions name)
             | _ -> ()));
  Hashtbl.iter
    (fun name instructions ->
      Hashtbl.replace functions name (List.rev instructions))
    functions;
  functions

let allowed_avx2 = function
  | "vbroadcastss" | "vxorps" | "vaddps" | "vsubps" | "vmulps"
  | "vdivps" | "vsqrtps" | "vfmadd213ps" | "vfmadd231ps" | "vcmpps"
  | "vcmpeq_oqps" | "vcmpneq_oqps" | "vcmplt_oqps" | "vcmple_oqps"
  | "vcmpeqps" | "vcmpneqps" | "vcmpltps" | "vcmpleps"
  | "vcmpunordps"
  | "vblendvps" | "vandps" | "vorps" | "vmovaps" | "ret" | "retq" ->
      true
  | "vperm2f128" | "vpermilps" | "vblendps" -> true
  | "vpxor" | "vpcmpeqd" -> true
  | _ -> false

let is_fma profile =
  match profile with
  | Target.X86_avx2 -> (function "vfmadd213ps" | "vfmadd231ps" -> true | _ -> false)
  | Target.Aarch64_neon -> (function "fmla" -> true | _ -> false)
  | _ -> fun _ -> false

let contains text needle =
  try
    ignore (Str.search_forward (Str.regexp_string needle) text 0);
    true
  with Not_found -> false

let is_alignment_padding decoded =
  match decoded.mnemonic with
  | "nop" | "nopl" | "nopw" -> true
  | "cs" | "data16" -> contains decoded.operands "nop"
  | _ -> false

let cross_lane_mnemonic = function
  | "vperm2f128" | "vpermilps" | "vblendps" -> true
  | _ -> false

let verify_avx2_instruction ~allow_cross_lane ~source ~function_name decoded =
  let mnemonic = decoded.mnemonic in
  let operands = decoded.operands in
  if String.starts_with ~prefix:"call" mnemonic then
    error ~source ~function_name ~obligation:"no calls"
      (Printf.sprintf "encountered %s" mnemonic)
  else if contains operands "rsp" || contains operands "rbp" then
    error ~source ~function_name ~obligation:"no stack use"
      (Printf.sprintf "encountered %s %s" mnemonic operands)
  else if
    contains operands "["
    && not
         ((mnemonic = "vbroadcastss" || mnemonic = "vxorps")
         && contains operands "rip")
  then
    error ~source ~function_name ~obligation:"no rack memory"
      (Printf.sprintf "encountered %s %s" mnemonic operands)
  else if
    contains operands "xmm"
    && not (mnemonic = "vbroadcastss" && contains operands "ymm")
  then
    error ~source ~function_name ~obligation:"one YMM per rack"
      (Printf.sprintf "encountered %s %s" mnemonic operands)
  else if contains operands "zmm" then
    error ~source ~function_name ~obligation:"one YMM per rack"
      (Printf.sprintf "encountered %s %s" mnemonic operands)
  else if cross_lane_mnemonic mnemonic && not allow_cross_lane then
    error ~source ~function_name ~obligation:"source-authorized cross-lane operation"
      (Printf.sprintf "encountered %s outside a reduction or scan" mnemonic)
  else if not (allowed_avx2 mnemonic) then
    let obligation =
      if String.starts_with ~prefix:"f" mnemonic
         || String.starts_with ~prefix:"x87" mnemonic
      then "no scalar or x87 arithmetic"
      else "instruction allow-list"
    in
    error ~source ~function_name ~obligation
      (Printf.sprintf "unexpected instruction %s%s" mnemonic
         (if operands = "" then "" else " " ^ operands))
  else Ok ()

let regexp_contains pattern text =
  try
    ignore (Str.search_forward (Str.regexp pattern) text 0);
    true
  with Not_found -> false

let allowed_neon = function
  | "movi" | "ldr" | "dup" | "fadd" | "fsub" | "fmul" | "fdiv"
  | "fsqrt" | "fmla" | "fcmeq" | "fcmgt" | "fcmge" | "and" | "orr"
  | "eor" | "mvn" | "bsl" | "bit" | "bif" | "mov" | "ret" -> true
  | _ -> false

let neon_callee_saved_vector operands =
  regexp_contains "\\bv\\(8\\|9\\|1[0-5]\\)\\." operands
  || regexp_contains "\\bq\\(8\\|9\\|1[0-5]\\)\\b" operands

let neon_scalar_register operands =
  regexp_contains "\\(^\\|[, \\t]+\\)[sd][0-9]+\\b" operands

let neon_general_register operands =
  regexp_contains "\\(^\\|[, \\t]+\\)[xw][0-9]+\\b" operands

let valid_neon_dup operands =
  regexp_contains
    "^v\\([0-9]+\\)\\.4s,[ \\t]*v\\([0-9]+\\)\\.s\\[0\\]$"
    operands

let valid_neon_literal_load operands =
  regexp_contains "^q[0-9]+,[ \\t]*[0-9a-f]+[ \\t]*<[^>]+>$" operands

let verify_neon_instruction ~source ~function_name decoded =
  let mnemonic = decoded.mnemonic in
  let operands = decoded.operands in
  if mnemonic = "bl" || mnemonic = "blr" then
    error ~source ~function_name ~obligation:"no calls"
      (Printf.sprintf "encountered %s" mnemonic)
  else if contains operands "sp" || contains operands "x29" then
    error ~source ~function_name ~obligation:"no stack use"
      (Printf.sprintf "encountered %s %s" mnemonic operands)
  else if neon_callee_saved_vector operands then
    error ~source ~function_name ~obligation:"AAPCS64 leaf register set"
      (Printf.sprintf "encountered partially callee-saved register in %s %s"
         mnemonic operands)
  else if neon_general_register operands then
    error ~source ~function_name ~obligation:"no scalarized lane control"
      (Printf.sprintf "encountered general register in %s %s" mnemonic operands)
  else if mnemonic = "ldr" && not (valid_neon_literal_load operands) then
    error ~source ~function_name ~obligation:"literal rack loads only"
      (Printf.sprintf "encountered %s %s" mnemonic operands)
  else if contains operands "q" && mnemonic <> "ldr" then
    error ~source ~function_name ~obligation:"full-register operations"
      (Printf.sprintf "q-register form is only permitted for literal loads: %s %s"
         mnemonic operands)
  else if contains operands ".s[" && not (mnemonic = "dup" && valid_neon_dup operands) then
    error ~source ~function_name ~obligation:"no lane extraction"
      (Printf.sprintf "encountered %s %s" mnemonic operands)
  else if neon_scalar_register operands then
    error ~source ~function_name ~obligation:"no scalar floating arithmetic"
      (Printf.sprintf "encountered %s %s" mnemonic operands)
  else if
    contains operands ".2s" || contains operands ".2d" || contains operands ".8b"
    || contains operands ".8h" || contains operands ".4h"
  then
    error ~source ~function_name ~obligation:"one 128-bit vector per rack"
      (Printf.sprintf "encountered narrowed vector form in %s %s" mnemonic operands)
  else if not (allowed_neon mnemonic) then
    error ~source ~function_name ~obligation:"instruction allow-list"
      (Printf.sprintf "unexpected instruction %s%s" mnemonic
         (if operands = "" then "" else " " ^ operands))
  else Ok ()

let verify_instruction ~profile ~allow_cross_lane ~source ~function_name decoded =
  match profile with
  | Target.X86_avx2 ->
      verify_avx2_instruction ~allow_cross_lane ~source ~function_name decoded
  | Target.Aarch64_neon -> verify_neon_instruction ~source ~function_name decoded
  | profile ->
      error ~source ~function_name ~obligation:"target profile"
        (Printf.sprintf "profile '%s' has no object verifier"
           (Target.profile_name profile))

let verify_function ~profile ~allow_cross_lane ~source ~function_name instructions =
  let rec loop saw_ret fma_count = function
    | [] ->
        if not saw_ret then
          error ~source ~function_name ~obligation:"function return"
            "function contains no ret instruction"
        else Ok fma_count
    | decoded :: rest when saw_ret && is_alignment_padding decoded ->
        loop saw_ret fma_count rest
    | decoded :: _ when saw_ret ->
        error ~source ~function_name ~obligation:"terminal return"
          (Printf.sprintf "encountered %s after ret" decoded.mnemonic)
    | decoded :: rest -> (
        match verify_instruction ~profile ~allow_cross_lane ~source ~function_name decoded with
        | Error _ as result -> result
        | Ok () ->
            let saw_ret = saw_ret || decoded.mnemonic = "ret" || decoded.mnemonic = "retq" in
            loop saw_ret
              (fma_count + if is_fma profile decoded.mnemonic then 1 else 0)
              rest)
  in
  loop false 0 instructions

let verify ?(profile = Target.X86_avx2) ?expected_fma_count
    ?(cross_lane_functions = []) ~source ~functions object_bytes =
  let object_ = Filename.temp_file "rake-native-verify-" ".o" in
  let output = Filename.temp_file "rake-native-verify-" ".objdump" in
  let files = [ object_; output ] in
  Fun.protect
    ~finally:(fun () ->
      List.iter (fun path -> try Sys.remove path with Sys_error _ -> ()) files)
    (fun () ->
      try
        write_file object_ object_bytes;
        match disassemble ~profile ~source ~object_ ~output with
        | Error _ as result -> result
        | Ok text ->
            let decoded = decode_functions text in
            let rec verify_named fma_count = function
              | [] -> (
                  match expected_fma_count with
                  | None -> Ok ()
                  | Some expected when expected = fma_count -> Ok ()
                  | Some expected ->
                      error ~source ~obligation:"exact FMA count"
                        (Printf.sprintf "expected %d but found %d" expected
                           fma_count))
              | function_name :: rest -> (
                  match Hashtbl.find_opt decoded function_name with
                  | None ->
                      error ~source ~function_name
                        ~obligation:"named function presence"
                        "function was not present in the object disassembly"
                  | Some instructions -> (
                      match
                        verify_function ~profile
                          ~allow_cross_lane:(List.mem function_name cross_lane_functions)
                          ~source ~function_name instructions
                      with
                      | Error _ as result -> result
                      | Ok count -> verify_named (fma_count + count) rest))
            in
            verify_named 0 functions
      with Sys_error detail -> error ~source ~obligation:"object I/O" detail)
