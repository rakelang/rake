(** Whole-program native code-generation target configuration.

    A rack has the fixed lane count and physical register class of its selected
    profile.  Profiles describe Rake's own backend contracts; they are not
    command-line settings for an external code generator. *)

type t = Cpu

type profile =
  | Scalar
  | X86_sse2
  | X86_avx2
  | X86_avx512
  | Aarch64_neon

type selection = Native | Explicit of profile

type profile_info = {
  profile : profile;
  id : string;
  register_bits : int option;
  f32_lanes : int;
  mir_register_class : string option;
  description : string;
}

type config = {
  target : t;
  profile : profile;
  width : int;
}

let info = function
  | Scalar ->
      {
        profile = Scalar;
        id = "scalar";
        register_bits = None;
        f32_lanes = 1;
        mir_register_class = None;
        description = "planned scalar CPU fallback (not a SIMD-register profile)";
      }
  | X86_sse2 ->
      {
        profile = X86_sse2;
        id = "x86-sse2";
        register_bits = Some 128;
        f32_lanes = 4;
        mir_register_class = Some "xmm";
        description = "planned x86-64 SSE2, one 128-bit XMM rack";
      }
  | X86_avx2 ->
      {
        profile = X86_avx2;
        id = "x86-avx2";
        register_bits = Some 256;
        f32_lanes = 8;
        mir_register_class = Some "ymm";
        description = "x86-64 AVX2+FMA, one 256-bit YMM rack";
      }
  | X86_avx512 ->
      {
        profile = X86_avx512;
        id = "x86-avx512";
        register_bits = Some 512;
        f32_lanes = 16;
        mir_register_class = Some "zmm";
        description = "planned x86-64 AVX-512F, one 512-bit ZMM rack";
      }
  | Aarch64_neon ->
      {
        profile = Aarch64_neon;
        id = "aarch64-neon";
        register_bits = Some 128;
        f32_lanes = 4;
        mir_register_class = Some "v";
        description = "AArch64 NEON/AAPCS64, one 128-bit vector rack";
      }

let profiles = [ Scalar; X86_sse2; X86_avx2; X86_avx512; Aarch64_neon ]
let profile_name profile = (info profile).id
let name Cpu = "cpu"

let profile_list () =
  profiles
  |> List.map (fun profile ->
         let p = info profile in
         Printf.sprintf "%-16s %s" p.id p.description)
  |> String.concat "\n"

let selection_of_string = function
  | "native" -> Ok Native
  | value -> (
      match List.find_opt (fun profile -> profile_name profile = value) profiles with
      | Some profile -> Ok (Explicit profile)
      | None ->
          Error
            (Printf.sprintf "unknown target profile '%s' (expected native, %s)"
               value
               (profiles |> List.map profile_name |> String.concat ", ")))

let cpuinfo_tokens () =
  try
    let channel = open_in "/proc/cpuinfo" in
    Fun.protect ~finally:(fun () -> close_in_noerr channel) (fun () ->
        let tokens = ref [] in
        (try
           while true do
             let line = input_line channel |> String.lowercase_ascii in
             match String.index_opt line ':' with
             | None -> ()
             | Some separator ->
                 let key = String.sub line 0 separator |> String.trim in
                 if key = "flags" || key = "features" then
                   let values =
                     String.sub line (separator + 1)
                       (String.length line - separator - 1)
                     |> String.split_on_char ' '
                     |> List.filter (fun value -> value <> "")
                   in
                   tokens := values @ !tokens
           done
         with End_of_file -> ());
        !tokens)
  with Sys_error _ -> []

let resolve_native () =
  let tokens = cpuinfo_tokens () in
  let has feature = List.mem feature tokens in
  (* Native selects the strongest backend that this compiler can actually
     emit, not the strongest instruction set merely present in the host. *)
  if has "avx2" && has "fma" then Ok X86_avx2
  else if has "asimd" then Ok Aarch64_neon
  else
    Error
      "this host provides neither AVX2+FMA nor AArch64 Advanced SIMD, the production backends in this compiler build; select an explicit profile for deterministic cross-compilation"

let resolve = function Native -> resolve_native () | Explicit profile -> Ok profile

let validate ({ profile; width; _ } as config) =
  let profile = info profile in
  if width <> profile.f32_lanes then
    let physical =
      match profile.register_bits with
      | Some bits -> Printf.sprintf "one %d-bit native register" bits
      | None -> "its fixed scalar execution width"
    in
    Error
      (Printf.sprintf
         "target profile '%s' maps a float rack to %s = %d f32 lane%s; --width %d is incompatible"
         profile.id physical profile.f32_lanes
         (if profile.f32_lanes = 1 then "" else "s") width)
  else Ok config

let make ?width ?(selection = Native) target =
  match resolve selection with
  | Error _ as error -> error
  | Ok profile ->
      let profile_info = info profile in
      let width = Option.value width ~default:profile_info.f32_lanes in
      validate { target; profile; width }

let make_exn ?width ?selection target =
  match make ?width ?selection target with
  | Ok config -> config
  | Error message -> invalid_arg message
