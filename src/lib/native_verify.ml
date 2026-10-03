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
  | Target.X86_sse2 | Target.X86_avx2 | Target.X86_avx512 ->
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

(** An embedded native traversal has a compiler-selected control/memory
    template as well as register instructions. Compare its complete ELF
    function extent against the separately assembled selection, including
    literal bytes. Require a relocation-free extent, so a helper or external
    constant cannot silently change the verified instruction/data graph.
    Pure register functions retain the independent instruction allow-lists. *)
let fixed_native_functions ~profile ~source ~functions ~expected object_bytes =
  let malformed detail = invalid_arg detail in
  let slice bytes offset count =
    if offset < 0 || count < 0 || offset > String.length bytes - count then
      malformed "truncated ELF extent";
    String.sub bytes offset count in
  let number bytes offset count =
    ignore (slice bytes offset count);
    let value = ref 0L in
    for i = 0 to count - 1 do
      value := Int64.logor !value (Int64.shift_left (Int64.of_int (Char.code bytes.[offset + i])) (i * 8))
    done;
    if !value < 0L || !value > Int64.of_int max_int then malformed "ELF extent exceeds host bounds";
    Int64.to_int !value in
  let extract bytes =
    let machine = match profile with
      | Target.X86_sse2 | Target.X86_avx2 | Target.X86_avx512 -> 62
      | Target.Aarch64_neon -> 183
      | _ -> malformed "selected traversal verification requires a physical CPU profile" in
    if slice bytes 0 6 <> "\x7fELF\x02\x01" || number bytes 16 2 <> 1 || number bytes 18 2 <> machine then
      malformed (Printf.sprintf "requires a little-endian relocatable ELF object for %s" (Target.profile_name profile));
    let start = number bytes 40 8 and width = number bytes 58 2 and count = number bytes 60 2 in
    if width <> 64 || count = 0 then malformed "unsupported ELF section table";
    let section index =
      if index < 0 || index >= count then malformed "invalid ELF section index";
      start + index * width in
    ignore (slice bytes start (width * count));
    let field index offset n = number bytes (section index + offset) n in
    let contents index = slice bytes (field index 24 8) (field index 32 8) in
    let cstring strings offset =
      if offset < 0 || offset >= String.length strings then malformed "invalid ELF symbol string";
      let finish = try String.index_from strings offset '\000' with Not_found -> malformed "unterminated ELF symbol" in
      String.sub strings offset (finish - offset) in
    let answer = Hashtbl.create 8 in
    for index = 0 to count - 1 do
      if field index 4 4 = 2 then (
        let symbols = contents index and strings = contents (field index 40 4) in
        if field index 56 8 <> 24 || String.length symbols mod 24 <> 0 then malformed "invalid ELF symbol table";
        for entry = 0 to String.length symbols / 24 - 1 do
          let pos = entry * 24 in
          let name = cstring strings (number symbols pos 4) in
          if List.mem name functions then (
            if Hashtbl.mem answer name then malformed "duplicate selected function symbol";
            if Char.code symbols.[pos + 4] land 15 <> 2 then malformed "selected symbol is not a function";
            let target = number symbols (pos + 6) 2 in
            if field target 8 8 land 4 = 0 then malformed "selected function is not executable";
            let offset = number symbols (pos + 8) 8 and size = number symbols (pos + 16) 8 in
            if size = 0 then malformed "empty selected function extent";
            let code = slice (contents target) offset size in
            for relocation = 0 to count - 1 do
              if List.mem (field relocation 4 4) [ 4; 9 ] && field relocation 44 4 = target then (
                let entries = contents relocation and stride = field relocation 56 8 in
                if stride < 8 || String.length entries mod stride <> 0 then malformed "invalid relocation table";
                for slot = 0 to String.length entries / stride - 1 do
                  let address = number entries (slot * stride) 8 in
                  if address >= offset && address < offset + size then
                    malformed "selected traversal contains an unresolved relocation"
                done)
            done;
            Hashtbl.add answer name code)
        done)
    done;
    answer in
  try
    let wanted = extract expected and actual = extract object_bytes in
    let rec check = function
      | [] -> Ok ()
      | name :: rest ->
          (match Hashtbl.find_opt wanted name, Hashtbl.find_opt actual name with
          | Some a, Some b when a = b -> check rest
          | Some _, Some _ -> error ~source ~function_name:name ~obligation:"exact traversal selection"
              "final loop, memory, register or literal bytes differ from Rake's selection"
          | _ -> error ~source ~function_name:name ~obligation:"selected traversal presence" "function extent is absent") in
    check functions
  with Invalid_argument detail -> error ~source ~obligation:"closed traversal artifact" detail

