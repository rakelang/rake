# Rust SoA comparison kernels

This crate implements the canonical runtime-length SoA operation:

```text
output_x[i] = position_x[i] + velocity_x[i] * dt
```

It contains a scalar implementation and separately hand-written SSE2 (4-lane)
and AVX2 (8-lane) intrinsic implementations. Each intrinsic implementation has
its own scalar tail. The default demo count is 400, but passing a count on the
command line (for example, `403`) exercises a non-multiple tail.

The SIMD functions explicitly call multiply and add intrinsics, so they retain
two operations and two rounding points. Requesting FMA requires another
width-specific intrinsic and the corresponding target feature. The Rake source
instead gives the compiler one fused data-flow region; its current AVX2 and
NEON backends select FMA without an extra spelling or a user-selected slow
mode. The shared formula is therefore a machine-contract comparison, not a
bit-equivalence claim for rounding-sensitive inputs.

Build and verify on the host:

```sh
cargo run --release --manifest-path demo/soa-proof/rust/Cargo.toml -- 400
cargo run --release --manifest-path demo/soa-proof/rust/Cargo.toml -- 403
```

No global target feature is required. The exact per-function features are:

```text
advance_x_sse2:  #[target_feature(enable = "sse2")]
advance_x_avx2:  #[target_feature(enable = "avx2")]
pressure20_avx2: #[target_feature(enable = "avx2")]
reject_register_pressure_avx2: #[target_feature(enable = "avx2")]
RUSTFLAGS:       unset
```

Runtime dispatch uses `is_x86_feature_detected!`. To emit inspectable assembly
without changing feature assumptions:

```sh
cargo rustc --release --manifest-path demo/soa-proof/rust/Cargo.toml \
  --lib -- --emit=asm
```

The `.s` output is under `demo/soa-proof/rust/target/release/deps/`. Search for
the exported `advance_x_*` and `pressure20_avx2` symbols. For a host-specific
comparison build, use `RUSTFLAGS='-C target-cpu=native'`; this is optional and
may also autovectorize the scalar baseline, so it is not the canonical build.

`pressure20_avx2` intentionally makes 20 old `__m256` column values live before
any output store. AVX2 exposes only 16 architectural YMM registers. Rust accepts
the function and delegates spilling/reloading to LLVM; it has no language rule
that rejects a SIMD intrinsic program whose desired vector values cannot all
remain resident in registers.

`reject_register_pressure_avx2` transcribes the Rake negative test's exact DAG:
eight input racks, nine separately named `a + b` temporaries, then a
left-associated sum of `t0..t8` and `a..h`. It is exported and non-inlined, but
uses no volatile access, assembly, `black_box`, or optimizer barrier. Since the
nine additions have identical observable values, Rust does not promise that the
nine source temporaries survive optimization. Inspect its assembly to see
whether the tested compiler eliminates, recomputes, or spills them.

With the canonical build on `rustc 1.96.0`, LLVM common-subexpression-
eliminates the nine identical source additions. The assembly computes `a + b`
once, retains that one value, and adds it repeatedly in the required order. It
folds inputs `c..h` into memory operands and emits no vector stack spill in this
function. Thus Rust accepts the source by optimizing away its source-level
register pressure; it neither preserves the nine rack identities nor diagnoses
that preserving them would exceed the intended register contract. The separate
`pressure20_avx2` case remains as a stress test whose values cannot collapse;
the same canonical build emits vector spills/reloads for it.

`sin_array_scalar` is the other negative comparison. It applies strict
`f32::sin` across a runtime-length column with no fast-math and no custom
approximation. Stable x86 Rust provides no packed sine intrinsic, so any packed
math-library call or scalar `sinf` loop is an optimizer/backend outcome rather
than an intrinsic implementation supplied by this program.

On `rustc 1.96.0`, the canonical `sin_array_scalar` assembly is unrolled in
groups of four but still calls scalar `sinf` four times. LLVM temporarily saves
and reshuffles scalar results through XMM/stack storage; it emits neither a
packed sine instruction nor a packed vector-math call.

## AVX-512 limitation on stable Rust

As of the tested stable `rustc 1.96.0`, the `std::arch::x86_64` AVX-512
intrinsics and AVX-512 `target_feature` names remain unstable. Consequently this
stable-only crate cannot honestly provide an intrinsic `advance_x_avx512`
variant. Doing so requires nightly feature gates, stable inline assembly, or a
non-Rust SIMD backend. This is itself part of the comparison: portable source
does not automatically select 4, 8, or 16 lanes; the programmer has written the
4-lane and 8-lane loops separately and needs a third implementation for 16 lanes.
