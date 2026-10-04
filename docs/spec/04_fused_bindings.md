# Fused bindings

*Binding* is general programming terminology for associating a name with a
value. A declaration introduces the name, and a definition supplies its
meaning. Rake's `let name = expression` does both: it gives the expression's
value a name that later code can use.

*Fusion* is a compiler term for combining separate pieces of work so they
can execute together. Rake's `| name <| expression` binds one stage of a
fused vector calculation. Read it from right to left: the expression flows
into `name`. Consecutive stages line up on their leading bars, so we can
follow the calculation down the page:

<!-- rake-check: verify x86-avx2 aarch64-neon wasm-simd128 -->
```rake
scratch advance(positions: f32s, velocities: f32s) -> f32s:
  | scaled: f32s <| velocities * <0.5>
  | moved: f32s  <| positions + scaled
  moved
```

The type annotation, as in `scaled: f32s`, is optional, and when present it
must match the expression's type. A fused name is a value, like a `let` name:
it is bound once, and it isn't a memory location, an evaluation point or a
rounding boundary. `scaled` exists for the reader. The two stages above are
the same computation as `| moved <| positions + velocities * <0.5>`.

## The contract

Every rack on the implemented profiles lives in one physical CPU register or
one WebAssembly `v128` value, with no source-visible spills. A fused
binding requires its expression to be pure data flow that the
compiler can emit as one contiguous run of vector instructions. The compiler
proves that or rejects the binding. It never falls back to something weaker.

A fused expression may contain arithmetic, comparisons, mask logic, uniforms,
`if ... then ... else`, `fma`, shuffles, and calls to these built-in
operations:

```text
sqrt abs floor ceil trunc nearest min max exp log log2 tanh select
dot narrow widen_low widen_high to_f32 to_i32 to_u32
bit_and bit_or bit_xor bit_andnot shift_bits_left shift_bits_right shift_bits_right_signed
relaxed_madd relaxed_nmadd relaxed_min relaxed_max
```

It can't contain a call to a scratch, rake or other function, a reduction, a
scan, `extract`, `insert`, `bitmask`, indexing or another memory access, a
conversion such as `bitcast`, or a record or array. A function's effects
aren't inferred yet, so a user-defined call can't enter a fused region even
when it is pure. A rejection gives the binding and the reason:

<!-- rake-check: reject "Fused binding contract for 'total' rejected: reduction is not an inlineable expression shape" -->
```rake
scratch spread(values: f32s) -> f32:
  | total: f32 <| sum(values)
  total
```

## Rewrites and fused multiply-add

Inside a fused region, arithmetic describes data flow rather than instruction
order or intermediate rounding. The language allows the compiler to
substitute identifiers, reassociate, factor, distribute, share common
subexpressions and form fused instructions, choosing the cheapest graph for
the profile. Different profiles may therefore round one floating-point
expression differently.

The compiler implements part of that. It substitutes fused identifiers, and on
`x86-avx2`, `x86-avx512` and `aarch64-neon` it contracts an `f32` multiply feeding an add in the
same fused region into one fused multiply-add, removing the multiply when
nothing else uses it. `advance` above compiles to one `vfmadd231ps` on AVX2
and AVX-512, and one `fmla` on NEON. A multiply and an add outside a fused region, or in
two different regions, stay separate. `wasm-simd128` contracts nothing,
because WebAssembly SIMD128 has no fused multiply-add. SSE2 also keeps the
multiply and add separate, because its ISA has no fused instruction. Reassociation,
factoring, distribution and the sharing of subexpressions aren't implemented.
Integer multiply and add retain their wrapping integer semantics. This
floating-point rewrite doesn't apply to them.

`fma(a, b, c)` requires `a * b + c` rounded once. The compiler also forms fused multiply-adds
where the source permits contraction. On AVX2, AVX-512 and NEON it is one fused instruction,
and `--verify-native` checks that the object holds exactly the fused
multiply-adds the compiler selected, both contracted and explicit.
SSE2 and `wasm-simd128` reject `fma`. Rake has no slower, stricter arithmetic mode: a
program that depends on an exact operation specifies it explicitly.

Reductions and scans have a defined lane order. That order is part of their
result, and fusion never reassociates it, even when their input comes from a
fused region.