let allowed_avx2 = function
  | "vbroadcastss" | "vxorps" | "vaddps" | "vsubps" | "vmulps"
  | "vdivps" | "vsqrtps" | "vfmadd213ps" | "vfmadd231ps" | "vcmpps"
  | "vcmpeq_oqps" | "vcmpneq_oqps" | "vcmplt_oqps" | "vcmple_oqps"
  | "vcmpeqps" | "vcmpneqps" | "vcmpltps" | "vcmpleps"
  | "vcmpunordps"
  | "vblendvps" | "vandps" | "vorps" | "vmovaps" | "ret" | "retq" ->
      true
  | "vperm2f128" | "vpermilps" | "vpermps" | "vblendps" | "vroundps" -> true
  | "vpxor" | "vpcmpeqd" -> true
  | _ -> false

let is_fma profile =
  match profile with
  | Target.X86_avx2 | Target.X86_avx512 -> (function "vfmadd213ps" | "vfmadd231ps" -> true | _ -> false)
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
  (* 66 90, the two-byte nop, disassembles as xchg ax,ax. *)
  | "xchg" -> String.trim decoded.operands = "ax,ax"
  | "cs" | "data16" -> contains decoded.operands "nop"
  | _ -> false

let cross_lane_mnemonic = function
  | "vperm2f128" | "vpermilps" | "vpermps" | "vblendps" -> true
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
         ((mnemonic = "vbroadcastss" || mnemonic = "vxorps" || mnemonic = "vandps"
           || (mnemonic = "vmovaps" && allow_cross_lane))
         && contains operands "rip"
         && not (contains (List.hd (String.split_on_char ',' operands)) "["))
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
      (Printf.sprintf "encountered %s outside a source-authorized cross-lane operation" mnemonic)
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

let allowed_sse2 = function
  | "movaps" | "xorps" | "andps" | "orps" | "pxor" | "pcmpeqd"
  | "addps" | "subps" | "mulps" | "divps" | "sqrtps" | "shufps"
  | "cvtps2dq" | "cvttps2dq" | "cvtdq2ps"
  | "cmpps" | "cmpeqps" | "cmpneqps" | "cmpltps" | "cmpleps"
  | "cmpunordps" | "cmpordps" | "ret" | "retq" -> true
  | _ -> false

let allowed_avx512f = function
  | "vbroadcastss" | "vpxord" | "vpandd" | "vpord" | "vpternlogd"
  | "vaddps" | "vsubps" | "vmulps" | "vdivps" | "vsqrtps"
  | "vrndscaleps"
  | "vfmadd213ps" | "vfmadd231ps" | "vcmpps" | "vcmpeq_oqps"
  | "vcmpneq_oqps" | "vcmplt_oqps" | "vcmple_oqps" | "vcmpeqps"
  | "vcmpunordps" | "vptestmd" | "vblendmps" | "vmovaps"
  | "vshuff32x4" | "vpermilps" | "vpermps" | "kxnorw" | "kshiftlw" | "kshiftrw"
  | "ret" | "retq" -> true
  | _ -> false

let verify_extended_x86_instruction ~profile ~allow_cross_lane ~source ~function_name decoded =
  let mnemonic = decoded.mnemonic and operands = decoded.operands in
  let sse = profile = Target.X86_sse2 in
  let fail obligation =
    error ~source ~function_name ~obligation (Printf.sprintf "encountered %s %s" mnemonic operands)
  in
  let literal_read =
    contains operands "rip"
    && not (contains (List.hd (String.split_on_char ',' operands)) "[")
    && (if sse then List.mem mnemonic [ "movaps"; "xorps"; "andps" ]
        else List.mem mnemonic [ "vbroadcastss"; "vpxord"; "vpandd" ]
          || (mnemonic = "vmovaps" && allow_cross_lane))
  in
  let cross_lane =
    if sse then mnemonic = "shufps" && not (String.ends_with ~suffix:",0x0" operands)
    else List.mem mnemonic [ "vshuff32x4"; "vpermilps"; "vpermps"; "kxnorw"; "kshiftlw"; "kshiftrw" ]
  in
  if String.starts_with ~prefix:"call" mnemonic then fail "no calls"
  else if contains operands "rsp" || contains operands "rbp" then fail "no stack use"
  else if contains operands "[" && not literal_read then fail "literal rack loads only"
  else if sse && (contains operands "ymm" || contains operands "zmm") then fail "one XMM per rack"
  else if not sse && (contains operands "ymm" || (contains operands "xmm" && mnemonic <> "vbroadcastss")) then fail "one ZMM per rack"
  else if not sse && regexp_contains "\\bk\\(0\\|[2-7]\\)\\b" operands then fail "reserved opmask register"
  else if cross_lane && not allow_cross_lane then fail "source-authorized cross-lane operation"
  else if not ((if sse then allowed_sse2 else allowed_avx512f) mnemonic) then fail "instruction allow-list"
  else Ok ()

