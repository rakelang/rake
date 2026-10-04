let assemble ?(profile = Rake.Target.X86_avx2) ~source assembly =
  match Rake.Native_toolchain.assemble ~profile ~source assembly with
  | Ok bytes -> bytes
  | Error error -> failwith (Rake.Native_toolchain.format_error error)

let expect_ok = function
  | Ok () -> ()
  | Error error -> failwith (Rake.Native_verify.format_error error)

let expect_obligation obligation = function
  | Ok () -> failwith ("verification unexpectedly satisfied " ^ obligation)
  | Error error when error.Rake.Native_verify.obligation = obligation -> ()
  | Error error ->
      failwith
        (Printf.sprintf "expected obligation %S, got: %s" obligation
           (Rake.Native_verify.format_error error))

let check_integer_argument_boundaries () =
  List.iter (fun (profile, prefix, transfer, wrong, vector_work) ->
    let source = "integer-argument-boundary" in
    let fixture body = prefix ^ "\n.text\n.globl integer_entry\ninteger_entry:\n" ^ body ^ "\n    ret\n" in
    let authorized = [ "integer_entry", [ { Rake.Native_register_assignment.argument = 0; register = 1 } ] ] in
    let check ?(integer_argument_transfers = authorized) body =
      Rake.Native_verify.verify ~profile ~source ~functions:[ "integer_entry" ]
        ~integer_argument_transfers (assemble ~profile ~source (fixture body)) in
    expect_ok (check (transfer ^ "\n" ^ vector_work));
    expect_obligation "integer argument boundary" (check (wrong ^ "\n" ^ vector_work));
    expect_obligation "integer argument boundary" (check (vector_work ^ "\n" ^ transfer));
    List.iter (fun body -> match check body with
      | Error _ -> () | Ok () -> failwith "an undeclared integer import passed object verification")
      [ transfer ^ "\n" ^ transfer ^ "\n" ^ vector_work ];
    (match check ~integer_argument_transfers:[] (transfer ^ "\n" ^ vector_work) with
     | Error _ -> () | Ok () -> failwith "integer imports require boundary authorization"))
    [ Rake.Target.X86_sse2, ".intel_syntax noprefix", "    movd xmm1, edi", "    movd xmm1, esi", "    addps xmm0, xmm0";
      Rake.Target.X86_avx2, ".intel_syntax noprefix", "    vmovd xmm1, edi", "    vmovd xmm1, esi", "    vaddps ymm0, ymm0, ymm0";
      Rake.Target.X86_avx512, ".intel_syntax noprefix", "    vmovd xmm1, edi", "    vmovd xmm1, esi", "    vaddps zmm0, zmm0, zmm0";
      Rake.Target.Aarch64_neon, ".arch armv8-a+simd", "    fmov s1, w0", "    fmov s1, w1", "    fadd v0.4s, v0.4s, v0.4s" ]

let check_conversion_instruction_boundaries () =
  List.iter (fun (profile, prefix, full, wrong) ->
    let source = "conversion-instruction-boundary" in
    let check body =
      let assembly = prefix ^ "\n.text\n.globl converted\nconverted:\n" ^ body ^ "\n    ret\n" in
      Rake.Native_verify.verify ~profile ~source ~functions:[ "converted" ]
        (assemble ~profile ~source assembly) in
    expect_ok (check full);
    match check wrong with
    | Error _ -> ()
    | Ok () -> failwith "a scalar or narrowed conversion passed rack verification")
    [ Rake.Target.X86_sse2, ".intel_syntax noprefix",
        "    cvtdq2ps xmm0, xmm0", "    cvtsi2ss xmm0, eax";
      Rake.Target.X86_avx2, ".intel_syntax noprefix",
        "    vcvtdq2ps ymm0, ymm0", "    vcvtdq2ps xmm0, xmm0";
      Rake.Target.X86_avx512, ".intel_syntax noprefix",
        "    vcvtdq2ps zmm0, zmm0\n    vcvtudq2ps zmm0, zmm0", "    vcvtudq2ps ymm0, ymm0";
      Rake.Target.X86_avx512, ".intel_syntax noprefix",
        "    vcvtps2udq zmm0, zmm0", "    vcvtps2udq ymm0, ymm0";
      Rake.Target.Aarch64_neon, ".arch armv8-a+simd",
        "    scvtf v0.4s, v0.4s\n    ucvtf v0.4s, v0.4s\n    fcvtns v0.4s, v0.4s",
        "    ucvtf v0.2s, v0.2s";
      Rake.Target.Aarch64_neon, ".arch armv8-a+simd",
        "    fcvtnu v0.4s, v0.4s", "    fcvtnu v0.2s, v0.2s" ]

