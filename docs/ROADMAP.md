# Roadmap

The compiler covers part of what [the goals](GOALS.md) promise. This page
lists the rest, grouped by the work it needs. [The changelog](../CHANGELOG.md)
records what each release added.

## Runs on x86 and AArch64

Runs, packs and whole programs compile on `wasm-simd128` only. On `x86-avx2`
and `aarch64-neon` they need traversal in the native IR, full-rack loops with
native loads and stores, tails with masked memory and benign operands, the
[planned x86-64 boundary](spec/02_packs_and_run.md#planned-x86-64-boundary)
and its AArch64 counterpart, and tests that call them from C over empty, short,
exact and tail counts and check the object for vector memory operations and no
scalar cleanup loop.

## Operations on every profile

[Racks and targets](spec/01_racks_targets_and_abi.md) lists what each profile
compiles. The gaps:

- On `x86-avx2` and `aarch64-neon`:
  - `min`, `max`, `abs`, `floor`, `ceil`, `trunc` and `nearest`,
  - `exp`, `log`, `log2` and `tanh`,
  - conditionals on a uniform,
  - `all`, `any`, `bitmask`, `extract`, `insert` and shuffles,
  - integer racks, and
  - gather.
- On `aarch64-neon`: reductions and scans.
- On every profile:
  - `lanes` and `@`,
  - moving whole lanes: `shift_left`, `shift_right`, `rotate_left`,
    `rotate_right` and `zip_low`,
  - `sin`, `cos`, `tan`, `pow` and `atan2`, and float `%`,
  - `f64s`, `i8s`, `u16s` and `bools` racks,
  - comparisons, `min` and `max` of `u32s` and `u64s`, and `min` and `max`
    of `i64s`,
  - integer reductions,
  - widening bytes into 16-bit lanes, and narrow columns into 64-bit lanes,
  - scalar arithmetic in a crunch, as on reductions' results,
  - scatter, on a profile with a scatter instruction, and
  - compression and expansion, as [memory
    operations](spec/08_memory_operations.md) design them.

An operation may lower to several vector instructions when the profile's
published sequence allows it. It may never lower to scalar lanes, helper
calls, split racks or memory temporaries.

## Fused rewrites

The optimiser substitutes fused names and forms fused multiply-adds. The
language also allows reassociation, factoring, distribution, sharing of
common subexpressions and strength reduction inside a fused region, chosen by
each profile's operation costs. Each rewrite needs tests whose expected bits
come from the verified optimised graph.

## More profiles

`x86-avx512` and `x86-sse2` each need their own selection, register
allocation, assembly, calling convention, object verification and runtime
tests. AVX-512 should use its mask registers for through blocks, masked memory
and tails. SSE2 must reject any operation whose only form would split a rack,
call a helper or spill. The planned `scalar` profile would run Rake without
the one-register guarantee.

## Forms that parse but don't compile

Tuples, lambdas, expression pipelines and single-record layouts have AST forms
but no source syntax or semantics yet. Each needs a language decision before it
can become source.

## Release gates

A capability moves from unavailable to supported when one compiler revision
has all of these:

- the specification gives its types and meaning,
- unavailable and malformed uses get diagnostics with a source location,
- the interpreter covers ordinary, boundary and exceptional inputs,
- the compiled code matches the interpreter,
- the object verifier checks the profile's rules for it, and
- `rakec --print-capabilities`, the tests, the changelog and the
  documentation agree.

A published benchmark records its source, compiler version, profile,
command, input size, machine and baseline.
