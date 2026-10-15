# The backend

This page describes how `rakec` turns source into machine code, and which
stage checks each requirement from [the goals](GOALS.md).

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

The type checker accepts a program only when each of its constructs has a
type rule and is available on the selected profile. If a profile can't
compile a feature, such as an explicit `fma` on SSE2, the checker rejects it
where the source uses it, with the profile's reason. `rakec --print-capabilities` lists each
feature's status, including partial support: the physical profiles compile
`i32` and `u32` racks but not 8-, 16- or 64-bit ones, and stack runs but not
general runs over views. `test/capability_profile_test.sh` fails if that
report disagrees with the fixtures that compile on each profile.

The checker instantiates global tines with their typed arguments, then proves
with a Boolean decision diagram that each use of a partial `through` result
stays inside its defined mask and that the sweep covers every lane.
Comparisons stay independent Boolean atoms, so `gaps` complements a mask
without assuming numeric identities, which fail for NaNs. Cross-lane
operations need fully defined operands.

Native lowering turns a scratch or rake into typed SSA and inlines its calls
to other scratches and rakes. The IR verifier then checks that every value is
defined once before its uses, that operand types match, that each fused
region is contiguous and pure, and that every block has exactly one
terminator. On profiles with floating-point exceptions, it also checks that
each exception-capable operation under a mask has replaced its inactive
operands. `--emit-native-ir` prints the IR after optimisation. For the
`advance` scratch of [fused bindings](spec/04_fused_bindings.md), on
`x86-avx2`:

```text
func @advance(%0 : rack<f32> positions, %1 : rack<f32> velocities) -> rack<f32> {
  %2 : rack<f32> = rack.splat f32:0x3f000000
  %4 : rack<f32> = rack.fma %1, %2, %0 {fused=0}
  return %4
}
```

Constants show their bits, and `{fused=0}` or `{through=%3}` marks the fused
region or mask containing an instruction. On `wasm-simd128` the same function
keeps its `mul` and `add`, because that profile forms no fused multiply-adds.

Instruction selection either finds a native form for every operation or
rejects the function and reports the operation. Nothing falls back to scalar
code or a helper call. The x86 and AArch64 allocators place every live rack
and each sequence's temporaries in their own registers, and reject a
function that would need more registers than the profile has, or arguments on
the stack.

## Instruction selection

Every operation works on full-width registers of 32-bit lanes, and integer
racks share the float racks' registers and C argument slots:

| Operation | SSE2 | AVX2 | AVX-512F | NEON |
| --- | --- | --- | --- | --- |
| `abs` on `f32s` | `andps` with a magnitude mask | `vandps` with a magnitude mask | `vpandd` | `and` with a literal rack |
| Float `min`, `max` | comparison and selection | comparison and selection | comparison and selection | `fmin`, `fmax` |
| Integral rounding | conversions and masks | `vroundps` | `vrndscaleps` | `frintm`, `frintp`, `frintz`, `frintn` |
| Lane extraction | `shufps` | `vperm2f128`, then `vpermilps` | `vshuff32x4`, then `vpermilps` | `dup` |
| Lane insertion | broadcast and masked merge | `vbroadcastss`, `vblendps` | `vbroadcastss`, `vmovaps` under `k1` | `ins` |
| Static shuffle | `shufps` | `vpermps` | `vpermps` | `dup` and `ins` |
| `bit_andnot` (`left & ~right`) | `andnps` | `vandnps` | `vpandnd` | `bic .16b` |
| Signed integer `abs` | sign mask, then `(input xor sign) - sign` | `vpabsd` | `vpabsd` | `abs .4s` |
| Integer multiply | `pmuludq` on even and odd lanes | `vpmulld` | `vpmulld` | `mul .4s` |
| Signed `min`, `max` | `pcmpgtd` and selection | `vpminsd`, `vpmaxsd` | `vpminsd`, `vpmaxsd` | `smin`, `smax` |
| Unsigned `min`, `max` | sign-bit XOR, `pcmpgtd` and selection | `vpminud`, `vpmaxud` | `vpminud`, `vpmaxud` | `umin`, `umax` |
| Signed comparisons | `pcmpeqd`, `pcmpgtd` | `pcmpeqd`, `pcmpgtd` | `vpcmpd` | `cmeq`, `cmgt`, `cmge` |
| Unsigned comparisons | sign-bit XOR, then signed | sign-bit XOR, then signed | `vpcmpud` | `cmhi`, `cmhs` |
| `i32s` to `f32s` | `cvtdq2ps` | `vcvtdq2ps` | `vcvtdq2ps` | `scvtf .4s` |
| `u32s` to `f32s` | two 16-bit halves | two 16-bit halves | `vcvtudq2ps` | `ucvtf .4s` |
| `to_i32` | `cvtps2dq` | `vcvtps2dq` | `vcvtps2dq` | `fcvtns .4s` |
| `to_u32` | range split at 2³¹ | range split at 2³¹ | `vcvtps2udq` | `fcvtnu .4s` |

