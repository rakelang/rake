module A = Rake.Aarch64_neon_regalloc
module M = Rake.Aarch64_neon_mir

let loc line =
  { Rake.Native_ir.file = "neon-asm.rk"; line; col = 1; offset = line * 10 }

let instruction line operation =
  { A.operation; loc = loc line; provenance = Rake.Native_ir.source }

let function_ =
  {
    A.name = "rake_neon_all_ops";
    loc = loc 1;
    instructions =
      [ instruction 2 (A.Uniform_f32 { dst = 2; bits = Int32.zero });
        instruction 2 (A.Mask_const { dst = 21; value = true });
        instruction 2 (A.Broadcast_f32 { dst = 22; source = 3 });
        instruction 3
          (A.Uniform_f32 { dst = 3; bits = Int32.bits_of_float 2.0 });
        instruction 4
          (A.Uniform_f32 { dst = 4; bits = Int32.bits_of_float 2.0 });
        instruction 5 (A.Uniform_f32 { dst = 5; bits = Int32.min_int });
        instruction 6 (A.Fadd { dst = 6; left = 0; right = 1 });
        instruction 7 (A.Fsub { dst = 6; left = 6; right = 2 });
        instruction 8 (A.Fmul { dst = 6; left = 6; right = 3 });
        instruction 9 (A.Fdiv { dst = 6; left = 6; right = 4 });
        instruction 10 (A.Fsqrt { dst = 6; source = 6 });
        instruction 11 (A.Eor { dst = 7; left = 6; right = 5 });
        instruction 12
          (A.Compare { dst = 16; predicate = M.Cgt; left = 6; right = 7 });
        instruction 13 (A.And { dst = 17; left = 16; right = 16 });
        instruction 14 (A.Orr { dst = 17; left = 17; right = 16 });
        instruction 15 (A.Eor { dst = 17; left = 17; right = 16 });
        instruction 16 (A.Mvn { dst = 18; source = 17 });
        instruction 17
          (A.Bsl { dst_mask = 18; if_true = 6; if_false = 7 });
        instruction 18
          (A.Bit { dst_false = 19; if_true = 6; mask = 16 });
        instruction 19
          (A.Bif { dst_true = 20; if_false = 7; mask = 16 });
        instruction 20
          (A.Fmla { dst = 20; multiplicand = 3; multiplier = 4 });
        instruction 21 (A.Move { dst = 0; source = 20 }) ];
    result = Some 0;
    maximum_live = 13;
  }

let contains text needle =
  let pattern = Str.regexp_string needle in
  try
    ignore (Str.search_forward pattern text 0);
    true
  with Not_found -> false

let count text needle =
  let pattern = Str.regexp_string needle in
  let rec loop position total =
    try loop (Str.search_forward pattern text position + String.length needle) (total + 1)
    with Not_found -> total
  in
  loop 0 0

let () =
  let assembly =
    match Rake.Aarch64_neon_asm.emit [ function_ ] with
    | Ok assembly -> assembly
    | Error error -> failwith (Rake.Aarch64_neon_asm.format_error error)
  in
  List.iter
    (fun line ->
      if not (contains assembly line) then failwith ("missing assembly: " ^ line))
    [ ".arch armv8-a+simd";
      ".globl rake_neon_all_ops";
      ".hidden rake_neon_all_ops";
      ".type rake_neon_all_ops, %function";
      "movi v2.4s, #0";
      "movi v21.16b, #0xff";
      "dup v22.4s, v3.s[0]";
      "fadd v6.4s, v0.4s, v1.4s";
      "fsqrt v6.4s, v6.4s";
      "eor v7.16b, v6.16b, v5.16b";
      "fcmgt v16.4s, v6.4s, v7.4s";
      "bsl v18.16b, v6.16b, v7.16b";
      "bit v19.16b, v6.16b, v16.16b";
      "bif v20.16b, v7.16b, v16.16b";
      "fmla v20.4s, v3.4s, v4.4s";
      "mov v0.16b, v20.16b";
      ".section .note.GNU-stack,\"\",%progbits" ];
  if count assembly ".long 0x40000000" <> 4 then
    failwith "identical uniform constants were not deduplicated into one 128-bit rack";
  if count assembly ".long 0x80000000" <> 4 then
    failwith "sign-bit rack constant was not preserved exactly";
  if count assembly "fmla " <> 1 then failwith "explicit FMA did not emit exactly one FMLA";
  List.iter
    (fun forbidden ->
      if contains assembly forbidden then failwith ("forbidden assembly: " ^ forbidden))
    [ " v8."; " v9."; " v10."; " v11."; " v12."; " v13."; " v14.";
      " v15."; " sp"; " bl " ];
  let invalid =
    {
      function_ with
      instructions = [ instruction 30 (A.Move { dst = 8; source = 0 }) ];
    }
  in
  (match Rake.Aarch64_neon_asm.emit [ invalid ] with
  | Error error
    when contains (Rake.Aarch64_neon_asm.format_error error)
           "invalid physical vector register v8" -> ()
  | Error error ->
      failwith
        ("unexpected invalid-register error: "
        ^ Rake.Aarch64_neon_asm.format_error error)
  | Ok _ -> failwith "callee-saved vector register unexpectedly emitted");
  print_endline "AArch64 NEON GNU assembly emitter tests passed"
