# The backend

This page describes how `rakec` turns source into machine code, and which
stage checks each promise from [the goals](GOALS.md).

## Scratches and rakes

```text
source
  -> layout check, lexer and layout tokens, parser       the AST
  -> type checker                                        types, capabilities and lane coverage
  -> native lowering                                     typed native IR
  -> native IR verifier
  -> optimiser                                           identifiers substituted, fused multiply-adds formed, dead code removed
  -> instruction selection for the profile
       x86-sse2      shared x86 IR -> no-spill XMM allocation -> GNU assembly -> as
       x86-avx2      shared x86 IR -> no-spill YMM allocation -> GNU assembly -> as
       x86-avx512    shared x86 IR -> no-spill ZMM allocation -> GNU assembly -> as
       aarch64-neon  machine IR -> no-spill vector allocation -> GNU assembly -> as
       wasm-simd128  WebAssembly instructions -> C with one intrinsic each -> clang
  -> object verifier                                     the disassembled object
```

The type checker accepts a program only when every construct it uses has a
type rule and is available, and `rakec --print-capabilities` lists that
status for each feature. Global tines are instantiated with their typed
arguments before the checker proves mask coverage. A Boolean decision diagram
checks that each use of a partial `through` result stays inside its defined
mask, and that the sweep covers every lane. Comparisons remain independent
Boolean atoms, so `gaps` complements a mask without assuming numeric identities
that fail for NaNs. Cross-lane operations require fully defined operands.

Native lowering turns a scratch or rake into typed SSA, inlining the scratches
and rakes it calls. A `through` without `else` needs no intermediate fallback
selection. The sweep supplies the values for its complementary lanes.
The IR verifier checks that
every value is defined once and before its uses, that each operation has
operands of the right types, that a fused region is contiguous and holds only
pure rack or mask operations, that every block ends in exactly one
terminator, and, on profiles with floating-point exceptions, that each
exception-capable operation under a mask has replaced its inactive operands.
`--emit-native-ir` prints the IR after optimisation. For the `advance` scratch
of [fused bindings](spec/04_fused_bindings.md), on `x86-avx2`:

```text
func @advance(%0 : rack<f32> positions, %1 : rack<f32> velocities) -> rack<f32> {
  %2 : rack<f32> = rack.splat f32:0x3f000000
  %4 : rack<f32> = rack.fma %1, %2, %0 {fused=0}
  return %4
}
```

Each value is numbered and typed, constants show their bits, and `{fused=0}`
or `{through=%3}` records the fused region or the mask an instruction belongs
to. On `wasm-simd128` the same function keeps its `mul` and `add`, because
that profile forms no fused multiply-adds.

Instruction selection either finds a native form for every operation or
rejects the function and reports the operation. Nothing falls back to scalar
code or a helper call. The x86 and AArch64 allocators place every live rack
in one register and reject a function that would need more registers than the
profile has, or arguments on the stack. `--emit-asm` prints the assembly, or
the C on wasm, and the system assembler or clang only encodes it.

In the development compiler, `abs` clears each lane's sign bit. SSE2 and AVX2
use `andps` and `vandps` with a literal magnitude mask. AVX-512F uses `vpandd`,
and NEON uses a literal rack and `and`. These are full-width bitwise operations,
so they introduce no floating-point exception, even for a signalling NaN.

Lane-wise `min` and `max` reuse the x86 reduction pipeline's strict
comparison-and-selection sequence. It propagates NaNs and orders −0 below
+0, with five temporary vector registers checked by the allocator. NEON
selects `fmin` and `fmax` on complete four-lane registers. These operations
use the caller's [floating-point environment](spec/01_primitives_operations_and_targets.md#floating-point-values).
Under a participation mask, native lowering sanitises both operands before
performing the operation, including in a stream's partial rack.

Integral rounding uses full-width `vroundps` on AVX2, `vrndscaleps` on
AVX-512F, and NEON's `frintm`, `frintp`, `frintz` and `frintn`. SSE2 has no
round-to-float instruction, so it selects vector conversions and masks.
Only magnitudes below 2²³ need conversion because larger binary32 values
are already integral. Directed rounding corrects the truncated value,
and a final selection preserves large values, infinities and signed zero.
Its five temporary registers count towards allocation pressure.

