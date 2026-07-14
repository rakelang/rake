# Rake fixtures

These sources are the Rake side of the 400-particle structure-of-arrays proof.
The workload passes `count = 400` at runtime; 400 is not baked into the kernel.
For `f32s`, the selected target fixes the number of lanes in one rack, so
the source does not name SSE, AVX2, or AVX-512 vector types.

## Status

- `particles_400_run.rk` is the canonical `advance_x` SoA source. It declares
  two columnar fields, accepts a runtime count and scalar `dt`, and traverses
  the pack in target-native chunks. Native `run`/pack
  traversal, loads, stores, loop control, and masked tails remain unavailable,
  so it is not yet executable through the native backend.
- `advance_rack.rk` is the same arithmetic body as a straight-line `crunch`.
  The current AVX2 backend emits an object for it and verifies that its rack
  operations stay in YMM registers without calls, spills, stack use, or scalar
  lane arithmetic. Its named `displacement` is a transparent fused alias: the
  optimizer substitutes it, removes the dead multiply, and emits one FMA. This
  differs intentionally from the demo's contraction-disabled C and explicit
  multiply/add Rust variants. It proves the current register-only backend
  slice, not pack traversal.
- `reject_sin.rk` is the primary fail-closed rejection proof. Rack-level
  `sin(values)` is valid in the frontend, but no current native profile owns a
  compliant inline vector-sine implementation. AVX2 and NEON therefore reject
  it during native SSA lowering instead of calling a library helper
  or scalarizing lanes. Neither target emits assembly.
- `reject_register_pressure.rk` is secondary, compiler-specific evidence. It passes
  frontend checking, then AVX2 native register allocation rejects the fused
  region because it would need 17 simultaneously live YMM registers while the
  profile provides 16. There is no spill fallback.

## Honest verification

From the repository root inside `nix develop`:

```sh
dune exec rakec -- demo/soa-proof/rake/particles_400_run.rk
dune exec rakec -- --target x86-avx2 --verify-native \
  demo/soa-proof/rake/advance_rack.rk \
  -o /tmp/rake-soa-proof-advance.o
dune exec rakec -- demo/soa-proof/rake/reject_register_pressure.rk
dune exec rakec -- demo/soa-proof/rake/reject_sin.rk
dune exec rakec -- --target x86-avx2 --emit-asm \
  demo/soa-proof/rake/reject_sin.rk \
  -o /tmp/rake-soa-proof-sin-avx2.s
dune exec rakec -- --target aarch64-neon --emit-asm \
  demo/soa-proof/rake/reject_sin.rk \
  -o /tmp/rake-soa-proof-sin-neon.s
dune exec rakec -- --target x86-avx2 --emit-asm \
  demo/soa-proof/rake/reject_register_pressure.rk \
  -o /tmp/rake-soa-proof-pressure.s
```

The first four commands must succeed. The next two must fail during native SSA
lowering because `sin` has no compliant lowering, and neither may
produce assembly. The final command must fail during native register allocation
and report both `17 simultaneously live YMM registers` and
`no spill fallback is permitted`; it must not produce assembly.

At 400 elements, a full-width traversal performs 25 chunks with 16-lane
AVX-512 racks, 50 chunks with 8-lane AVX2 racks, or 100 chunks with 4-lane
128-bit racks. The number of SoA fields remains two on every target; SIMD width
changes the lane count per rack, not the number of stacks.
