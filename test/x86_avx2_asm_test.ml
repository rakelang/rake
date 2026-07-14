module A = Rake.X86_avx2_regalloc

let loc line =
  { Rake.Native_ir.file = "asm.rk"; line; col = 1; offset = line * 10 }

let instruction line operation =
  { A.operation; loc = loc line; provenance = Rake.Native_ir.source }

let function_ =
  {
    A.name = "rake_all_ops";
    loc = loc 1;
    instructions =
      [
        instruction 2 (A.Uniform_f32 { dst = 2; bits = Int32.zero });
        instruction 3 (A.Uniform_f32 { dst = 3; bits = Int32.bits_of_float 2.0 });
        instruction 4 (A.Uniform_f32 { dst = 4; bits = Int32.bits_of_float 2.0 });
        instruction 5 (A.Uniform_f32 { dst = 5; bits = Int32.min_int });
        instruction 6 (A.Addps { dst = 6; left = 0; right = 1 });
        instruction 7 (A.Subps { dst = 6; left = 6; right = 2 });
        instruction 8 (A.Mulps { dst = 6; left = 6; right = 3 });
        instruction 9 (A.Divps { dst = 6; left = 6; right = 4 });
        instruction 10 (A.Sqrtps { dst = 6; source = 6 });
        instruction 11 (A.Negps { dst = 7; source = 6 });
        instruction 12
          (A.Cmpps
             {
               dst = 8;
               predicate = Rake.X86_avx2_mir.Olt;
               left = 6;
               right = 7;
             });
        instruction 13
          (A.Blendvps { dst = 9; mask = 8; if_true = 6; if_false = 7 });
        instruction 14 (A.Mask_andps { dst = 10; left = 8; right = 9 });
        instruction 15 (A.Mask_orps { dst = 10; left = 10; right = 8 });
        instruction 16 (A.Mask_xorps { dst = 10; left = 10; right = 9 });
        instruction 17 (A.Mask_notps { dst = 11; source = 10 });
        instruction 18 (A.Moveaps { dst = 12; source = 9 });
        instruction 19 (A.Fma213ps { dst = 12; multiplier = 3; addend = 4 });
        instruction 20
          (A.Fma231ps { dst = 12; multiplicand = 3; multiplier = 4 });
        instruction 21 (A.Moveaps { dst = 0; source = 12 });
      ];
    result = Some 0;
    result_type = Some (Rake.Native_ir.Rack Rake.Native_ir.F32);
    maximum_live = 13;
  }

let reduction_function =
  {
    A.name = "strict_reduce_add";
    loc = loc 40;
    instructions =
      [ instruction 41
          (A.Reduce_f32
             { dst = 1; source = 0; operation = Rake.Native_ir.Reduce_add;
               scratch = [ 2 ] });
        instruction 42 (A.Moveaps { dst = 0; source = 1 }) ];
    result = Some 0;
    result_type = Some (Rake.Native_ir.Scalar Rake.Native_ir.F32);
    maximum_live = 3;
  }

let scan_function =
  {
    A.name = "strict_scan_add";
    loc = loc 50;
    instructions =
      [ instruction 51
          (A.Scan_f32
             { dst = 1; source = 0; operation = Rake.Native_ir.Scan_add;
               scratch = [ 2; 3 ] });
        instruction 52 (A.Moveaps { dst = 0; source = 1 }) ];
    result = Some 0;
    result_type = Some (Rake.Native_ir.Rack Rake.Native_ir.F32);
    maximum_live = 4;
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

let write_file path contents =
  let channel = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out_noerr channel) (fun () ->
      output_string channel contents)

let read_file path =
  let channel = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in_noerr channel) (fun () ->
      really_input_string channel (in_channel_length channel))