let check_uniform_shift_sequences () =
  List.iter (fun (profile, prefix, sequence, bare, wrong_count, narrowed) ->
    let source = "uniform-shift-sequence" in
    let check ?(authorized = true) body =
      let assembly = prefix ^ "\n.text\n.globl shifted\nshifted:\n" ^ body ^ "\n    ret\n" in
      Rake.Native_verify.verify ~profile ~source ~functions:["shifted"]
        ~uniform_shift_counts:(if authorized then ["shifted", 1] else [])
        (assemble ~profile ~source assembly) in
    expect_ok (check sequence);
    expect_obligation "uniform shift selection" (check ~authorized:false sequence);
    List.iter (fun body -> match check body with
      | Error _ -> ()
      | Ok () -> failwith "an unnormalized or narrowed runtime shift passed object verification")
      [bare; wrong_count; narrowed];
    expect_obligation "uniform shift selection" (check ""))
    [ Rake.Target.X86_sse2, ".intel_syntax noprefix",
        "    movaps xmm2, xmm1\n    psllq xmm2, 59\n    psrlq xmm2, 59\n    pslld xmm0, xmm2",
        "    pslld xmm0, xmm1",
        "    psllq xmm2, 58\n    psrlq xmm2, 58\n    pslld xmm0, xmm2",
        "    psllq xmm2, 59\n    psrlq xmm2, 59\n    pslld xmm0, xmm3";
      Rake.Target.X86_avx2, ".intel_syntax noprefix",
        "    vpsllq ymm2, ymm1, 59\n    vpsrlq ymm2, ymm2, 59\n    vpsrld ymm0, ymm0, xmm2",
        "    vpsrld ymm0, ymm0, xmm1",
        "    vpsllq ymm2, ymm1, 58\n    vpsrlq ymm2, ymm2, 58\n    vpsrld ymm0, ymm0, xmm2",
        "    vpsllq ymm2, ymm1, 59\n    vpsrlq ymm2, ymm2, 59\n    vpsrld xmm0, xmm0, xmm2";
      Rake.Target.X86_avx512, ".intel_syntax noprefix",
        "    vpsllq zmm2, zmm1, 59\n    vpsrlq zmm2, zmm2, 59\n    vpsrad zmm0, zmm0, xmm2",
        "    vpsrad zmm0, zmm0, xmm1",
        "    vpsllq zmm2, zmm1, 58\n    vpsrlq zmm2, zmm2, 58\n    vpsrad zmm0, zmm0, xmm2",
        "    vpsllq zmm2, zmm1, 59\n    vpsrlq zmm2, zmm2, 59\n    vpsrad ymm0, ymm0, xmm2";
      Rake.Target.Aarch64_neon, ".arch armv8-a+simd",
        "    dup v2.4s, v1.s[0]\n    shl v2.4s, v2.4s, #27\n    ushr v2.4s, v2.4s, #27\n    neg v2.4s, v2.4s\n    sshl v0.4s, v0.4s, v2.4s",
        "    sshl v0.4s, v0.4s, v1.4s",
        "    dup v2.4s, v1.s[0]\n    shl v2.4s, v2.4s, #26\n    ushr v2.4s, v2.4s, #26\n    neg v2.4s, v2.4s\n    sshl v0.4s, v0.4s, v2.4s",
        "    dup v2.4s, v1.s[0]\n    shl v2.4s, v2.4s, #27\n    ushr v2.4s, v2.4s, #27\n    neg v2.4s, v2.4s\n    sshl v0.2s, v0.2s, v2.2s" ]

let valid =
  {|
.intel_syntax noprefix
.text
.globl verified_kernel
.type verified_kernel, @function
verified_kernel:
    vaddps ymm0, ymm0, ymm1
    vcmpps ymm4, ymm0, ymm1, 0x11
    vfmadd213ps ymm0, ymm2, ymm3
    ret
.size verified_kernel, .-verified_kernel
.p2align 4
.globl verified_mul
.type verified_mul, @function
verified_mul:
    vmulps ymm0, ymm0, ymm1
    ret
.size verified_mul, .-verified_mul
.p2align 4
.globl verified_identity
.type verified_identity, @function
verified_identity:
    ret
.size verified_identity, .-verified_identity
.section .note.GNU-stack,"",@progbits
|}

let stack =
  {|
.intel_syntax noprefix
.text
.globl stack_kernel
.type stack_kernel, @function
stack_kernel:
    vmovaps YMMWORD PTR [rsp - 32], ymm0
    ret
.size stack_kernel, .-stack_kernel
.section .note.GNU-stack,"",@progbits
|}

let call =
  {|
.intel_syntax noprefix
.text
.globl call_kernel
.type call_kernel, @function
call_kernel:
    vaddps ymm0, ymm0, ymm1
    call external_function
    ret
.size call_kernel, .-call_kernel
.section .note.GNU-stack,"",@progbits
|}

let cross_lane =
  {|
.intel_syntax noprefix
.text
.globl strict_scan
.type strict_scan, @function
strict_scan:
    vperm2f128 ymm2, ymm0, ymm0, 0x00
    vpermilps ymm2, ymm2, 0x00
    vblendps ymm0, ymm0, ymm2, 0x02
    ret
.size strict_scan, .-strict_scan
.section .note.GNU-stack,"",@progbits
|}

let neon_valid =
  {|
.arch armv8-a+simd
.text
.globl neon_verified
.type neon_verified, %function
neon_verified:
    fadd v3.4s, v0.4s, v1.4s
    fcmeq v4.4s, v3.4s, v2.4s
    bsl v4.16b, v3.16b, v2.16b
    fmla v4.4s, v0.4s, v1.4s
    mov v0.16b, v4.16b
    ret
.size neon_verified, .-neon_verified
.section .note.GNU-stack,"",%progbits
|}