The [Intel instruction reference](https://cdrdv2-public.intel.com/835757/325383-sdm-vol-2abcd.pdf)
describes the conversion and rounding instructions, and the
[Arm instruction reference](https://documentation-service.arm.com/static/67e40f3398aa3c3b6eea6a85)
describes NEON's integral rounding. The SSE2 conversions may raise inexact
for a fractional active input. The other native profiles suppress that flag
for these operations. Results have the same non-NaN bits, while the language
doesn't require matching inexact flags between profiles. A signalling NaN
raises invalid on native profiles only when its lane participates.

NEON reductions and scans keep a left-to-right prefix in a full register.
They broadcast each next lane with `dup` and perform three packed steps.
Scans insert the new prefix with `ins`, and extrema explicitly select the
language's canonical NaN. The [reduction contract](spec/06_reductions_and_scans.md)
specifies their order and the permitted lane transfers.

Float extraction consumes its literal index during instruction selection.
SSE2 uses a full-width `shufps`. AVX2 selects the containing 128-bit group
with `vperm2f128`, then uses `vpermilps` within that group. AVX-512F uses
`vshuff32x4` and `vpermilps`, and NEON uses `dup`. The selected bits occupy
the whole destination register, with its low `f32` returned through the
scalar ABI. No scalar arithmetic or memory temporary is introduced. Bounds
follow the selected profile, and the allocator preserves a still-live source.

Float insertion replaces one literal-index lane with a uniform's bits.
SSE2 broadcasts the scalar and merges it through a literal one-lane mask.
AVX2 uses `vbroadcastss` and immediate `vblendps`. AVX-512F uses
`vbroadcastss` and a one-bit `k1` mask with `vmovaps`, without requiring
AVX-512DQ, BW or VL. The x86 allocator counts the broadcast temporary and
reuses only a dying input rack for the destination. NEON uses `ins` from
the scalar argument's low lane, copying the input rack when it remains live.
The insertion sequence is shared with scan accumulation on each architecture.

Static float shuffles select a complete output rack from one or two input
racks. SSE2 uses immediate `shufps`: two inputs need two permutations and a
bitwise mask merge. AVX2 and AVX-512F use full-width `vpermps` with a literal
index vector. Two inputs need two permutations and a vector blend. NEON
uses four `dup` broadcasts and three `ins` transfers. These sequences
preserve lane bits across register subdivisions, without scalar arithmetic
or memory temporaries. The allocator counts every scratch register and
keeps both inputs intact while a two-rack shuffle reads them.

Mask reductions combine full-width lane groups with permutations and
bitwise AND or OR. `all` and `any` finish with a vector mask that normalises
the result to zero or one. `bitmask` first applies the lane weights
`[1, 2, 4, 8, ...]`, then ORs the groups. Each sequence uses one allocated
temporary vector register. A source-declared `bool` or `u32` result ends
with `movd` or `vmovd` into `eax` on x86, or `umov` into `w0` on AArch64.
The verifier accepts only that terminal result transfer, and still rejects
intermediate scalar lane work.

A direct uniform `f32` condition broadcasts both comparison operands and
uses the existing ordered vector comparison. Its mask selects the same arm
in every participating lane. The branches pass through the common masked
lowering, so untaken arithmetic receives benign operands. Outer through masks
and stream tails further limit participation. This uses no scalar comparison
or branch inside the register kernel. Integer and Boolean uniform conditions
remain work in progress on physical profiles.

Native 32-bit integer racks share the float racks' register widths and C
vector argument slots. Add and subtract select packed `paddd` and `psubd`
on SSE2, their full-width VEX/EVEX forms on AVX2 and AVX-512F, or NEON
`add` and `sub` with four 32-bit lanes. Bitwise operations use the existing
register-only logical instructions. Signed integer negation subtracts each
lane from zero. The x86 profiles clear a separate destination register before
packed subtraction, preserving the source until it's consumed. NEON selects
one full-width `neg vD.4s, vS.4s` instruction.
Multiplication keeps the low 32 bits for signed and unsigned racks. AVX2 and
AVX-512F select full-width `vpmulld`, and NEON selects `mul .4s`. SSE2
multiplies the even lanes with `pmuludq`, then multiplies the odd lanes in two
allocated temporaries. Four `shufps` instructions put the low product words
back in lane order. Those temporaries participate in the no-spill register
allocation. The final-object verifier permits these shuffles for the selected
SSE2 multiply and checks full-register multiply operands on every profile.
Signed lane-wise extrema select `vpminsd` or `vpmaxsd` on AVX2 and AVX-512F,
or `smin .4s` and `smax .4s` on NEON. SSE2 uses `pcmpgtd` in an allocated
mask register, followed by vector logical selection. Both input racks remain
available until the selection finishes, including when the destination
reuses a dying input. The verifier checks full-width extrema operands and
rejects the SSE4.1 `pminsd` and `pmaxsd` instructions in the SSE2 profile.
Literal bit shifts use packed `pslld`, `psrld` or `psrad` on SSE2 and their
full-width VEX/EVEX forms on AVX2 and AVX-512F. NEON uses `shl`, `ushr` or
`sshr` with `.4s` operands. Instruction selection consumes a literal count
from 0 to 31. A zero count needs only a register copy, elided when the
destination reuses the input. The final-object verifier checks register
widths and immediate bounds, rejecting register-supplied counts and memory
operands in these register kernels. Native runtime shift counts remain
work in progress.
Signed comparisons use `pcmpeqd` and
`pcmpgtd` on SSE2 and AVX2, with operand reversal or mask inversion for the
other predicates. AVX-512F uses `vpcmpd` and expands its `k1` result into a
full rack without requiring AVX-512DQ. NEON uses `cmeq`, `cmgt` and `cmge`,
with mask inversion for inequality. The final-object verifier rejects
narrow integer vectors, scalar arithmetic and integer memory operands.
Integer masks and float masks share the same lane representation, so either
can select float or integer racks. Native integer streams and uniform integer
arguments remain work in progress.

## Whole programs

```text
source
  -> parser and type checker
  -> tier checker                  runs and slow code in tier IR; each pure rack
                                   expression in a run goes through the scratch
                                   pipeline above
  -> C emitter                     one C file with a C entry point
  -> clang for wasm32 with SIMD128
  -> object verifier               scratches, rakes and runs in the object
```

The tier checker enforces the rules of [the slow tier](spec/08_slow_tier.md):
slow code holds no racks, a scalar becomes a rack only at a marked argument,
and only an explicit slow block in a run can call scalar code or read module
state. The C emitter lifts each such block to a never-inlined scalar helper,
capturing scalar values and pointer/count pairs, never racks. It forms a
run's addresses, writes its loops, tails and checks, and inlines its rack
expressions, which native lowering and wasm selection compile as they compile
a scratch. `rakec --interpret` runs `main` in Rake's executable semantics,
evaluating rack expressions in the same reference semantics as scratches, and
`test/program_test.sh` compares it with the compiled program.

The unreleased development compiler adds a native mixed destination for the
same tier IR:

```text
register kernels -> Rake selection and allocation -> opaque GNU assembly ─┐
explicit slow code -> scalar C and C ABI declarations ────────────────────┤
                                                                        v
                                                              one native C unit
                                                                        |
                                                              platform C compiler
                                                                        |
                                                               one native object
                                                                        |
                                                              register-kernel verifier
```

This development path supports the limited SSE2, AVX2, AVX-512 and NEON stream traversal.
General native runs remain work in progress. Slow callers can pass
uniform `f32` arguments and receive `f32`, `bool` or `u32` results from register kernels.
The platform compiler lowers explicit slow code and supplies the System V
AMD64 or AAPCS64 C ABI. It cannot rewrite the opaque kernel assembly, which
the final-object verifier checks using Rake's selected instruction contract.
`test/native_program_test.sh` compares scalar and mixed results with the
selected-profile interpreter. Independent C checks header-backed struct
layout and imports/exports on x86 and under AArch64 QEMU; known lane counts
also check the x86 reduction fixtures.

A process entry with parameters gets a compiler-owned adapter for
`int main(int argc, char **argv)`. The adapter copies the pointer array into
typed byte-pointer storage without aliasing the runtime's `char **` object.
The startup checks compare the interpreter with independently compiled C on
every physical profile and through WASI's command startup.

## Profiles

On x86, an `f32s` rack and its lane mask occupy one XMM register on SSE2,
one YMM register on AVX2, or one ZMM register on AVX-512F. All three profiles
share one instruction-selection and no-spill allocation pipeline. The
emitter chooses two-address SSE2 instructions or three-address AVX
instructions, and each object verifier checks only its profile's ISA.
SSE2 reserves `xmm15` for instruction-local temporaries. AVX-512 uses `k1`
while materialising or selecting a vector mask, and needs no AVX-512DQ,
BW or VL instructions.

On `x86-avx2`, an `f32s` rack is one YMM register and a mask is a YMM value.
Arguments follow the System V convention in eight SSE-class registers, and a
uniform `f32` arrives in an XMM register, whose YMM identifier denotes the same physical
register, so the allocator tracks the pair as one. A uniform's use is a
`vbroadcastss`. The profile needs AVX2 and FMA3.

On `aarch64-neon`, an `f32s` rack is one 128-bit vector register. Arguments
take `v0` to `v7` and rack and `f32` results return in `v0`. Mask reductions
return their completed Boolean or bitset in `w0`. The allocator uses the 24
registers that a call may clobber, `v0` to `v7` and `v16` to `v31`. GNU
cross-binutils assemble and disassemble the object, and
`test/neon_backend_test.sh` compares exact result bits under QEMU.

On `wasm-simd128`, a rack is one `v128` in the WebAssembly virtual machine.
Rake adheres to that machine's fiction. It selects virtual SIMD instructions
and locals, but doesn't try to replace the WebAssembly runtime's physical
register allocation. A value used once is computed where it is consumed, and
one used more than once is kept in a local. The output is C, one
`wasm_simd128.h` intrinsic for each selected instruction, because some wasm32
toolchains accept only C and reject `v128` operands to inline assembly.

The promise is the same as on a physical target: outside a `slow` block, rack
work uses vector instructions wherever the selected profile implements the
operation. A run may also contain the uniform address, loop and bounds work
written in its source. It never replaces rack work with scalar lane loops.

## Native traversal selection

Rake selects a native stream's loop, addresses, full-rack transfers and tail.
Its lane expression goes through the same SSA selector
and no-spill allocator as a register kernel. The tail is lowered under its
participation mask, so inactive operands cannot raise arithmetic exceptions.
The complete stream is opaque assembly inside the native C unit. C supplies
only slow orchestration and its ABI. SSE2 and NEON use count-guarded lane
transfers for the tail, then evaluate its arithmetic as one masked rack.
AVX2 and AVX-512 use fault-suppressing masked vector transfers.

The final traversal function's complete bytes must match a separately
assembled selection. This includes its branches, address operands and
embedded literals. Unresolved relocations fail verification, preventing
unverified helpers or external constants from changing that graph. Guard
pages and an independent C oracle check the memory and numerical semantics.
This stage supports one to four `f32` read columns and an `f32` output.
The output is a separate stream pointer or one column in a mutable stack.
A separate destination stack may have a different record layout. Column
updates load every input rack before writing the result.
The count may be `i32` or `i64`. The former is sign-extended to the native
address width at entry, before signed count guards or pointer access.
Up to eight uniform `f32` arguments use the platform C register slots.
The traversal copies them into preserved caller-clobbered vector registers,
and their allocator lifetimes extend across iterations. That prevents an
argument from being overwritten after its last use in the first rack.
[Native CPU streams](spec/02_packs_and_run.md#native-cpu-streams) defines
the accepted subset and caller obligations.

## Object verification

`--verify-native` disassembles the object and checks register kernels against
their profile's instruction list. Native streams use the complete-function
selection check above:

- On SSE2, AVX2, AVX-512 and NEON: no calls, no stack, every rack in one
  whole register, no scalar arithmetic on rack lanes, cross-lane instructions
  only in selected reductions, scans, extractions, insertions and shuffles,
  and exactly the fused multiply-adds that the compiler selected.
  Integer results have one checked terminal transfer into `eax` or `w0`.
- For a `wasm-simd128` scratch or rake: only locals, constants and register
  instructions, with no calls, memory or branches.
- For a `wasm-simd128` run: direct calls only to the helpers for its explicit
  slow blocks, verified by their object relocations, no C stack, only the vector
  instructions its source selected or their documented equivalents, and no
  more lane operations or loops than its source states.

[Primitives, operations, and targets](spec/01_primitives_operations_and_targets.md#verification) and [the
slow tier](spec/08_slow_tier.md#verification) give the details.

## Ownership

Rake owns the IR, its rewrites and instruction selection on every profile.
It owns register allocation and assembly on x86 and AArch64. For WebAssembly,
clang encodes the selected virtual instructions and the runtime assigns
physical registers. The system toolchain also owns object formats,
relocations, linking and start-up. Debug information and exception unwinding
aren't produced. The x86 and AArch64 backends in 0.6.0-beta compile scratches
and rakes only. The development compiler adds native mixed programs through
the limited scalar C boundary above. General runs compile on WebAssembly;
SSE2, AVX2, AVX-512 and NEON implement the stream subset.

## Planned GPU pipeline

GPU profiles will add lane-to-invocation mapping, uniformity and collective
participation to the existing checked lowering. They will preserve useful
parallel execution, with explicit memory and synchronisation effects.
They will never serially emulate a rack with a hidden per-thread lane loop.

```text
Physical CPU: Rake selection + allocation -> assembly -> object verification
WebAssembly: Rake virtual SIMD selection -> object verification -> runtime
NVIDIA (planned): Rake SIMT mapping -> PTX -> pinned ptxas -> cubin verification
Vulkan (later): Rake subgroup mapping -> SPIR-V -> driver -> device verification
```

The proposed `nvidia-ptx-sm120` profile targets PTX 8.7 and a 32-thread warp.
NVIDIA will own final allocation and instruction scheduling. Rake will check
the final cubin's instructions, control/data flow and resources against its
contract, rejecting unknown or insufficient evidence. A certificate applies
to that artifact, not every translation of its PTX.

The runtime will load only the verified cubin, with an explicit parameter ABI,
context and CUDA stream. It will refuse an unverified PTX JIT fallback.
Hardware scheduling, input-dependent lane activity and achieved occupancy
remain outside compiler ownership. [The GPU design](GPU.md) separates the
proof obligations from measurements and defines the acceptance gates.