let allowed_neon = function
  | "movi" | "ldr" | "dup" | "fadd" | "fsub" | "fmul" | "fdiv" | "fmin" | "fmax"
  | "fsqrt" | "fmla" | "fcmeq" | "fcmgt" | "fcmge" | "and" | "orr"
  | "frintm" | "frintp" | "frintz" | "frintn"
  | "eor" | "mvn" | "bsl" | "bit" | "bif" | "mov" | "ext" | "ret" -> true
  | _ -> false

let neon_callee_saved_vector operands =
  regexp_contains "\\bv\\(8\\|9\\|1[0-5]\\)\\." operands
  || regexp_contains "\\bq\\(8\\|9\\|1[0-5]\\)\\b" operands

let neon_scalar_register operands =
  regexp_contains "\\(^\\|[, \\t]+\\)[sd][0-9]+\\b" operands

let neon_general_register operands =
  regexp_contains "\\(^\\|[, \\t]+\\)[xw][0-9]+\\b" operands

let valid_neon_dup ~allow_cross_lane operands =
  regexp_contains
    ("^v\\([0-9]+\\)\\.4s,[ \\t]*v\\([0-9]+\\)\\.s\\["
     ^ (if allow_cross_lane then "[0-3]" else "0") ^ "\\]$")
    operands

let valid_neon_insert operands =
  regexp_contains "^v[0-9]+\\.s\\[[0-3]\\],[ \\t]*v[0-9]+\\.s\\[0\\]$" operands

let valid_neon_literal_load operands =
  regexp_contains "^q[0-9]+,[ \\t]*[0-9a-f]+[ \\t]*<[^>]+>$" operands

let valid_neon_mask_fold operands =
  regexp_contains
    "^v[0-9]+\\.16b,[ \\t]*\\(v[0-9]+\\.16b\\),[ \\t]*\\1,[ \\t]*#\\(4\\|8\\|0x4\\|0x8\\)$"
    operands

let verify_neon_instruction ~allow_cross_lane ~source ~function_name decoded =
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
  else if mnemonic = "ext" && not (allow_cross_lane && valid_neon_mask_fold operands) then
    error ~source ~function_name ~obligation:"source-authorized mask fold"
      (Printf.sprintf "encountered %s %s" mnemonic operands)
  else if mnemonic = "ldr" && not (valid_neon_literal_load operands) then
    error ~source ~function_name ~obligation:"literal rack loads only"
      (Printf.sprintf "encountered %s %s" mnemonic operands)
  else if contains operands "q" && mnemonic <> "ldr" then
    error ~source ~function_name ~obligation:"full-register operations"
      (Printf.sprintf "q-register form is only permitted for literal loads: %s %s"
         mnemonic operands)
  else if contains operands ".s[" && not (
    (mnemonic = "dup" && valid_neon_dup ~allow_cross_lane operands)
    || (mnemonic = "mov" && allow_cross_lane && valid_neon_insert operands)) then
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
  | (Target.X86_sse2 | Target.X86_avx512) as profile ->
      verify_extended_x86_instruction ~profile ~allow_cross_lane ~source ~function_name decoded
  | Target.Aarch64_neon -> verify_neon_instruction ~allow_cross_lane ~source ~function_name decoded
  | profile ->
      error ~source ~function_name ~obligation:"target profile"
        (Printf.sprintf "profile '%s' has no object verifier"
           (Target.profile_name profile))

let valid_integer_result_transfer profile decoded =
  let operands = Str.global_replace (Str.regexp "[ \\t]+") "" decoded.operands in
  match profile with
  | Target.X86_sse2 -> decoded.mnemonic = "movd" && operands = "eax,xmm0"
  | Target.X86_avx2 | Target.X86_avx512 -> decoded.mnemonic = "vmovd" && operands = "eax,xmm0"
  | Target.Aarch64_neon -> List.mem decoded.mnemonic [ "mov"; "umov" ] && operands = "w0,v0.s[0]"
  | _ -> false

let verify_function ~profile ~allow_cross_lane ~integer_result ~source ~function_name instructions =
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
    | decoded :: { mnemonic = ("ret" | "retq"); operands = "" } :: rest when integer_result ->
        if valid_integer_result_transfer profile decoded then loop true fma_count rest
        else error ~source ~function_name ~obligation:"integer result boundary"
          "expected the low 32 bits of vector register 0 in the C integer return register immediately before ret"
    | { mnemonic = ("ret" | "retq"); _ } :: _ when integer_result ->
        error ~source ~function_name ~obligation:"integer result boundary"
          "missing the terminal vector-to-integer result transfer"
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
    ?(cross_lane_functions = []) ?(integer_result_functions = []) ~source ~functions object_bytes =
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
                          ~integer_result:(List.mem function_name integer_result_functions)
                          ~source ~function_name instructions
                      with
                      | Error _ as result -> result
                      | Ok count -> verify_named (fma_count + count) rest))
            in
            verify_named 0 functions
      with Sys_error detail -> error ~source ~obligation:"object I/O" detail)