Under a participation mask, native lowering sanitises an operation's inactive
operands first, including in a stack run's partial rack, so a signalling NaN
raises invalid only when its lane participates. Float `abs` is bitwise and
raises nothing. On x86, float `min` and `max` propagate NaNs and order −0
below +0. SSE2 has no round-to-float instruction, so it converts magnitudes
below 2²³, which are the only ones that can be fractional. Those conversions
may raise inexact, as the language allows, and the non-NaN result bits
match the other profiles. The
[Intel](https://cdrdv2-public.intel.com/835757/325383-sdm-vol-2abcd.pdf) and
[Arm](https://documentation-service.arm.com/static/67e40f3398aa3c3b6eea6a85)
instruction references describe the conversion and rounding instructions.

SSE2 lacks several integer instructions, so Rake builds them from older ones.
Unsigned extrema and comparisons XOR bit 31 into copies of both inputs and
compare those as signed, and AVX2 does the same for unsigned comparisons.
Unsigned racks keep a distinct IR element through selection, so unsigned
ordering never depends on signed predicates. The verifier keeps SSE4.1's
`pminsd` and `pmaxsd` and SSSE3's `pabsd` out of the SSE2 profile.

A runtime
`u32` shift count is taken modulo 32 in a temporary register: x86 shifts the
count's 64-bit word left and then right by 59, and NEON shifts its broadcast
word left and right by 27. The verifier accepts a runtime shift only as that
complete sequence.

For `u32s` to `f32s`, SSE2 and AVX2 convert the two 16-bit halves separately
and compute `high × 65,536 + low`. The conversions and the multiplication are
exact, so the addition is the only rounding. `to_i32` zeroes NaNs, and
`to_u32` zeroes NaNs and negative values. Both then convert and restore the
saturated endpoints with vector selections. For `to_u32`, SSE2 and AVX2
subtract 2³¹ from the upper half, which is exact in binary32, convert as
signed and restore the high bit with an XOR.

Extraction, insertion and shuffles take literal indices and move lane bits
without numerical conversion, scalar arithmetic or memory temporaries. An
extracted float returns through the scalar floating-point ABI, and an integer
moves into `eax` on x86-64 or `w0` on AArch64 at the return boundary. Mask
reductions combine lane groups with permutations and AND or OR, and a `bool`
or `u32` result ends with the same kind of terminal transfer. The verifier
allows that one transfer and rejects any scalar lane work before it. NEON
reductions and scans keep a left-to-right prefix in a full register, in the
order set out in [reductions and scans](spec/06_reductions_and_scans.md).

A uniform condition broadcasts its operands and compares them as vectors, so
its mask selects the same arm in every participating lane, and the common
masked lowering gives untaken arithmetic benign operands. A Boolean uniform
becomes a mask by shifting its broadcast low word left by 31 and
arithmetically right by 31. Short-circuit `and` and `or` limit the right-hand
comparison to the lanes that need its result. No scalar comparison or branch
enters a register kernel.

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
which captures scalar values and pointer/count pairs but never racks. It forms
a run's addresses, writes its loops, tails and checks, and inlines its rack
expressions, which compile as they would in a scratch. `rakec --interpret`
runs `main` in Rake's executable semantics, and `test/program_test.sh`
compares it with the compiled program.

Native targets compile the same tier IR into one C unit:

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

The platform compiler lowers explicit slow code and supplies the System V
AMD64 or AAPCS64 C ABI. It can't rewrite the opaque kernel assembly, and the
final-object verifier checks that assembly against Rake's selection. This
path compiles stack runs on SSE2, AVX2, AVX-512 and NEON, but general runs
over views remain work in progress there. Slow callers can pass uniform
`f32`, `i32`, `u32` and `bool` arguments to register kernels and receive
results of the same types. A process entry with parameters gets a
compiler-owned adapter for `int main(int argc, char **argv)`.

## Profiles

On x86, an `f32s` rack and its mask each occupy one XMM register on SSE2, one
YMM register on AVX2 or one ZMM register on AVX-512F. The three profiles
share one selection and allocation pipeline, and each object verifier checks
only its profile's ISA. SSE2 reserves `xmm15` for instruction-local
temporaries, AVX2 also needs FMA3, and AVX-512 uses `k1` for masks without
needing AVX-512DQ, BW or VL. Rack, mask and `f32` arguments follow the System V convention
in eight SSE-class registers.

Integer and Boolean uniforms arrive through the C integer argument registers,
up to six on x86 and eight on AArch64. At entry, Rake moves them into vector
registers, which is the only added scalar instruction, and a Boolean keeps
only its value bit so that unspecified upper bits can't leak in. The verifier
checks this entry sequence against the declared register mapping.

On `aarch64-neon`, an `f32s` rack is one 128-bit vector register. SIMD
arguments arrive in `v0` to `v7`, and rack and `f32` results return in `v0`.
The allocator uses the 24 caller-saved registers, `v0` to `v7` and `v16` to
`v31`.

On `wasm-simd128`, a rack is one `v128` in the WebAssembly virtual machine.
Rake selects virtual SIMD instructions and locals and leaves physical register
allocation to the runtime. The output is C with one `wasm_simd128.h` intrinsic
per selected instruction, because some wasm32 toolchains accept only C and
reject `v128` operands to inline assembly. A partial store hides its scalar
remainder from clang with an empty `asm` operand, because otherwise clang can
pull integer arithmetic past a lane extraction. The final-object verifier
rejects extra lane extractions or scalar lowering introduced by the C
compiler.

Clang can also rewrite packed code, for example by comparing a compact column
before widening it, or by forming an extending multiply. The verifier accepts
these substitutions only when source-derived bounds on both operands justify
them. Other rewrites, such as folding `(x << n) >> n` into a mask, can't be
proved across separate bindings yet, so the verifier rejects those objects.

Outside a `slow` block, rack work uses vector instructions wherever the
selected profile implements the operation. A run may also contain its
source's uniform address, loop and bounds work, but it never replaces rack
work with scalar lane loops.

## Native stack runs

Rake selects a stack run's loop, addresses, full-rack transfers, tail and
compaction itself. Lowering returns all of a rack's replacements, or the
compaction's selection and every column, from one SSA function, so shared
values are computed once and each output stays in a register until the loop
stores it. The tail is lowered under its participation mask, so inactive
operands can't raise arithmetic exceptions. The complete run is opaque
assembly inside the native C unit, and C supplies only slow orchestration and
its ABI.

Each stack descriptor arrives in an integer register, and every column read
or written gets one pointer, loaded once. Full racks use unaligned vector
transfers, and compact columns are widened with packed extension. SSE2 and
NEON tails use count-guarded lane transfers, while AVX2 uses `vmaskmovps` and
AVX-512F masks every transfer with `k2`.

Compaction keeps a write cursor, which never passes the records already read,
so a full rack can store whole racks at the cursor without overwriting an
unread record. A tail stores only its selected lanes.

| Profile | Selection | Moving the selected lanes | Compact columns |
| --- | --- | --- | --- |
| AVX-512F | `vptestmd` into `k3`, combined with `k2` in the tail | `vcompressps` to memory | `vcompressps` in a register, then `vpmovdb` or `vpmovdw` under a prefix mask |
| AVX2 | `vmovmskps` bits | `vpermps` by a 256-entry table of lane orders | `vpshufb` and `vpermd` truncation |
| SSE2 | `movmskps` bits | a jump to one of 16 fixed `pshufd` permutations | sign-extending shifts and saturating packs |
| NEON | lane weights summed by `addv` | `tbl` by a 16-entry byte table | `xtn` |

A run keeps up to twenty columns in vector registers: six on SSE2, seven on
AVX2 and NEON. Up to eight uniform arguments are copied into vector registers
that stay allocated across iterations. Compilation fails when the argument
registers, the vector registers or the allocator run out.

The verifier compares the final run's complete bytes, including its branches,
address operands and embedded literals, with a separately assembled
selection. Unresolved relocations fail verification, so unverified helpers or
external constants can't change the run.
[The C boundary](spec/02_packs_and_run.md#the-c-boundary) defines the callers'
obligations.

## Object verification

`--verify-native` disassembles the object and checks register kernels against
their profile's instruction list. Native stack runs get the complete-function
check above:

- On SSE2, AVX2, AVX-512 and NEON: no calls, no stack, every rack in one
  whole register, no scalar arithmetic on rack lanes, cross-lane instructions
  only in selected reductions, scans, extractions, insertions and shuffles,
  and exactly the compiler's selected fused multiply-adds.
  Integer results have one checked terminal transfer into `eax` or `w0`.
- For a `wasm-simd128` scratch or rake: only locals, constants and register
  instructions, with no calls, memory or branches.
- For a `wasm-simd128` run: direct calls only to the helpers for its explicit
  slow blocks, verified by their object relocations, no C stack, only the vector
  instructions selected from its source or their documented equivalents, and
  no more lane operations or loops than its source states.

[Primitives, operations, and targets](spec/01_primitives_operations_and_targets.md#verification) and [the
slow tier](spec/08_slow_tier.md#verification) give the details.

## Ownership

Rake owns the IR, its rewrites and instruction selection on every profile,
and register allocation and assembly on x86 and AArch64. For WebAssembly,
clang encodes the selected virtual instructions and the runtime assigns
physical registers. The system toolchain owns object formats, relocations,
linking and start-up. Rake produces no debug information or exception
unwinding.

## Planned GPU pipeline

GPU profiles will add lane-to-invocation mapping, uniformity and collective
participation to the existing checked lowering. They'll keep useful parallel
execution, with explicit memory and synchronisation effects, and will never
emulate a rack serially with a hidden per-thread lane loop.

```text
Physical CPU: Rake selection + allocation -> assembly -> object verification
WebAssembly: Rake virtual SIMD selection -> object verification -> runtime
NVIDIA (planned): Rake SIMT mapping -> PTX -> pinned ptxas -> cubin verification
Vulkan (later): Rake subgroup mapping -> SPIR-V -> driver -> device verification
```

The proposed `nvidia-ptx-sm120` profile targets PTX 8.7 and a 32-thread warp.
NVIDIA will own final allocation and instruction scheduling, and Rake will
check the final cubin's instructions, control and data flow and resources,
rejecting unknown or insufficient evidence. A certificate applies to that
artifact's exact bytes. The runtime will load only the verified cubin and will
refuse an unverified PTX JIT fallback. [The GPU design](GPU.md) separates the
proof obligations from measurements and lists the
[verification tests](GPU.md#verification-tests).
