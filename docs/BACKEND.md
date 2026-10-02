# The backend

This page describes how `rakec` turns source into machine code, and which
stage checks each promise from [the goals](GOALS.md).

## Scratches and rakes

```text
source
  -> layout check, lexer and layout tokens, parser       the AST
  -> type checker                                        types and capabilities
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
status for each feature. Native lowering turns a scratch or rake into typed
SSA, inlining the scratches and rakes it calls. The IR verifier checks that
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

This development path supports the limited AVX2 stream traversal below.
General native runs remain work in progress. Slow callers can pass
uniform `f32` arguments and receive `f32` results from register kernels.
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
take `v0` to `v7` and the result returns in `v0`. The allocator uses the 24
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

An AVX2 stream's loop, addresses, full-rack transfers and masked tail are
selected by Rake. Its lane expression goes through the same SSA selector
and no-spill allocator as a register kernel. The tail is lowered under its
participation mask, so inactive operands cannot raise arithmetic exceptions.
The complete stream is opaque assembly inside the native C unit. C supplies
only slow orchestration and its ABI.

The final traversal function's complete bytes must match a separately
assembled selection. This includes its branches, address operands and
embedded literals. Unresolved relocations fail verification, preventing
unverified helpers or external constants from changing that graph. Guard
pages and an independent C oracle check the memory and numerical semantics.
This stage supports one to four `f32` read columns and an `f32` output.
[Native AVX2 streams](spec/02_packs_and_run.md#native-avx2-streams) defines
the accepted subset and caller obligations.

## Object verification

`--verify-native` disassembles the object and checks each function against
its profile's list of instructions:

- On SSE2, AVX2, AVX-512 and NEON: no calls, no stack, every rack in one
  whole register, no scalar arithmetic on rack lanes, cross-lane instructions
  only in reductions and scans, and exactly the fused multiply-adds that the
  compiler selected.
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
AVX2 implements the stream subset. Other native run profiles remain WIP.

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