let objdump object_bytes =
  let object_ = Filename.temp_file "rake-asm-test-" ".o" in
  let output = Filename.temp_file "rake-asm-test-" ".txt" in
  Fun.protect
    ~finally:(fun () -> List.iter (fun path -> try Sys.remove path with Sys_error _ -> ()) [ object_; output ])
    (fun () ->
      write_file object_ object_bytes;
      let input = Unix.openfile "/dev/null" [ Unix.O_RDONLY ] 0 in
      let destination = Unix.openfile output [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600 in
      let status =
        Fun.protect
          ~finally:(fun () -> Unix.close input; Unix.close destination)
          (fun () ->
            let argv = [| "objdump"; "-d"; "-M"; "intel"; "--no-show-raw-insn"; object_ |] in
            let pid = Unix.create_process "objdump" argv input destination destination in
            snd (Unix.waitpid [] pid))
      in
      match status with Unix.WEXITED 0 -> read_file output | _ -> failwith "objdump failed")

let () =
  let assembly =
    match Rake.X86_avx2_asm.emit [ function_; reduction_function; scan_function ] with
    | Ok assembly -> assembly
    | Error error -> failwith (Rake.X86_avx2_asm.format_error error)
  in
  List.iter
    (fun line -> if not (contains assembly line) then failwith ("missing assembly: " ^ line))
    [
      ".intel_syntax noprefix";
      ".globl rake_all_ops";
      ".hidden rake_all_ops";
      ".type rake_all_ops, @function";
      "vxorps ymm2, ymm2, ymm2";
      "vblendvps ymm9, ymm7, ymm6, ymm8";
      "vcmpps ymm8, ymm6, ymm7, 0x11";
      "vfmadd213ps ymm12, ymm3, ymm4";
      "vfmadd231ps ymm12, ymm3, ymm4";
      ".section .note.GNU-stack,\"\",@progbits";
    ];
  if contains assembly "vzeroupper" then failwith "emitter destroyed a YMM return with vzeroupper";
  if count assembly ".long 0x40000000" <> 1 then
    failwith "identical uniform constants were not deduplicated";
  if count assembly ".long 0x80000000" <> 9 then
    failwith "negative-zero and sign-mask bit patterns were not preserved exactly";
  if count assembly "vaddps ymm1, ymm1, ymm2" <> 7
     || count assembly "vaddps ymm2, ymm2, ymm3" <> 7
  then failwith "strict reduction and scan must each use seven ordered add steps";
  List.iter
    (fun opcode -> if not (contains assembly opcode) then failwith ("missing cross-lane assembly: " ^ opcode))
    [ "vperm2f128"; "vpermilps"; "vblendps" ];
  List.iter
    (fun forbidden ->
      if contains assembly forbidden then failwith ("forbidden cross-lane assembly: " ^ forbidden))
    [ "vhaddps"; "call"; "rsp"; "rbp" ];
  let object_bytes =
    match Rake.Native_toolchain.assemble ~source:"asm-emitter-test" assembly with
    | Ok bytes -> bytes
    | Error error -> failwith (Rake.Native_toolchain.format_error error)
  in
  let disassembly = objdump object_bytes in
  List.iter
    (fun opcode -> if not (contains disassembly opcode) then failwith ("objdump missed " ^ opcode))
    [ "vaddps"; "vsubps"; "vmulps"; "vdivps"; "vsqrtps"; "vcmplt_oqps";
      "vblendvps"; "vandps"; "vorps"; "vxorps"; "vmovaps"; "vfmadd213ps";
      "vfmadd231ps"; "vbroadcastss" ];
  List.iter
    (fun forbidden ->
      if contains disassembly forbidden then failwith ("forbidden disassembly: " ^ forbidden))
    [ "call"; "rsp"; "rbp" ];
  let invalid = { function_ with instructions = [ instruction 30 (A.Moveaps { dst = 16; source = 0 }) ] } in
  (match Rake.X86_avx2_asm.emit [ invalid ] with
  | Error error when contains (Rake.X86_avx2_asm.format_error error) "invalid physical YMM register 16" -> ()
  | Error error -> failwith ("unexpected invalid-register error: " ^ Rake.X86_avx2_asm.format_error error)
  | Ok _ -> failwith "invalid physical register unexpectedly emitted");
  print_endline "x86 AVX2 Intel assembly emitter tests passed"