let neon_callee_saved =
  {|
.arch armv8-a+simd
.text
.globl neon_bad_register
.type neon_bad_register, %function
neon_bad_register:
    fadd v8.4s, v0.4s, v1.4s
    mov v0.16b, v8.16b
    ret
.size neon_bad_register, .-neon_bad_register
.section .note.GNU-stack,"",%progbits
|}

let neon_scalar =
  {|
.arch armv8-a+simd
.text
.globl neon_scalar
.type neon_scalar, %function
neon_scalar:
    fadd s0, s0, s1
    ret
.size neon_scalar, .-neon_scalar
.section .note.GNU-stack,"",%progbits
|}

let check_selected_traversal ~profile ~traversal ~mutations ~kernel ~helper =
  let expected = assemble ~profile ~source:"traversal-selection" traversal in
  let check actual = Rake.Native_verify.fixed_native_functions ~profile ~source:"traversal-selection"
    ~functions:[ "exact_stream" ] ~expected actual in
  expect_ok (check expected);
  List.iter (fun (before, after) ->
    let changed = Str.global_replace (Str.regexp_string before) after traversal in
    expect_obligation "exact traversal selection"
      (check (assemble ~profile ~source:"mutated-traversal" changed))) mutations;
  let opaque = Str.global_replace (Str.regexp_string kernel) helper traversal in
  expect_obligation "closed traversal artifact"
    (check (assemble ~profile ~source:"opaque-traversal" opaque))

