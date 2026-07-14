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

let () =
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
  let neon_profile = Rake.Target.Aarch64_neon in
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
  print_endline "native object-code verification test passed"
