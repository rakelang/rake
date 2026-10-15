# Vectors cheat sheet

A vector operation does the same work on several values at once. This page
explains the vocabulary for that work, first for CPU registers and then for
GPU threads, with four-lane examples so you can follow every value. For
Rake's own terms, see the [language glossary](GLOSSARY.md), and for what Rake
implements, see [primitives, operations, and targets](spec/01_primitives_operations_and_targets.md).
Rake's [GPU profiles](GPU.md) are currently a design.

[CPU](#cpu) · [GPU](#gpu)

## CPU

### Values, lanes and registers

Think of a vector register as a row of cells. Each cell holds one element,
and an instruction can operate on the whole row. A 256-bit register holds
eight 32-bit floats, sixteen 16-bit integers or thirty-two 8-bit integers.

<figure class="diagram diagram-vector-ops">
<div class="diagram-scroll" tabindex="0" role="region" aria-label="CPU lane operations, scroll horizontally on a narrow screen">
<svg viewBox="0 0 680 284" role="img" aria-labelledby="vector-basic-title vector-basic-desc">
<title id="vector-basic-title">Element-wise arithmetic, broadcast and shuffle</title>
<desc id="vector-basic-desc">Adding corresponding elements of two vectors gives 11, 22, 33, 44. Broadcasting 7 gives four copies. Shuffling the values a, b, c, d by indices 2, 0, 3, 1 gives c, a, d, b.</desc>
<text class="diagram-label" x="16" y="24">Element-wise add: each lane keeps its position</text>
<rect class="diagram-cell" x="16" y="38" width="308" height="38" rx="4"/>
<text class="diagram-instruction" x="170" y="57">[1, 2, 3, 4] + [10, 20, 30, 40]</text>
<path class="diagram-flow" d="M334 57 H364 l-7 -5 M364 57 l-7 5"/>
<rect class="diagram-cell diagram-cell-active" x="374" y="38" width="290" height="38" rx="4"/>
<text class="diagram-value" x="519" y="57">[11, 22, 33, 44]</text>
<text class="diagram-label" x="16" y="114">Broadcast / splat: one value fills every lane</text>
<rect class="diagram-cell" x="16" y="128" width="308" height="38" rx="4"/>
<text class="diagram-value" x="170" y="147">7</text>
<path class="diagram-flow" d="M334 147 H364 l-7 -5 M364 147 l-7 5"/>
<rect class="diagram-cell diagram-cell-active" x="374" y="128" width="290" height="38" rx="4"/>
<text class="diagram-value" x="519" y="147">[7, 7, 7, 7]</text>
<text class="diagram-label" x="16" y="204">Shuffle: select existing register lanes by index</text>
<rect class="diagram-cell" x="16" y="218" width="308" height="38" rx="4"/>
<text class="diagram-instruction" x="170" y="237">[a, b, c, d], indices [2, 0, 3, 1]</text>
<path class="diagram-flow" d="M334 237 H364 l-7 -5 M364 237 l-7 5"/>
<rect class="diagram-cell diagram-cell-active" x="374" y="218" width="290" height="38" rx="4"/>
<text class="diagram-value" x="519" y="237">[c, a, d, b]</text>
</svg>
</div>
<figcaption>Arithmetic changes values, a broadcast copies one value into every lane, and a shuffle changes which lane supplies each result.</figcaption>
</figure>

| Term | Meaning |
| --- | --- |
| Scalar | One value, such as a single float. |
| f32 / FP32 / binary32 | A 32-bit IEEE 754 float, C's `float`. `f64` / FP64 uses 64 bits. |
| Vector / packed value | Several elements held together in a register. In Rake, `pack` declares a record instead. |
| Element / lane | An element is a stored value, and a lane is its position within a vector operation. |
| SIMD | Single instruction, multiple data: one instruction operates on several elements. |
| Uniform / varying | A uniform has the same value in every lane, while a varying value can differ by lane. |
| Fixed-width / scalable vector / VLA | Fixed-width code assumes one register size. Scalable, vector-length-agnostic code adapts to the machine's vector length (VL), the active element count at each step. |
| SSE / SSE2 / XMM | x86 families with 128-bit XMM registers. SSE2 adds packed integer and double-precision operations, among others. |
| AVX / AVX2 / YMM | x86 families with 256-bit YMM registers. AVX2 extends packed integer operations and adds gathers. |
| AVX-512 / ZMM / opmask | x86 extensions with 512-bit ZMM registers and dedicated mask registers. |
| NEON / Advanced SIMD | Arm's fixed-width SIMD, with 128-bit vectors on AArch64. |
| SVE / SVE2 | Arm's scalable vectors, with predicates and vector-length-agnostic loops. |
| RVV / VLEN / SEW / LMUL | RISC-V vectors, the hardware register length, the selected element width, and the multiplier that groups registers into one logical vector. |
| WebAssembly SIMD / v128 | A virtual 128-bit vector. The runtime selects the physical instructions and allocates registers. |

Architecture references: [Intel intrinsics](https://www.intel.com/content/www/us/en/docs/intrinsics-guide/index.html),
[Arm Advanced SIMD](https://arm-software.github.io/acle/neon_intrinsics/advsimd.html),
[Arm scalable vectors](https://arm-software.github.io/acle/main/acle.html#sve-language-extensions),
[RISC-V vectors](https://docs.riscv.org/reference/isa/unpriv/v-st-ext.html)
and [WebAssembly vector instructions](https://webassembly.github.io/spec/core/syntax/instructions.html#vector-instructions).

### Moving values between lanes

A shuffle reads values already in registers, whereas a gather reads from
memory, so although both use indices, they differ in latency and memory
effects.

| Term | Meaning and example |
| --- | --- |
| Broadcast / splat | Replicate one value, from memory or a register lane: `7 → [7,7,7,7]`. |
| Shuffle / permute | Select and reorder source lanes, possibly repeating them: `[a,b,c,d]` with `[2,0,3,1]` gives `[c,a,d,b]`. |
| Swizzle / table lookup | Indexed lane selection from one vector or a small register table. |
| Static / dynamic shuffle | A shuffle whose indices are known at compilation, or computed at runtime. |
| Zip / interleave / unpack | Alternate elements from two vectors: `[a,b]` and `[x,y]` become `[a,x,b,y]`. Some instruction sets use “unpack” for this or for widening. |
| Unzip / deinterleave | Separate alternating elements: `[a,x,b,y]` becomes `[a,b]` and `[x,y]`. |
| Transpose | Exchange rows and columns, turning vectors of records into vectors of fields. |
| Reverse / rotate lanes | `[a,b,c,d]` becomes `[d,c,b,a]`, or cyclically `[d,a,b,c]`. Bit reversal and rotation stay inside an element. |
| Slide / shift lanes | Move whole elements or bytes across positions, filling from a defined value or a second source. Shifting bits inside each element is a different operation. |
| Extract / insert | Read one lane as a scalar, or replace one lane with a scalar. |
| Compress / compact | Pack selected lanes toward the start: `[a,b,c,d]` under `[1,0,1,0]` gives `[a,c,…]`. |
| Expand | Place dense values in selected positions: `[a,c]` under `[1,0,1,0]` gives `[a,fill,c,fill]`. |
| Lane-local / cross-lane | Lane-local work depends only on corresponding inputs, while cross-lane work exchanges or combines elements. Some instructions only exchange within 128-bit sub-vectors. |

The [GCC vector reference](https://gcc.gnu.org/onlinedocs/gcc/Vector-Extensions.html)
illustrates shuffle selection and conversion.

### Masks and selection

| Term | Meaning |
| --- | --- |
| Comparison | Compare corresponding elements to produce a mask: `[1,4,2,9] > 3 → [0,1,0,1]`. |
| Mask / predicate | A true or false choice per lane, held as vector bits or in a dedicated predicate register. |
| Active / inactive lane | A lane included in, or excluded by, the operation's mask. |
| Predication / merge / zero masking | Execute under a mask. Depending on the instruction, inactive lanes skip the work, keep an old value (merge masking) or become zero (zero masking). |
| Select / blend | Choose one of two values per lane: mask `[1,0,1,0]` selects `[a,y,c,w]` from `[a,b,c,d]` and `[x,y,z,w]`. |
| Any / all / none | Reduce a mask to one truth value. |
| Movemask / bitmask | Collect one bit per lane into a scalar. An x86 movemask usually takes each lane's sign bit. |
| Popcount / first set bit | Count a mask's selected lanes, or find the first one. An empty mask needs a defined result. |
| Masked load / store / first-fault | Memory operations on selected lanes only. Fault suppression stops some inactive accesses from faulting, and first-fault loads record how far a load got, but neither makes an invalid pointer safe. |
| Speculation / partial operation | Calculating both candidates before selecting. An operation valid for only part of its domain, such as square root, needs suppressed arithmetic or safe operands in inactive lanes. |

### Combining lanes and calculating values

<figure class="diagram diagram-vector-ops">
<div class="diagram-scroll" tabindex="0" role="region" aria-label="Reduction and scan, scroll horizontally on a narrow screen">
<svg viewBox="0 0 680 186" role="img" aria-labelledby="vector-reduce-title vector-reduce-desc">
<title id="vector-reduce-title">Reduction and prefix scan</title>
<desc id="vector-reduce-desc">Reducing 1, 2, 3, 4 by addition produces one value, 10. An inclusive scan produces 1, 3, 6, 10. An exclusive scan starting at zero produces 0, 1, 3, 6.</desc>
<text class="diagram-label" x="16" y="24">Input</text>
<rect class="diagram-cell" x="16" y="38" width="194" height="120" rx="4"/>
<text class="diagram-value" x="113" y="98">[1, 2, 3, 4]</text>
<path class="diagram-flow" d="M220 98 H256 M256 58 V138 M256 58 H294 l-7 -5 M294 58 l-7 5 M256 98 H294 l-7 -5 M294 98 l-7 5 M256 138 H294 l-7 -5 M294 138 l-7 5"/>
<rect class="diagram-cell diagram-cell-active" x="304" y="38" width="360" height="40" rx="4"/>
<rect class="diagram-cell diagram-cell-active" x="304" y="78" width="360" height="40" rx="4"/>
<rect class="diagram-cell diagram-cell-active" x="304" y="118" width="360" height="40" rx="4"/>
<text class="diagram-instruction" x="484" y="58">reduction: 10</text>
<text class="diagram-instruction" x="484" y="98">inclusive scan: [1, 3, 6, 10]</text>
<text class="diagram-instruction" x="484" y="138">exclusive scan: [0, 1, 3, 6]</text>
</svg>
</div>
<figcaption>A reduction produces one combined value, while a scan keeps each partial result.</figcaption>
</figure>

| Term | Meaning |
| --- | --- |
| Element-wise / vertical | Apply an operation independently at each lane position. |
| Horizontal / reduction | Combine lanes into fewer results, such as a sum or maximum. |
| Scan / prefix sum | Running partial results. An inclusive scan includes the current element, and an exclusive scan starts from an identity and excludes it. |
| Dot product | Multiply corresponding elements and sum the products, with instruction-specific accumulation width and rounding. |
| FMA / MAC | A fused multiply-add calculates `a*b+c` with one rounding. A multiply-accumulate may round once or twice, depending on the instruction. |
| Saturating / wrapping arithmetic | An overflow clamps to the limit, or wraps modulo the width: unsigned 8-bit `250+10` gives 255 or 4. |
| Widen / narrow / extend | Convert to a wider or narrower element type. Signed widening copies the sign bit and unsigned widening fills with zeros, while narrowing needs a rule for overflow. |
| Conversion / bitcast | A conversion preserves the numerical value where possible, while a bitcast reinterprets the same bits. |
| Logical / arithmetic shift | Shift bits inside each element, filling with zeros or, for arithmetic right shifts, the sign bit. |
| Transcendental functions | `sin`, `exp`, `log` and similar. A vector implementation may compute them with a polynomial or library sequence. |
| Ordered / unordered comparison | An ordered comparison is false when an operand is NaN, while an unordered one reports it. |
| NaN / infinity / signed zero | Special float values with their own comparison, minimum, maximum and arithmetic rules. |
| Subnormal / FTZ / DAZ | Very small floats. Flush-to-zero discards subnormal results, and denormals-are-zero treats subnormal inputs as zero. |
| Rounding / ULP / fast math | Rounding picks a representable result, an ULP is the spacing between representable values, and fast math permits specific departures from strict rules. |
| Reassociation | Regrouping, such as `(a+b)+c` to `a+(b+c)`, which can change a floating-point result, including in tree reductions. |

### Memory and data layout

<figure class="diagram diagram-vector-ops">
<div class="diagram-scroll" tabindex="0" role="region" aria-label="Gather and scatter, scroll horizontally on a narrow screen">
<svg viewBox="0 0 680 232" role="img" aria-labelledby="vector-memory-title vector-memory-desc">
<title id="vector-memory-title">Gather reads indexed memory, scatter writes it</title>
<desc id="vector-memory-desc">Memory contains a, b, c, d, e, f, g, h. Gathering indices 6, 1, 4, 3 produces g, b, e, d. Scattering W, X, Y, Z to those indices writes W at 6, X at 1, Y at 4 and Z at 3.</desc>
<text class="diagram-label" x="16" y="24">Memory indices 0 … 7</text>
<rect class="diagram-cell" x="16" y="38" width="648" height="36" rx="4"/>
<text class="diagram-value" x="340" y="56">[a, b, c, d, e, f, g, h]</text>
<text class="diagram-label" x="16" y="106">Gather, indices [6, 1, 4, 3]</text>
<path class="diagram-flow" d="M519 76 V87 l-5 -5 M519 87 l5 -5"/>
<rect class="diagram-cell diagram-cell-active" x="374" y="88" width="290" height="38" rx="4"/>
<text class="diagram-value" x="519" y="107">[g, b, e, d]</text>
<text class="diagram-label" x="16" y="164">Scatter [W, X, Y, Z] to those indices</text>
<path class="diagram-flow" d="M340 170 V182 l-5 -7 M340 182 l5 -7"/>
<rect class="diagram-cell diagram-cell-active" x="16" y="188" width="648" height="36" rx="4"/>
<text class="diagram-value" x="340" y="206">[a, X, c, Z, Y, f, W, h]</text>
</svg>
</div>
<figcaption>A contiguous load reads neighbouring elements, while gather and scatter use one address per lane.</figcaption>
</figure>

| Term | Meaning |
| --- | --- |
| Contiguous / strided | Neighbouring lanes access neighbouring elements, `[0,1,2,3]`, or elements a constant gap apart, `[0,2,4,6]`. |
| Gather / scatter | Load or store through one index per lane: `out[i] = memory[index[i]]` and `memory[index[i]] = value[i]`. A scatter needs a rule for duplicate destinations. |
| Alignment | An address that's a multiple of a byte boundary. Unaligned access support and cost vary by instruction. |
| Cache line / locality | A cache's unit of transfer, a block of nearby bytes. Good locality means reusing data or using nearby data. |
| AoS / SoA / AoSoA | Records stored whole (`x0,y0,x1,y1,…`), as separate field columns (`x0,x1,…` and `y0,y1,…`), or as small SoA tiles. Rake's stack uses SoA. |
| Aliasing / overlap | Different pointers referring to the same memory, so a vectorised loop needs rules for overlapping reads and writes. |
| Strip mining / tail | Dividing a loop into vector-sized chunks, and the incomplete final chunk, handled by masking or separate cleanup. |

### Data streams and traversal

A data stream is a sequence of elements or records, in memory or arriving from
a file or network, such as a column of a million floats. A stream traversal
walks along it one rack at a time: it loads the next rack, calculates the
result, stores it and advances. The sequence can be any length, so the final
rack may have fewer active lanes.

<figure class="diagram diagram-vector-ops">
<div class="diagram-scroll" tabindex="0" role="region" aria-label="Stream traversal, scroll horizontally on a narrow screen">
<svg viewBox="0 0 680 254" role="img" aria-labelledby="vector-stream-title vector-stream-desc">
<title id="vector-stream-title">A traversal processes a stream one rack at a time</title>
<desc id="vector-stream-desc">Eleven f32 elements on SSE2 form two full four-lane racks and a tail with three active lanes. For each rack, the traversal loads its elements, calculates a vector result, stores the active results and advances to the next rack.</desc>
<text class="diagram-label" x="16" y="24">11 f32 elements on SSE2: element indices in each rack</text>
<rect class="diagram-cell diagram-cell-active" x="16" y="38" width="202" height="46" rx="4"/>
<text class="diagram-value" x="117" y="61">[0, 1, 2, 3]</text>
<rect class="diagram-cell diagram-cell-active" x="230" y="38" width="202" height="46" rx="4"/>
<text class="diagram-value" x="331" y="61">[4, 5, 6, 7]</text>
<rect class="diagram-cell" x="444" y="38" width="220" height="46" rx="4"/>
<text class="diagram-value" x="554" y="61">[8, 9, 10, _]</text>
<text class="diagram-label" x="16" y="116">For each rack</text>
<rect class="diagram-cell" x="16" y="132" width="130" height="46" rx="4"/>
<text class="diagram-instruction" x="81" y="155">Load</text>
<path class="diagram-flow" d="M156 155 H180 l-7 -5 M180 155 l-7 5"/>
<rect class="diagram-cell diagram-cell-active" x="190" y="132" width="144" height="46" rx="4"/>
<text class="diagram-instruction" x="262" y="155">Vector work</text>
<path class="diagram-flow" d="M344 155 H368 l-7 -5 M368 155 l-7 5"/>
<rect class="diagram-cell" x="378" y="132" width="130" height="46" rx="4"/>
<text class="diagram-instruction" x="443" y="155">Store</text>
<path class="diagram-flow" d="M518 155 H542 l-7 -5 M542 155 l-7 5"/>
<rect class="diagram-cell" x="552" y="132" width="112" height="46" rx="4"/>
<text class="diagram-instruction" x="608" y="155">Advance</text>
<path class="diagram-flow" d="M608 188 V222 H81 V188 l-5 7 M81 188 l5 7"/>
<text class="diagram-instruction" x="340" y="207">Continue while elements remain</text>
</svg>
</div>
<figcaption>The underscore marks an inactive lane. Loop control advances from rack to rack, and the arithmetic works across each rack's lanes, including the tail's active lanes.</figcaption>
</figure>

A stream update is a traversal that writes its results, either to a separate
output (out of place) or back into the input (in place). An in-place update
needs rules for overlap, so stores don't replace inputs before they've been
read. In Rake, a [stack run](spec/02_packs_and_run.md#stack-runs) describes
the update on whole columns, and the compiler performs the traversal. Uniform
loop control and address calculation advance through memory, while the lane
arithmetic stays vectorised.

### Compilation and cost

| Term | Meaning |
| --- | --- |
| Intrinsic | A compiler-provided function that requests a specific instruction's semantics. |
| Autovectorisation | A compiler turning a scalar loop into vector work after checking dependencies. |
| Scalarisation | Implementing a vector operation as separate scalar work. Silent scalarisation hides a change in execution. |
| Loop unrolling / fusion | Repeating a loop body to expose independent work, or combining compatible passes over data. |
| Register pressure / spill | Demand for registers at once. A spill saves a value to memory and reloads it when registers run out. |
| ISA / microarchitecture | The instruction set, and the hardware implementing it. Processors with one ISA can perform differently. |
| Latency / throughput | The delay from input to result, and the rate of independent completed operations. |
| Bandwidth / arithmetic intensity / roofline | Bytes moved per unit time, arithmetic per byte moved, and the model comparing the two limits. A wider vector can leave a memory-bound loop unchanged. |
| ABI / calling convention | Rules for data layout, argument and result locations, and register preservation across calls. |

[ISPC's performance guide](https://ispc.github.io/perfguide.html) explains
SIMD execution and layout costs, and Rake's [backend](BACKEND.md) describes
its checked lowering.

## GPU

### Threads, warps and workgroups

On a GPU, each thread holds its own values, and a group of threads executes
lane-parallel work, so the CPU arithmetic terms above apply to GPU lane values
too. A GPU shuffle exchanges values between threads, like a CPU register
shuffle with extra participation rules.

<figure class="diagram diagram-vector-ops">
<div class="diagram-scroll" tabindex="0" role="region" aria-label="GPU thread hierarchy, scroll horizontally on a narrow screen">
<svg viewBox="0 0 680 264" role="img" aria-labelledby="vector-gpu-title vector-gpu-desc">
<title id="vector-gpu-title">A launch contains blocks, and a block contains warps</title>
<desc id="vector-gpu-desc">An illustrative CUDA grid has multiple blocks. One selected block of 64 threads contains two warps of 32 threads. Each warp has lane IDs from 0 to 31.</desc>
<rect class="diagram-desk" x="16" y="16" width="648" height="232" rx="6"/>
<text class="diagram-label" x="32" y="40">Grid / dispatch</text>
<rect class="diagram-cell" x="32" y="54" width="448" height="172" rx="4"/>
<text class="diagram-label" x="48" y="78">One block / workgroup: 64 threads in this example</text>
<rect class="diagram-cell diagram-cell-active" x="48" y="92" width="416" height="46" rx="4"/>
<text class="diagram-instruction" x="256" y="115">warp 0: thread 0 … 31, lane 0 … 31</text>
<rect class="diagram-cell diagram-cell-active" x="48" y="156" width="416" height="46" rx="4"/>
<text class="diagram-instruction" x="256" y="179">warp 1: thread 32 … 63, lane 0 … 31</text>
<rect class="diagram-cell" x="496" y="54" width="152" height="172" rx="4"/>
<text class="diagram-instruction" x="572" y="116">Other blocks</text>
<text class="diagram-instruction" x="572" y="148">…</text>
</svg>
</div>
<figcaption>A warp is a hardware execution group, while a block is a programmer-selected group with shared memory and synchronisation.</figcaption>
</figure>

| Term | Meaning |
| --- | --- |
| Driver / runtime | Software that loads programs, manages memory, submits work and may compile intermediate code. |
| Kernel / shader | A program entry run across many GPU invocations. |
| Thread / work-item / invocation | One instance of the program, with its own indices and values. GPU threads aren't operating-system threads. |
| Lane ID | A thread's position within its subgroup, 0 to 31 in an NVIDIA warp. |
| Warp | NVIDIA's group of 32 threads, scheduled together for SIMT execution. |
| Wave / wavefront | AMD's comparable group, commonly 32 or 64 wide depending on architecture and mode. |
| Subgroup | Portable API term for invocations that take part in subgroup operations, with device-dependent sizes. |
| Block / workgroup / threadgroup | A programmer-selected group of cooperating threads, in CUDA, OpenCL/Vulkan and Metal respectively. |
| Grid / dispatch / launch | The blocks or workgroups submitted to run a kernel. |
| SM / CU | NVIDIA's streaming multiprocessor or AMD's compute unit, the hardware hosting groups of threads. |
| SPMD / gang | Single program, multiple data: many program instances on different data. ISPC maps a gang of instances onto CPU SIMD lanes. |
| SIMT | Single instruction, multiple threads: GPU execution across thread lanes, masking lanes on differing paths. |
| Cooperative group / tile | An explicitly defined group that cooperates and synchronises, whose size can differ from a warp's. |

See [NVIDIA's SIMT model](https://docs.nvidia.com/cuda/cuda-programming-guide/03-advanced/advanced-kernel-programming.html#simt-execution-model),
[AMD architecture references](https://gpuopen.com/amd-gpu-architecture-programming-documentation/)
and [Vulkan subgroups](https://docs.vulkan.org/guide/latest/subgroups.html).

### Participation, control and collectives

| Term | Meaning |
| --- | --- |
| Uniform / divergent control | Every participant in a group takes the same path, or lanes take different ones. |
| Divergence / reconvergence | Lanes split onto different paths and later meet again, and masked execution spends time on paths with few active lanes. |
| Active mask | The lanes participating at a point in execution, which can differ from the intended members of a later collective. |
| Independent thread scheduling | Hardware tracking each thread's progress separately, so communication can't assume warp lockstep without explicit synchronisation. |
| Collective / subgroup operation | An exchange, vote or reduction among threads. Every required participant needs to reach it with compatible membership and operands. |
| Warp shuffle | Reading another participating lane's value without a round trip through shared memory. |
| Shuffle up / down / XOR | Reading from a lower or higher lane index, or a lane whose ID differs by an XOR mask. |
| Broadcast / read-first-lane | Sharing one participating lane's value with the group. |
| Ballot | One predicate bit per participating lane, collected into a bitset, like a CPU movemask. |
| Vote / any / all | Whether some or all participating threads satisfy a predicate. |
| Subgroup reduction / scan | Combining values or producing prefixes across a group, which needs rules for order and inactive inputs. |
| Barrier | A rendezvous at a given scope, where every specified participant needs to arrive. A warp barrier can't synchronise other warps. |
| Memory fence / acquire / release | Ordering memory visibility. Waiting for other threads needs a separate operation, such as a barrier. |
| Atomic / CAS | An indivisible read-modify-write, such as compare-and-swap, with a memory order and scope. Contention can serialise it. |
| Scope | The threads covered by an operation: subgroup, workgroup, device or system. |

The [PTX instruction reference](https://docs.nvidia.com/cuda/parallel-thread-execution/index.html#data-movement-and-conversion-instructions-shfl-sync)
specifies shuffle membership, and NVIDIA's [synchronisation guide](https://docs.nvidia.com/cuda/cuda-programming-guide/03-advanced/advanced-kernel-programming.html#advanced-synchronization-primitives)
defines barriers, scopes and ordered communication.

### Memory movement and matrix operations

| Term | Meaning |
| --- | --- |
| Global / device memory | Device-wide memory, usually GPU DRAM behind caches. |
| Shared / workgroup memory | Programmer-managed storage shared within a block, with capacity, bank and synchronisation limits. |
| Local / private memory | Thread-private storage. CUDA “local memory” can live in device memory and holds spills, whereas OpenCL “local” means workgroup-shared. |
| Coalescing | Combining nearby lanes' requests, including gathers and scatters, into fewer memory transactions. Alignment, element size and the address pattern decide how many. |
| Bank conflict | Shared memory is split into banks, and different addresses in one bank take extra steps. |
| Padding / tiling | Changing a layout or processing blocks to improve locality, coalescing or bank use. |
| CUDA stream / command queue | An ordered queue of submitted work, such as transfers and kernel launches, distinct from a data stream. |
| Tensor core / MMA / fragment | Matrix hardware and its warp-level multiply-accumulate interface, with each participant holding a fragment of the matrix in an often architecture-specific layout. |

[CUDA memory guidance](https://docs.nvidia.com/cuda/cuda-c-best-practices-guide/index.html#memory-optimizations)
explains coalescing and bank conflicts, and [CUDA matrix operations](https://docs.nvidia.com/cuda/cuda-programming-guide/05-appendices/cpp-language-extensions.html#warp-matrix-functions)
have their own participation and layout requirements.

### Resources, performance and compiled artifacts

<figure class="diagram diagram-vector-ops">
<div class="diagram-scroll" tabindex="0" role="region" aria-label="GPU participation and occupancy, scroll horizontally on a narrow screen">
<svg viewBox="0 0 680 172" role="img" aria-labelledby="vector-cost-title vector-cost-desc">
<title id="vector-cost-title">Resident warps and active lanes measure different things</title>
<desc id="vector-cost-desc">Occupancy compares resident warps with supported resident capacity. Lane utilisation compares participating lanes while an operation executes. A resident warp can execute with only some lanes active.</desc>
<rect class="diagram-cell" x="16" y="16" width="310" height="136" rx="4"/>
<text class="diagram-label" x="32" y="40">Occupancy</text>
<text class="diagram-instruction" x="171" y="78">resident warps</text>
<path class="diagram-flow" d="M66 93 H276"/>
<text class="diagram-instruction" x="171" y="116">resident warp capacity</text>
<rect class="diagram-cell" x="350" y="16" width="314" height="136" rx="4"/>
<text class="diagram-label" x="366" y="40">Lane utilisation at an instruction</text>
<text class="diagram-instruction" x="507" y="78">participating lanes</text>
<path class="diagram-flow" d="M402 93 H612"/>
<text class="diagram-instruction" x="507" y="116">available lanes in the group</text>
</svg>
</div>
<figcaption>High occupancy can coexist with low lane utilisation.</figcaption>
</figure>

| Term | Meaning |
| --- | --- |
| Occupancy | Resident warps relative to capacity, limited by registers and shared memory, either in theory for a launch or as achieved during execution. |
| Lane utilisation | The share of lanes doing useful work. |
| Register pressure / spill | On a GPU, spilled values go to device-backed local memory. Spill checks inspect memory instructions and data flow as well as resource reports. |
| Latency hiding | Running other warps while some wait, which needs enough eligible work. |
| Serial lane emulation | One thread looping over elements that were meant to run across lanes. |
| FLOPS | Floating-point operations per second. Specifications give peak rates, and measurements give achieved ones. |
| Launch / transfer overhead | The cost of submitting kernels and moving data, which can dominate tiny workloads. |
| PTX / virtual ISA | NVIDIA's intermediate instruction language, lowered to hardware by NVIDIA's toolchain. |
| SASS / cubin | NVIDIA's physical instruction assembly, and the compiled device file holding code and metadata. |
| ptxas / AOT / JIT | NVIDIA's assembler, and compiling ahead of time or while loading. |
| SPIR-V / Vulkan / OpenCL / Metal / HIP | A portable intermediate representation and the graphics and compute interfaces, each with its own execution, memory and compilation rules. |
| Disassembly / resource report | Decoded instructions, and counts such as registers or local memory. |
| Artifact verification | Checking properties of exact executable bytes for one architecture and toolchain, which don't carry over to a rebuild. |

[CUDA's resource discussion](https://docs.nvidia.com/cuda/cuda-programming-guide/02-basics/writing-cuda-kernels.html#registers)
and [binary utilities](https://docs.nvidia.com/cuda/cuda-binary-utilities/)
cover registers, occupancy and artifact inspection. Rake's proposed GPU
profiles check lane mapping and designated register and memory properties.