let () =
  (* Independent machine objects check the verifier's newly admitted integer
     forms. Narrow vectors and integer memory work stay outside rack kernels. *)
  List.iter (fun (profile, vector_add, vector_compare, narrowed, memory, obligation) ->
    let source = "integer-verifier-fixture" in
    let check instruction =
      let assembly = Printf.sprintf {|
.intel_syntax noprefix
.text
.globl integer_kernel
.type integer_kernel, @function
integer_kernel:
    %s
    ret
.size integer_kernel, .-integer_kernel
.section .note.GNU-stack,"",@progbits
|} instruction in
      Rake.Native_verify.verify ~profile ~source ~functions:[ "integer_kernel" ]
        (assemble ~profile ~source assembly) in
    expect_ok (check vector_add);
    expect_ok (check vector_compare);
    expect_obligation obligation (check narrowed);
    expect_obligation (if profile = Rake.Target.X86_avx2 then "no rack memory" else "literal rack loads only") (check memory))
    [ Rake.Target.X86_sse2, "paddd xmm0, xmm1", "pcmpgtd xmm0, xmm1",
      "vpaddd ymm0, ymm0, ymm1", "paddd xmm0, XMMWORD PTR [rax]", "one XMM per rack";
      Rake.Target.X86_avx2, "vpaddd ymm0, ymm0, ymm1", "vpcmpgtd ymm0, ymm0, ymm1",
      "vpaddd xmm0, xmm0, xmm1", "vpaddd ymm0, ymm0, YMMWORD PTR [rax]", "one YMM per rack";
      Rake.Target.X86_avx512, "vpaddd zmm0, zmm0, zmm1", "vpcmpd k1, zmm0, zmm1, 1",
      "vpaddd ymm0, ymm0, ymm1", "vpaddd zmm0, zmm0, ZMMWORD PTR [rax]", "one ZMM per rack" ];
  (* Independent multiply objects exercise the ISA boundary, including MMX,
     narrowed vectors, memory sources and scalar work that the emitter avoids. *)
  List.iter (fun (profile, valid, wrong_width, memory, scalar, width_obligation) ->
    let source = "integer-multiply-verifier-fixture" in
    let check body = Rake.Native_verify.verify ~profile ~source ~functions:[ "multiply_kernel" ]
      (assemble ~profile ~source
        (".intel_syntax noprefix\n.text\n.globl multiply_kernel\nmultiply_kernel:\n    " ^ body ^ "\n    ret\n")) in
    expect_ok (check valid);
    expect_obligation width_obligation (check wrong_width);
    expect_obligation (if profile = Rake.Target.X86_avx2 then "no rack memory" else "literal rack loads only") (check memory);
    expect_obligation "instruction allow-list" (check scalar))
    [ Rake.Target.X86_sse2, "pmuludq xmm0, xmm1", "pmuludq mm0, mm1",
        "pmuludq xmm0, XMMWORD PTR [rax]", "imul eax, ecx", "full-width integer multiply";
      Rake.Target.X86_avx2, "vpmulld ymm0, ymm0, ymm1", "vpmulld xmm0, xmm0, xmm1",
        "vpmulld ymm0, ymm0, YMMWORD PTR [rax]", "imul eax, ecx", "one YMM per rack";
      Rake.Target.X86_avx512, "vpmulld zmm0, zmm0, zmm1", "vpmulld ymm0, ymm0, ymm1",
        "vpmulld zmm0, zmm0, ZMMWORD PTR [rax]", "imul eax, ecx", "one ZMM per rack" ];
  List.iter (fun (profile, valid, wrong_width, width_obligation, memory) ->
    let source = "integer-andnot-verifier-fixture" in
    let check body = Rake.Native_verify.verify ~profile ~source ~functions:[ "andnot_kernel" ]
      (assemble ~profile ~source
        (".intel_syntax noprefix\n.text\n.globl andnot_kernel\nandnot_kernel:\n    " ^ body ^ "\n    ret\n")) in
    expect_ok (check valid);
    expect_obligation width_obligation (check wrong_width);
    expect_obligation (if profile = Rake.Target.X86_avx2 then "no rack memory" else "literal rack loads only") (check memory);
    expect_obligation "instruction allow-list" (check "not eax"))
    [ Rake.Target.X86_sse2, "andnps xmm0, xmm1", "vandnps ymm0, ymm0, ymm1",
        "one XMM per rack", "andnps xmm0, XMMWORD PTR [rax]";
      Rake.Target.X86_avx2, "vandnps ymm0, ymm0, ymm1", "vandnps xmm0, xmm0, xmm1",
        "one YMM per rack", "vandnps ymm0, ymm0, YMMWORD PTR [rax]";
      Rake.Target.X86_avx512, "vpandnd zmm0, zmm0, zmm1", "vpandnd ymm0, ymm0, ymm1",
        "one ZMM per rack", "vpandnd zmm0, zmm0, ZMMWORD PTR [rax]" ];
  (* Absolute-value objects are assembled independently of Rake's selector.
     SSE2 needs a packed sequence because PABSD was introduced in SSSE3. *)
  List.iter (fun (profile, valid, wrong_width, width_obligation, memory) ->
    let source = "integer-absolute-verifier-fixture" in
    let check body = Rake.Native_verify.verify ~profile ~source ~functions:[ "absolute_kernel" ]
      (assemble ~profile ~source
        (".intel_syntax noprefix\n.text\n.globl absolute_kernel\nabsolute_kernel:\n    " ^ body ^ "\n    ret\n")) in
    expect_ok (check valid);
    expect_obligation width_obligation (check wrong_width);
    expect_obligation (if profile = Rake.Target.X86_avx2 then "no rack memory" else "literal rack loads only") (check memory);
    expect_obligation "instruction allow-list" (check "neg eax"))
    [ Rake.Target.X86_sse2,
        "movaps xmm1, xmm0\n    psrad xmm1, 31\n    xorps xmm0, xmm1\n    psubd xmm0, xmm1",
        "pabsd xmm0, xmm1", "instruction allow-list", "psubd xmm0, XMMWORD PTR [rax]";
      Rake.Target.X86_avx2, "vpabsd ymm0, ymm1", "vpabsd xmm0, xmm1",
        "one YMM per rack", "vpabsd ymm0, YMMWORD PTR [rax]";
      Rake.Target.X86_avx512, "vpabsd zmm0, zmm1", "vpabsd ymm0, ymm1",
        "one ZMM per rack", "vpabsd zmm0, ZMMWORD PTR [rax]" ];
  (* These separately assembled bytes check the new shift contract independently
     of selection: full racks, literal counts, no memory and no scalar lanes. *)
  List.iter (fun (profile, prefix, register, wrong_width, width_obligation) ->
    List.iter (fun operation ->
      let source = "integer-shift-verifier-fixture" in
      let check body = Rake.Native_verify.verify ~profile ~source ~functions:[ "shift_kernel" ]
        (assemble ~profile ~source
          (".intel_syntax noprefix\n.text\n.globl shift_kernel\nshift_kernel:\n    " ^ body ^ "\n    ret\n")) in
      let shift count = if profile = Rake.Target.X86_sse2 then
          Printf.sprintf "%s%s %s0, %d" prefix operation register count
        else Printf.sprintf "%s%s %s0, %s0, %d" prefix operation register register count in
      List.iter (fun count -> expect_ok (check (shift count))) [ 0; 1; 31 ];
      expect_obligation "full-width literal integer shift" (check (shift 32));
      expect_obligation width_obligation
        (check (if profile = Rake.Target.X86_sse2 then operation ^ " mm0, 1"
          else Printf.sprintf "%s%s %s0, %s0, 1" prefix operation wrong_width wrong_width));
      expect_obligation (if profile = Rake.Target.X86_sse2 then "full-width literal integer shift" else width_obligation)
        (check (if profile = Rake.Target.X86_sse2 then operation ^ " xmm0, xmm1"
          else Printf.sprintf "%s%s %s0, %s0, xmm1" prefix operation register register));
      expect_obligation (if profile = Rake.Target.X86_avx2 then "no rack memory" else "literal rack loads only")
        (check (if profile = Rake.Target.X86_sse2 then operation ^ " xmm0, XMMWORD PTR [rax]"
          else Printf.sprintf "%s%s %s0, %s0, XMMWORD PTR [rax]" prefix operation register register));
      expect_obligation "instruction allow-list" (check "shl eax, 1")) [ "pslld"; "psrld"; "psrad" ])
    [ Rake.Target.X86_sse2, "", "xmm", "mm", "full-width literal integer shift";
      Rake.Target.X86_avx2, "v", "ymm", "xmm", "one YMM per rack";
      Rake.Target.X86_avx512, "v", "zmm", "ymm", "one ZMM per rack" ];
  List.iter (fun profile ->
    let register, memory, width = match profile with
      | Rake.Target.X86_avx2 -> "ymm", "YMMWORD", "one YMM per rack"
      | Rake.Target.X86_avx512 -> "zmm", "ZMMWORD", "one ZMM per rack"
      | _ -> assert false in
    List.iter (fun mnemonic ->
      let source = "integer-extrema-verifier-fixture" in
      let check body = Rake.Native_verify.verify ~profile ~source ~functions:[ "extrema_kernel" ]
        (assemble ~profile ~source
          (".intel_syntax noprefix\n.text\n.globl extrema_kernel\nextrema_kernel:\n    " ^ body ^ "\n    ret\n")) in
      expect_ok (check (Printf.sprintf "%s %s0, %s0, %s1" mnemonic register register register));
      expect_obligation width (check (mnemonic ^ " xmm0, xmm0, xmm1"));
      expect_obligation (if profile = Rake.Target.X86_avx2 then "no rack memory" else "literal rack loads only")
        (check (Printf.sprintf "%s %s0, %s0, %s PTR [rax]" mnemonic register register memory));
      expect_obligation "instruction allow-list" (check "cmovg eax, ecx")) [ "vpminsd"; "vpmaxsd"; "vpminud"; "vpmaxud" ])
    [ Rake.Target.X86_avx2; Rake.Target.X86_avx512 ];
  (* Direct 32-bit extrema need SSE4.1 and cannot enter the SSE2 profile. *)
  let unsigned_profile = Rake.Target.X86_avx512 and unsigned_source = "unsigned-compare-verifier-fixture" in
  let unsigned_check instruction = Rake.Native_verify.verify ~profile:unsigned_profile ~source:unsigned_source ~functions:["unsigned_kernel"]
    (assemble ~profile:unsigned_profile ~source:unsigned_source
      (".intel_syntax noprefix\n.text\n.globl unsigned_kernel\nunsigned_kernel:\n    " ^ instruction ^ "\n    ret\n")) in
  List.iter (fun predicate ->
    expect_ok (unsigned_check (Printf.sprintf "vpcmpud k1, zmm0, zmm1, %d" predicate)))
    [0; 1; 2; 4; 5; 6];
  expect_obligation "one ZMM per rack" (unsigned_check "vpcmpud k1, ymm0, ymm1, 1");
  expect_obligation "literal rack loads only" (unsigned_check "vpcmpud k1, zmm0, ZMMWORD PTR [rax], 1");
  expect_obligation "reserved opmask register" (unsigned_check "vpcmpud k2, zmm0, zmm1, 1");
  expect_obligation "full-width unsigned integer comparison" (unsigned_check "vpcmpud k1, zmm0, zmm1, 3");
  List.iter (fun mnemonic ->
    let profile = Rake.Target.X86_sse2 and source = "sse2-extrema-verifier-fixture" in
    expect_obligation "instruction allow-list"
      (Rake.Native_verify.verify ~profile ~source ~functions:[ "extrema_kernel" ]
        (assemble ~profile ~source
          (".intel_syntax noprefix\n.text\n.globl extrema_kernel\nextrema_kernel:\n    " ^ mnemonic ^ " xmm0, xmm1\n    ret\n"))))
    [ "pminsd"; "pmaxsd"; "pminud"; "pmaxud" ];
  let profile = Rake.Target.Aarch64_neon in
  let source = "neon-integer-verifier-fixture" in
  let check instruction =
    let assembly = Printf.sprintf {|
.arch armv8-a+simd
.text
.globl integer_kernel
.type integer_kernel, %%function
integer_kernel:
    %s
    ret
.size integer_kernel, .-integer_kernel
.section .note.GNU-stack,"",%%progbits
|} instruction in
    Rake.Native_verify.verify ~profile ~source ~functions:[ "integer_kernel" ]
      (assemble ~profile ~source assembly) in
  expect_ok (check "add v0.4s, v0.4s, v1.4s");
  expect_ok (check "cmgt v0.4s, v0.4s, v1.4s");
  List.iter (fun mnemonic ->
    expect_ok (check (mnemonic ^ " v0.4s, v0.4s, v1.4s"));
    expect_obligation "four 32-bit integer lanes" (check (mnemonic ^ " v0.2s, v0.2s, v1.2s"));
    expect_obligation "four 32-bit integer lanes" (check (mnemonic ^ " v0.8h, v0.8h, v1.8h"))) ["cmhi"; "cmhs"];
  expect_ok (check "neg v0.4s, v0.4s");
  expect_ok (check "abs v0.4s, v1.4s");
  expect_obligation "four 32-bit integer lanes" (check "abs v0.2s, v1.2s");
  expect_obligation "four 32-bit integer lanes" (check "abs v0.8h, v1.8h");
  expect_obligation "four 32-bit integer lanes" (check "abs d0, d1");
  expect_ok (check "mul v0.4s, v0.4s, v1.4s");
  expect_ok (check "bic v0.16b, v0.16b, v1.16b");
  expect_obligation "full-width integer and-not" (check "bic v0.8b, v0.8b, v1.8b");
  expect_obligation "full-width integer and-not" (check "bic v0.4s, #1");
  expect_obligation "no scalarized lane control" (check "bic w0, w0, w1");
  List.iter (fun mnemonic ->
    List.iter (fun count -> expect_ok (check (Printf.sprintf "%s v0.4s, v0.4s, #%d" mnemonic count))) [ 1; 31 ];
    expect_obligation "four-lane literal integer shift" (check (mnemonic ^ " v0.2s, v0.2s, #1"));
    expect_obligation "four-lane literal integer shift" (check (mnemonic ^ " v0.8h, v0.8h, #1")))
    [ "shl"; "ushr"; "sshr" ];
  expect_ok (check "shl v0.4s, v0.4s, #0");
  expect_obligation "four-lane literal integer shift" (check "ushr v0.4s, v0.4s, #32");
  expect_obligation "four-lane literal integer shift" (check "sshr v0.4s, v0.4s, #32");
  expect_obligation "no scalarized lane control" (check "lsl w0, w0, #1");
  List.iter (fun mnemonic ->
    expect_ok (check (mnemonic ^ " v0.4s, v0.4s, v1.4s"));
    expect_obligation "four 32-bit integer lanes" (check (mnemonic ^ " v0.2s, v0.2s, v1.2s"));
    expect_obligation "four 32-bit integer lanes" (check (mnemonic ^ " v0.8h, v0.8h, v1.8h")))
    [ "smin"; "smax"; "umin"; "umax" ];
  expect_obligation "four 32-bit integer lanes" (check "add v0.8h, v0.8h, v1.8h");
  expect_obligation "four 32-bit integer lanes" (check "cmeq v0.16b, v0.16b, v1.16b");
  expect_obligation "four 32-bit integer lanes" (check "neg v0.2s, v0.2s");
  expect_obligation "four 32-bit integer lanes" (check "neg v0.8h, v0.8h");
  expect_obligation "four 32-bit integer lanes" (check "mul v0.2s, v0.2s, v1.2s");
  expect_obligation "four 32-bit integer lanes" (check "mul v0.8h, v0.8h, v1.8h");
  expect_obligation "no scalarized lane control" (check "mul w0, w0, w1");
  expect_obligation "no scalarized lane control" (check "add w0, w0, w1");
  (* A selected traversal extent includes control flow and embedded literals.
     Independent mutations must fail even if their mnemonics look harmless. *)
  let traversal = {|
.intel_syntax noprefix
.text
.p2align 5
.globl exact_stream
.type exact_stream, @function
exact_stream:
    test rsi, rsi
    je .Ldone
    vmovups ymm0, YMMWORD PTR [rdi]
    vsqrtps ymm0, ymm0
    vmovups YMMWORD PTR [rdx], ymm0
.Ldone:
    ret
    .long 0x3f800000
.size exact_stream, .-exact_stream
|} in
  check_selected_traversal ~profile:Rake.Target.X86_avx2 ~traversal
    ~mutations:[ "je .Ldone", "jne .Ldone";
      "[rdi]", "[rdi + 4]";
      "vsqrtps ymm0, ymm0", "vmulps ymm0, ymm0, ymm0";
      "0x3f800000", "0x40000000" ]
    ~kernel:"vsqrtps ymm0, ymm0" ~helper:"call opaque_helper";
  let neon_traversal = {|
.arch armv8-a+simd
.text
.p2align 4
.globl exact_stream
.type exact_stream, %function
exact_stream:
    cmp x1, #0
    b.le .Ldone
    ldr q0, [x0]
    fsqrt v0.4s, v0.4s
    str q0, [x2]
.Ldone:
    ret
    .long 0x3f800000
.size exact_stream, .-exact_stream
|} in
  check_selected_traversal ~profile:Rake.Target.Aarch64_neon ~traversal:neon_traversal
    ~mutations:[ "b.le .Ldone", "b.lt .Ldone";
      "[x0]", "[x0, #16]";
      "fsqrt v0.4s, v0.4s", "fmul v0.4s, v0.4s, v0.4s";
      "0x3f800000", "0x40000000" ]
    ~kernel:"fsqrt v0.4s, v0.4s" ~helper:"bl opaque_helper";
  let valid = assemble ~source:"valid-verifier-fixture" valid in
  expect_ok
    (Rake.Native_verify.verify ~source:"valid-verifier-fixture"
       ~functions:[ "verified_kernel"; "verified_mul"; "verified_identity" ]
       ~expected_fma_count:1 valid);
  expect_obligation "exact FMA count"
    (Rake.Native_verify.verify ~source:"valid-verifier-fixture"
       ~functions:[ "verified_kernel"; "verified_mul"; "verified_identity" ]
       ~expected_fma_count:2 valid);
  let stack = assemble ~source:"stack-verifier-fixture" stack in
  expect_obligation "no stack use"
    (Rake.Native_verify.verify ~source:"stack-verifier-fixture"
       ~functions:[ "stack_kernel" ] stack);
  let call = assemble ~source:"call-verifier-fixture" call in
  expect_obligation "no calls"
    (Rake.Native_verify.verify ~source:"call-verifier-fixture"
       ~functions:[ "call_kernel" ] call);
  let cross_lane = assemble ~source:"cross-lane-verifier-fixture" cross_lane in
  expect_obligation "source-authorized cross-lane operation"
    (Rake.Native_verify.verify ~source:"cross-lane-verifier-fixture"
       ~functions:[ "strict_scan" ] cross_lane);
  expect_ok
    (Rake.Native_verify.verify ~source:"cross-lane-verifier-fixture"
       ~functions:[ "strict_scan" ] ~cross_lane_functions:[ "strict_scan" ]
       cross_lane);
  (* Independently assembled return transfers may cross the scalar C ABI
     only at the terminal boundary of a source-declared integer result. *)
  List.iter (fun (profile, prefix, zero, transfer, wrong_transfer, scalar) ->
    let fixture body = Printf.sprintf
      "%s\n.text\n.globl mask_result\nmask_result:\n%s\n    ret\n" prefix body in
    let check body =
      let source = "mask-result-verifier-fixture" in
      Rake.Native_verify.verify ~profile ~source ~functions:[ "mask_result" ]
        ~integer_result_functions:[ "mask_result" ]
        (assemble ~profile ~source (fixture body)) in
    expect_ok (check (zero ^ "\n" ^ transfer));
    expect_obligation "integer result boundary" (check (zero ^ "\n" ^ wrong_transfer));
    expect_obligation "integer result boundary" (check zero);
    let expect_rejected = function
      | Error _ -> () | Ok () -> failwith "scalar mask-result path passed verification" in
    expect_rejected (check (transfer ^ "\n" ^ zero ^ "\n" ^ transfer));
    expect_rejected (check (zero ^ "\n" ^ scalar ^ "\n" ^ transfer));
    expect_rejected (Rake.Native_verify.verify ~profile ~source:"unauthorized-result-transfer"
      ~functions:[ "mask_result" ]
      (assemble ~profile ~source:"unauthorized-result-transfer" (fixture (zero ^ "\n" ^ transfer)))))
    [ Rake.Target.X86_sse2, ".intel_syntax noprefix", "    pxor xmm0, xmm0",
        "    movd eax, xmm0", "    movd eax, xmm1", "    inc eax";
      Rake.Target.X86_avx2, ".intel_syntax noprefix", "    vpxor ymm0, ymm0, ymm0",
        "    vmovd eax, xmm0", "    vmovd edx, xmm0", "    inc eax";
      Rake.Target.X86_avx512, ".intel_syntax noprefix", "    vpxord zmm0, zmm0, zmm0",
        "    vmovd eax, xmm0", "    vmovd eax, xmm1", "    inc eax";
      Rake.Target.Aarch64_neon, ".arch armv8-a+simd", "    movi v0.4s, #0",
        "    umov w0, v0.s[0]", "    umov w0, v0.s[1]", "    add w0, w0, #1" ];
  let mask_fold_source = "neon-mask-fold-fixture" in
  let mask_fold body = assemble ~profile:Rake.Target.Aarch64_neon ~source:mask_fold_source
    (".arch armv8-a+simd\n.text\n.globl mask_fold\nmask_fold:\n    " ^ body ^ "\n    ret\n") in
  let check_fold ?(authorized = true) body = Rake.Native_verify.verify
    ~profile:Rake.Target.Aarch64_neon ~source:mask_fold_source ~functions:[ "mask_fold" ]
    ~cross_lane_functions:(if authorized then [ "mask_fold" ] else []) (mask_fold body) in
  expect_ok (check_fold "ext v1.16b, v0.16b, v0.16b, #8");
  expect_obligation "source-authorized mask fold" (check_fold ~authorized:false "ext v1.16b, v0.16b, v0.16b, #8");
  expect_obligation "source-authorized mask fold" (check_fold "ext v1.16b, v0.16b, v0.16b, #2");
  expect_obligation "source-authorized mask fold" (check_fold "ext v1.16b, v0.16b, v2.16b, #8");
  (* Independently assembled permutation bytes require source authorization.
     An authorized literal read must never authorize a rack store. *)
  List.iter (fun (profile, register, memory, bytes) ->
    let assembly = Printf.sprintf {|
.intel_syntax noprefix
.text
.globl shuffle_kernel
.type shuffle_kernel, @function
shuffle_kernel:
    vpermps %s0, %s1, %s0
    ret
.size shuffle_kernel, .-shuffle_kernel
.globl shuffle_literal
.type shuffle_literal, @function
shuffle_literal:
    vmovaps %s1, %s PTR [rip + shuffle_indices]
    vpermps %s0, %s1, %s0
    ret
.size shuffle_literal, .-shuffle_literal
.globl shuffle_store
.type shuffle_store, @function
shuffle_store:
    vmovaps %s PTR [rip + shuffle_indices], %s0
    ret
.size shuffle_store, .-shuffle_store
.data
.p2align 6
shuffle_indices:
    .zero %d
.section .note.GNU-stack,"",@progbits
|} register register register register memory register register register memory register bytes in
    let source = "shuffle-verifier-fixture" in
    let object_code = assemble ~profile ~source assembly in
    let check ?(authorized = false) function_name =
      Rake.Native_verify.verify ~profile ~source ~functions:[ function_name ]
        ~cross_lane_functions:(if authorized then [ function_name ] else []) object_code in
    expect_obligation "source-authorized cross-lane operation" (check "shuffle_kernel");
    expect_ok (check ~authorized:true "shuffle_kernel");
    let memory_obligation = if profile = Rake.Target.X86_avx2
      then "no rack memory" else "literal rack loads only" in
    expect_obligation memory_obligation (check "shuffle_literal");
    expect_ok (check ~authorized:true "shuffle_literal");
    expect_obligation memory_obligation (check ~authorized:true "shuffle_store"))
    [ Rake.Target.X86_avx2, "ymm", "YMMWORD", 32;
      Rake.Target.X86_avx512, "zmm", "ZMMWORD", 64 ];
  let neon_profile = Rake.Target.Aarch64_neon in
  (* Object disassembly annotates a literal address with a symbol. That symbol
     must not count as a register; actual stack and rack-memory operands must. *)
  let check_neon_literal function_name instruction =
    let source = "neon-literal-symbol-fixture" in
    let assembly = Printf.sprintf {|
.arch armv8-a+simd
.text
.globl %s
.type %s, %%function
%s:
    %s
    ret
.size %s, .-%s
.section .rodata.cst16,"aM",%%progbits,16
.p2align 4
.Lneon_literal:
    .long 0x3f800000, 0x3f800000, 0x3f800000, 0x3f800000
.section .note.GNU-stack,"",%%progbits
|} function_name function_name function_name instruction function_name function_name in
    Rake.Native_verify.verify ~profile:neon_profile ~source ~functions:[ function_name ]
      (assemble ~profile:neon_profile ~source assembly) in
  List.iter (fun function_name ->
    expect_ok (check_neon_literal function_name "ldr q0, .Lneon_literal"))
    [ "spread"; "sp"; "x29"; "q8"; "v8.4s"; "narrow.2s" ];
  List.iter (fun instruction ->
    expect_obligation "no stack use" (check_neon_literal "spread" instruction))
    [ "ldr q0, [sp]"; "ldr q0, [x29]"; "add w29, w0, #1"; "add wsp, w0, #1" ];
  expect_obligation "literal rack loads only" (check_neon_literal "spread" "ldr q0, [x0]");
  let neon_valid =
    assemble ~profile:neon_profile ~source:"neon-valid-verifier-fixture"
      neon_valid
  in
  expect_ok
    (Rake.Native_verify.verify ~profile:neon_profile
       ~source:"neon-valid-verifier-fixture" ~functions:[ "neon_verified" ]
       ~expected_fma_count:1 neon_valid);
  expect_obligation "exact FMA count"
    (Rake.Native_verify.verify ~profile:neon_profile
       ~source:"neon-valid-verifier-fixture" ~functions:[ "neon_verified" ]
       ~expected_fma_count:2 neon_valid);
  let neon_callee_saved =
    assemble ~profile:neon_profile ~source:"neon-callee-saved-fixture"
      neon_callee_saved
  in
  expect_obligation "AAPCS64 leaf register set"
    (Rake.Native_verify.verify ~profile:neon_profile
       ~source:"neon-callee-saved-fixture"
       ~functions:[ "neon_bad_register" ] neon_callee_saved);
  let neon_scalar =
    assemble ~profile:neon_profile ~source:"neon-scalar-fixture" neon_scalar
  in
  expect_obligation "no scalar floating arithmetic"
    (Rake.Native_verify.verify ~profile:neon_profile
       ~source:"neon-scalar-fixture" ~functions:[ "neon_scalar" ] neon_scalar);
  let neon_prefix = assemble ~profile:neon_profile ~source:"neon-prefix-fixture" {|
.arch armv8-a+simd
.text
.globl neon_prefix
.type neon_prefix, %function
neon_prefix:
    dup v1.4s, v0.s[1]
    fadd v2.4s, v1.4s, v0.4s
    ins v0.s[2], v2.s[0]
    ret
.size neon_prefix, .-neon_prefix
.section .note.GNU-stack,"",%progbits
|} in
  expect_obligation "no lane extraction"
    (Rake.Native_verify.verify ~profile:neon_profile ~source:"neon-prefix-fixture"
      ~functions:[ "neon_prefix" ] neon_prefix);
  expect_ok
    (Rake.Native_verify.verify ~profile:neon_profile ~source:"neon-prefix-fixture"
      ~functions:[ "neon_prefix" ] ~cross_lane_functions:[ "neon_prefix" ] neon_prefix);
  let neon_insert = assemble ~profile:neon_profile ~source:"neon-insert-fixture" {|
.arch armv8-a+simd
.text
.globl neon_insert
.type neon_insert, %function
neon_insert:
    ins v0.s[0], v1.s[0]
    ret
.size neon_insert, .-neon_insert
.section .note.GNU-stack,"",%progbits
|} in
  expect_obligation "no lane extraction"
    (Rake.Native_verify.verify ~profile:neon_profile ~source:"neon-insert-fixture"
      ~functions:[ "neon_insert" ] neon_insert);
  expect_ok
    (Rake.Native_verify.verify ~profile:neon_profile ~source:"neon-insert-fixture"
      ~functions:[ "neon_insert" ] ~cross_lane_functions:[ "neon_insert" ] neon_insert);
  let neon_unselected_lane = assemble ~profile:neon_profile ~source:"neon-unselected-lane-fixture" {|
.arch armv8-a+simd
.text
.globl neon_unselected_lane
.type neon_unselected_lane, %function
neon_unselected_lane:
    ins v0.s[0], v1.s[1]
    ret
.size neon_unselected_lane, .-neon_unselected_lane
.section .note.GNU-stack,"",%progbits
|} in
  expect_obligation "no lane extraction"
    (Rake.Native_verify.verify ~profile:neon_profile ~source:"neon-unselected-lane-fixture"
      ~functions:[ "neon_unselected_lane" ] ~cross_lane_functions:[ "neon_unselected_lane" ] neon_unselected_lane);
  check_integer_argument_boundaries ();
  check_conversion_instruction_boundaries ();
  check_uniform_shift_sequences ();
  print_endline "native object-code verification test passed"
