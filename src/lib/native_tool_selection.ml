(** GNU ELF tools are target dependencies, not dependencies of the front end. An
    explicit override selects one executable, never a shell command. *)

let executable_exists program =
  let executable path =
    try
      Unix.access path [ Unix.X_OK ];
      (Unix.stat path).Unix.st_kind = Unix.S_REG
    with Unix.Unix_error _ -> false
  in
  if not (Filename.is_implicit program) then executable program
  else
    Option.value (Sys.getenv_opt "PATH") ~default:""
    |> String.split_on_char (if Sys.win32 then ';' else ':')
    |> List.exists (fun directory ->
        let path = Filename.concat directory program in
        executable path || (Sys.win32 && executable (path ^ ".exe")))

let select ~variable candidates =
  match Sys.getenv_opt variable with
  | Some program -> program
  | None -> (
      match List.find_opt executable_exists candidates with
      | Some program -> program
      | None -> List.hd candidates)

let assembler = function
  | Target.X86_sse2 | Target.X86_avx2 | Target.X86_avx512 ->
      ( select ~variable:"RAKE_X86_AS"
          [
            "x86_64-linux-gnu-as";
            "x86_64-unknown-linux-gnu-as";
            "x86_64-elf-as";
            "as";
          ],
        [ "--64" ] )
  | Target.Aarch64_neon ->
      ( select ~variable:"RAKE_AARCH64_AS"
          [
            "aarch64-linux-gnu-as";
            "aarch64-unknown-linux-gnu-as";
            "aarch64-none-linux-gnu-as";
            "aarch64-elf-as";
          ],
        [] )
  | profile ->
      invalid_arg ("no GNU ELF assembler for " ^ Target.profile_name profile)

let disassembler = function
  | Target.X86_sse2 | Target.X86_avx2 | Target.X86_avx512 ->
      ( select ~variable:"RAKE_X86_OBJDUMP"
          [
            "x86_64-linux-gnu-objdump";
            "x86_64-unknown-linux-gnu-objdump";
            "x86_64-elf-objdump";
            "objdump";
          ],
        [ "-d"; "-M"; "intel"; "--no-show-raw-insn" ] )
  | Target.Aarch64_neon ->
      ( select ~variable:"RAKE_AARCH64_OBJDUMP"
          [
            "aarch64-linux-gnu-objdump";
            "aarch64-unknown-linux-gnu-objdump";
            "aarch64-none-linux-gnu-objdump";
            "aarch64-elf-objdump";
          ],
        [ "-d"; "--no-show-raw-insn" ] )
  | profile ->
      invalid_arg ("no GNU ELF disassembler for " ^ Target.profile_name profile)

let requirement ~profile ~operation =
  let variable =
    match (profile, operation) with
    | (Target.X86_sse2 | Target.X86_avx2 | Target.X86_avx512), `Assemble ->
        "RAKE_X86_AS"
    | (Target.X86_sse2 | Target.X86_avx2 | Target.X86_avx512), `Disassemble ->
        "RAKE_X86_OBJDUMP"
    | Target.Aarch64_neon, `Assemble -> "RAKE_AARCH64_AS"
    | Target.Aarch64_neon, `Disassemble -> "RAKE_AARCH64_OBJDUMP"
    | _ -> invalid_arg "native tool requirement needs a physical profile"
  in
  Printf.sprintf
    "install GNU ELF binutils for %s or set %s to the matching executable"
    (Target.profile_name profile)
    variable
