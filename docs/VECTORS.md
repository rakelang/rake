# Vectors cheat sheet

A vector operation does the same work on several values at once. This page
explains the vocabulary used to describe that work, starting with CPU
registers and then GPU threads. Use your browser's find command to look up a
term. The examples use four lanes so you can follow every value.

[CPU](#cpu) · [GPU](#gpu)

These are hardware and programming terms, rather than a list of available
Rake functions. [Primitives, operations, and targets](spec/01_primitives_operations_and_targets.md)
lists implemented support. Rake's [GPU profiles](GPU.md) are currently a
design. The [language glossary](GLOSSARY.md) explains Rake's own terminology.

## CPU

### Values, lanes and registers

Think of a vector register as a row of cells. Each cell holds one element,
and an instruction can operate on the whole row. A 256-bit register holds
eight 32-bit floats, sixteen 16-bit integers or thirty-two 8-bit integers.
Element width and register width are different quantities.

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
<figcaption>Arithmetic changes values. Broadcast duplicates one value. Shuffle changes which lane supplies each result.</figcaption>
</figure>

| Term | Meaning |
| --- | --- |
| Scalar | One value, such as a single float. Scalar execution processes one element per operation. |
| f32 / FP32 / binary32 | A 32-bit IEEE 754 floating-point value, normally C's `float`. `f64` / FP64 uses 64 bits. Integer element types specify signedness and bit width. |
| Vector / packed value | Several elements held together in a register for parallel operations. Rake uses `pack` separately for a record declaration. |
| Element / lane | An element is a stored value. A lane is its position within a vector operation. Some instruction manuals also use “lane” for a larger sub-register, so check the instruction's granularity. |
| SIMD | Single instruction, multiple data: one instruction operates on multiple elements. |
| Vector width / element width | The register's bit capacity and the bits per element. Their ratio gives the element count for a fixed-width vector. |
| Vector register / register file | Fast processor storage for a vector, and the collection of registers available to execution. |
| Uniform / varying | A uniform has the same value across lanes. A varying value can differ by lane. A uniform may be computed at runtime. |
| Fixed-width / scalable vector | Fixed-width code uses a specified register size. Scalable-vector code can adapt its active element count to the machine. |
| VLA / vector-length agnostic | Code written without assuming one hardware vector length. A loop can process the available number of elements at each step. |
| Vector length / VL | The current active element count, especially in scalable architectures. It can be smaller than the register's maximum capacity. |
| SWAR | SIMD within a register: treating a scalar word as several smaller fields and operating on them with bit tricks. |
| SSE / SSE2 / XMM | x86 instruction families with 128-bit XMM registers. SSE2 adds, among other operations, packed integer and double-precision operations. |
| AVX / AVX2 / YMM | x86 families using 256-bit YMM vectors as well as narrower forms. AVX2 extends packed integer operations and adds gathers. |
| AVX-512 / ZMM / opmask | x86 extensions with 512-bit ZMM vectors and dedicated mask registers. Individual extensions support different element types and operations. |
| NEON / Advanced SIMD | Arm's fixed-width SIMD, including 128-bit vectors on AArch64. |
| SVE / SVE2 | Arm scalable vector extensions. Software can use predicates and write vector-length-agnostic loops. |
| RVV / VLEN / SEW / LMUL | RISC-V vectors, hardware register length, selected element width, and register grouping multiplier. LMUL can group registers for one logical vector. |
| WebAssembly SIMD / v128 | A virtual 128-bit vector and its operations. The runtime performs physical instruction selection and register allocation. |

Architecture references: [Intel intrinsics](https://www.intel.com/content/www/us/en/docs/intrinsics-guide/index.html),
[Arm Advanced SIMD](https://arm-software.github.io/acle/neon_intrinsics/advsimd.html),
[Arm scalable vectors](https://arm-software.github.io/acle/main/acle.html#sve-language-extensions),
[RISC-V vectors](https://docs.riscv.org/reference/isa/unpriv/v-st-ext.html)
and [WebAssembly vector instructions](https://webassembly.github.io/spec/core/syntax/instructions.html#vector-instructions).

### Moving values between lanes

A shuffle reads values already in registers. A gather reads values from
memory. Both use indices, but their storage, latency and memory effects differ.

| Term | Meaning and example |
| --- | --- |
| Broadcast / splat | Replicate one value: `7 → [7,7,7,7]`. Usually synonyms. Broadcast can read a scalar from memory or one register lane. |
| Shuffle / permute | Select and reorder source lanes, possibly repeating them: `[a,b,c,d]` with `[2,0,3,1]` gives `[c,a,d,b]`. Instructions differ in index freedom and source count. |
| Swizzle / table lookup | Indexed lane selection, often from one source vector or a small register table. “Swizzle” is common in shader and WebAssembly terminology. |
| Static / dynamic shuffle | Static indices are known at compilation. Dynamic indices are values computed at runtime. Support and cost can differ. |
| Zip / interleave | Alternate elements from two vectors: `[a,b]` and `[x,y]` become `[a,x,b,y]`. |
| Unpack | Instruction-set terminology for interleaving lanes or widening packed values. Check which meaning and source halves an instruction uses. |
| Unzip / deinterleave | Separate alternating elements: `[a,x,b,y]` becomes `[a,b]` and `[x,y]`. |
| Transpose | Exchange row and column positions. A matrix of vectors can become vectors of corresponding fields. |
| Reverse | Reverse lane order: `[a,b,c,d] → [d,c,b,a]`. Byte reversal within each element is a different operation. |
| Slide / shift lanes / align | Move whole elements or bytes across positions, with defined fill or a second source. This differs from shifting bits inside each element. |
| Rotate lanes | Move lanes cyclically: `[a,b,c,d] → [d,a,b,c]`. A bit rotation stays inside an element. |
| Extract / insert | Read one lane as a scalar, or replace one lane with a scalar. Extraction can introduce a vector-to-scalar dependency. |
| Concatenate / split | Join vector pieces or divide a vector into pieces. The result may occupy multiple physical registers. |
| Compress / compact | Pack selected lanes toward the start: `[a,b,c,d]` under `[1,0,1,0]` gives `[a,c,…]`. The remaining lanes have instruction-specific contents. |
| Expand | Place dense values in selected positions: `[a,c]` under `[1,0,1,0]` gives `[a,fill,c,fill]`. |
| Lane-local / cross-lane | Lane-local work depends only on corresponding inputs. Cross-lane work exchanges or combines elements. Some instructions restrict exchange to 128-bit sub-vectors. |

The [GCC vector reference](https://gcc.gnu.org/onlinedocs/gcc/Vector-Extensions.html)
illustrates shuffle selection and conversion. Intel and Arm use different
operation spellings, so consult the instruction's element and sub-vector rules.

### Masks and selection

| Term | Meaning |
| --- | --- |
| Comparison | Compare corresponding elements and produce a mask, such as `[1,4,2,9] > 3 → [0,1,0,1]`. |
| Mask / predicate | A true/false choice per lane. Its representation may be vector bits or a dedicated predicate register. |
| Active / inactive lane | A lane included or excluded by the operation's mask. Suppression of computation and memory access depends on the instruction and profile. |
| Predication | Execute under a predicate. The instruction defines whether inactive lanes suppress work, retain old values or produce a fill value. |
| Select / blend | Choose one of two values per lane: mask `[1,0,1,0]` selects `[a,y,c,w]` from `[a,b,c,d]` and `[x,y,z,w]`. |
| Merge masking / zero masking | Inactive lanes preserve a supplied or previous value, or become zero. These are different result policies. |
| Any / all / none | Reduce a mask to one truth value: at least one lane, every lane, or no lanes satisfy it. |
| Movemask / bitmask | Collect specified lane bits into a scalar bitset. An x86 movemask often extracts sign bits, rather than testing arbitrary nonzero values. |
| Population count / popcount | Count set bits. Applied to a lane mask, it counts selected lanes. |
| First / last set bit | Locate a selected lane in a mask. The result for an empty mask requires a specified convention. |
| Masked load / masked store | Memory operations restricted to selected lanes. Fault suppression and inactive results depend on the instruction. |
| Fault suppression / first-fault | Suppression prevents some inactive accesses from faulting. First-fault loads, on supporting architectures, record how far a load succeeded. Neither makes arbitrary invalid pointers safe. |
| Speculation / safe operands | A compiler may calculate both candidates before selecting. Replacing invalid inactive inputs with safe ones can prevent unwanted arithmetic exceptions. |
| Partial operation | An operation valid for only part of its input domain, such as real square root for non-negative values. Safe evaluation requires suppressed arithmetic or benign operands in inactive lanes. |

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
<figcaption>A reduction produces one combined value. A scan retains each partial result.</figcaption>
</figure>

| Term | Meaning |
| --- | --- |
| Element-wise / vertical operation | Apply an operation independently at corresponding lane positions, such as vector addition. |
| Horizontal operation / reduction | Combine lanes into fewer results, such as a sum, minimum or maximum. |
| Pairwise operation | Combine adjacent pairs. Pairwise adds of `[a,b,c,d]` produce the two results `a+b` and `c+d`. |
| Scan / prefix sum | Produce running partial results. Inclusive includes the current element. Exclusive starts with an identity and excludes the current element. |
| Segmented reduction / scan | Combine values within separately marked groups, restarting at each segment boundary. |
| Dot product | Multiply corresponding elements, then sum those products. The instruction or algorithm specifies accumulation width and rounding. |
| FMA / fused multiply-add | Calculate `a*b+c` with one final rounding, which can differ from separate multiply and add. |
| Multiply-accumulate / MAC | Multiply and add into an accumulator. The selected instruction determines whether the operations round separately or once as an FMA. |
| Saturating arithmetic | Clamp an overflowing integer to its representable limit, such as unsigned 8-bit `250+10 → 255`. |
| Wrapping / modular arithmetic | Keep the result modulo the integer width: unsigned 8-bit `250+10 → 4`. |
| Widen / narrow | Convert to a wider or narrower element type. Narrowing needs a rule for rounding, truncation, saturation or overflow. |
| Sign extend / zero extend | Widen signed integers by copying the sign bit, or unsigned integers by filling upper bits with zero. |
| Numeric conversion / bitcast | Conversion changes representation to preserve a numerical value where possible. Bitcast reinterprets the same bits as another type. |
| Packed arithmetic / packed conversion | Operate on several elements together. “Pack” in some integer instruction sets specifically means narrowing and joining values. |
| Bitwise AND / OR / XOR / NOT | Operate on individual bits inside each element. A Boolean lane mask is a separate interpretation. |
| Logical / arithmetic shift | Shift bits inside each element. A logical shift fills with zero, while arithmetic right shift repeats the sign bit. |
| Bit rotate / bit reverse | Wrap displaced bits to the other end, or reverse their order. Neither rearranges whole vector lanes. |
| CLZ / CTZ / bit count | Count leading zeros, trailing zeros or set bits within an element. Zero-input behaviour is instruction-specific. |
| Absolute difference / SAD | Calculate the distance between corresponding values. Sum of absolute differences adds those distances, often for image matching. |
| Reciprocal / reciprocal square root | Calculate `1/x` or `1/sqrt(x)`. Estimate instructions offer limited accuracy, sometimes followed by refinement steps. |
| Transcendental / elementary math | Functions such as `sin`, `exp` and `log`. A vector implementation may require a polynomial or library sequence rather than one instruction. |
| Ordered / unordered comparison | An ordered floating comparison requires non-NaN operands. An unordered comparison can report the presence of NaN. Read the exact operator's NaN rule. |
| NaN / infinity / signed zero | Special floating-point values. Their comparison, minimum/maximum and arithmetic rules affect reproducibility. |
| Subnormal / FTZ / DAZ | A subnormal represents a very small value. Flush-to-zero discards subnormal results. Denormals-are-zero treats subnormal inputs as zero where supported. |
| Rounding / ULP / fast math | Rounding chooses a representable result. An ULP measures its representable spacing. Fast-math settings permit specific departures from strict numerical rules. |
| Reassociation | Change grouping, such as `(a+b)+c` to `a+(b+c)`. Floating-point results can change, including in tree reductions. |

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
<figcaption>A contiguous load reads neighbouring elements. Gather and scatter use one address per lane.</figcaption>
</figure>

| Term | Meaning |
| --- | --- |
| Load / store | Transfer data from memory into registers, or from registers into memory. |
| Contiguous / unit-stride | Neighbouring lanes access neighbouring elements: indices `[0,1,2,3]`. |
| Strided access | A constant gap separates elements: indices `[0,2,4,6]`. |
| Gather | Load through an address or index per lane: `out[i] = memory[index[i]]`. |
| Scatter | Store through an address or index per lane: `memory[index[i]] = value[i]`. Duplicate destinations require a defined conflict policy. |
| Indexed / segmented load | Indexed loads use separate offsets. Segmented loads read several fields of interleaved records into separate vectors on supporting ISAs. |
| Alignment / unaligned access | Alignment constrains an address to a multiple of a byte boundary. Unaligned support, legality and cost depend on the instruction and crossed boundaries. |
| Cache line / locality | A cache transfers a block of nearby bytes. Temporal locality reuses data, while spatial locality uses nearby data. |
| AoS / array of structures | Consecutive complete records: `x0,y0,x1,y1,…`. |
| SoA / structure of arrays | Separate field columns: `x0,x1,…` and `y0,y1,…`. Rake's stack uses this layout. |
| AoSoA / tiled layout | Small SoA blocks stored as an array. A tile can group a vector's worth of records. |
| Prefetch | Request data before its use. It is a latency hint whose effectiveness depends on the access pattern. |
| Streaming / non-temporal store | A store with cache-policy hints intended for data with little expected reuse. Alignment and ordering requirements still apply. |
| Aliasing / overlap | Different pointers may refer to the same memory. A vectorised loop needs valid rules for overlapping reads and writes. |
| Tail / remainder | The final incomplete vector when division by the lane count leaves a remainder. Masking or a separately specified cleanup handles it. |
| Strip mining / chunking | Divide a longer loop into vector-sized chunks, then handle the remainder. |

### Data streams and traversal

A data stream is a sequence of elements to process, such as a column with a
million floats. A stream traversal walks along that sequence one rack at a
time. It loads the next rack, calculates the result, stores it and advances
to the next group of elements. The sequence can be any length, so the final
rack may have fewer active lanes.

<figure class="diagram diagram-vector-ops">
<div class="diagram-scroll" tabindex="0" role="region" aria-label="Stream traversal, scroll horizontally on a narrow screen">
<svg viewBox="0 0 680 254" role="img" aria-labelledby="vector-stream-title vector-stream-desc">
<title id="vector-stream-title">A traversal processes a stream one rack at a time</title>
<desc id="vector-stream-desc">Eleven f32 elements on SSE2 form two full four-lane racks and a tail with three active lanes. The element indices are 0 through 3, 4 through 7, and 8 through 10. For each rack, the traversal loads its elements, calculates a vector result, stores the active results and advances to the next rack.</desc>
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
<figcaption>The underscore marks an inactive lane. Loop control advances between racks. The arithmetic within each rack operates across its lanes, including the active lanes of the tail.</figcaption>
</figure>

A stream update transforms successive elements and writes the results.
Writing into a separate output array is an out-of-place update. Writing back
into the input array is an in-place update, which needs an overlap contract
so stores don't replace inputs before they have been read.

| Term | Meaning |
| --- | --- |
| Data stream | Successive data elements or records, stored in memory or arriving from a file or network. |
| Stream traversal | A pass over successive chunks of a sequence. A SIMD traversal processes each chunk as a rack, with a defined policy for the tail. |
| Stream update | A traversal that writes transformed values, either to a separate output or back into the input. Traversals can also inspect or combine data without updating it. |
| In-place / out-of-place update | Store into the input's storage, or into separate output storage. In-place vector work needs explicit rules for overlapping inputs and outputs. |

Traversal and update describe a whole pass over data, rather than one SIMD
instruction. In Rake, a [run](spec/02_packs_and_run.md#traversals) performs the
traversal and applies rack expressions to its columns. Uniform loop control
and address calculation advance through memory while the lane arithmetic
stays vectorised. Traversal alone doesn't request non-temporal stores or
guarantee a particular cache policy.

### Compilation and cost

| Term | Meaning |
| --- | --- |
| Intrinsic | A compiler-provided operation that requests specific instruction semantics. It can still expand into several instructions. |
| Autovectorisation / loop vectorisation | A compiler turns a scalar loop into vector work after checking dependencies and legality. |
| SLP vectorisation | Superword-level parallelism: group independent scalar expressions into vector operations, even outside a loop. |
| Scalarisation / scalar fallback | Implement a vector operation as separate scalar work. A fallback can be explicit, while silent scalarisation hides a change in execution. |
| Loop unrolling / fusion | Unrolling repeats a loop body to expose independent work. Loop fusion combines compatible passes over data. |
| Register pressure / live range | Pressure is the simultaneous demand for registers. A live range lasts while a value can still be used. |
| Spill / reload | Save a register value to memory and load it back later, usually because registers are insufficient. |
| ISA / microarchitecture | The instruction-set interface and the hardware implementation beneath it. Processors with the same ISA can have different performance. |
| Latency / throughput | Latency is the delay from input to result. Throughput is the rate of independent completed operations. |
| Bandwidth / arithmetic intensity | Bytes transferred per unit time, and arithmetic work per byte transferred. A wider vector may leave a memory-bound loop unchanged. |
| Roofline / compute-bound / memory-bound | A performance model compares arithmetic limits with memory bandwidth. The limiting resource depends on the workload. |
| Dispatch / multiversioning | Select among implementations for supported ISA features. Measurements establish which variant is fastest for a workload. |
| ABI / calling convention | Rules for data layout, argument and result locations, register preservation and calls between compiled functions. |

[ISPC's performance guide](https://ispc.github.io/perfguide.html) explains
SIMD execution and layout costs. Rake's [backend](BACKEND.md) describes its
checked lowering. Timings, cache behaviour and sustained throughput still
require measurement on the target machine.

## GPU

### Threads, warps and workgroups

On a GPU, each thread holds its own values, and a group of threads executes
lane-parallel work. A GPU shuffle exchanges those thread values. It is the
counterpart of a CPU register shuffle, with additional participation rules.
The CPU arithmetic terms above also apply to GPU lane values.

<figure class="diagram diagram-vector-ops">
<div class="diagram-scroll" tabindex="0" role="region" aria-label="GPU thread hierarchy, scroll horizontally on a narrow screen">
<svg viewBox="0 0 680 264" role="img" aria-labelledby="vector-gpu-title vector-gpu-desc">
<title id="vector-gpu-title">A launch contains blocks, and a block contains warps</title>
<desc id="vector-gpu-desc">An illustrative CUDA grid has multiple blocks. One selected block of 64 threads contains two warps of 32 threads. Each warp has lane IDs from 0 to 31. Other block sizes are possible.</desc>
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
<figcaption>A warp is a hardware execution grouping. A block is a programmer-selected group with shared-memory and synchronisation facilities.</figcaption>
</figure>

| Term | Meaning |
| --- | --- |
| Host / device | The CPU-side application and the GPU executing its submitted work. |
| Driver / runtime | Software for device access, program loading, memory management and submission. It may compile intermediate code. Hardware schedules runnable warps. |
| Kernel / shader | A program entry executed across many GPU invocations. A compute shader performs general calculation through a graphics API. |
| Thread / work-item / invocation | One instance of the program, with its own indices and values. GPU threads differ from operating-system threads. |
| Lane / lane ID | A thread's position within its subgroup. NVIDIA warp lane IDs run from 0 to 31. |
| Warp | NVIDIA's grouping of 32 GPU threads for SIMT execution, scheduled together by the hardware. |
| Wave / wavefront | AMD terminology for a comparable execution group. Width depends on architecture and mode, commonly 32 or 64. |
| Subgroup | Portable API terminology for invocations that participate in subgroup operations. Supported sizes and operations are device-dependent. |
| Block / workgroup / threadgroup | A programmer-selected collection of threads with group-scoped cooperation. These terms come from CUDA, OpenCL/Vulkan and Metal respectively. |
| Grid / dispatch / launch | The collection of blocks or workgroups submitted to execute a kernel. |
| SM / CU | NVIDIA streaming multiprocessor or AMD compute unit: a vendor-specific execution resource hosting groups of threads. Each architecture defines its hardware organization. |
| SPMD | Single program, multiple data: many program instances process different data. ISPC applies this model to CPU SIMD gangs too. |
| SIMT | Single instruction, multiple threads: GPU execution across thread lanes, with masking for differing paths. |
| Per-thread vector / vector load | Several components held or transferred by one thread, such as a CUDA `float4`. Warp-level parallelism comes from executing multiple threads. |
| Gang | An SPMD group, such as ISPC's program instances mapped to SIMD lanes. |
| Cooperative group | A programming abstraction for an explicitly defined group that cooperates and synchronises. Its scope can differ from one warp. |
| Tile / subgroup partition | A subdivision used for data or cooperation. Its logical size can differ from the hardware warp size. |
| Warp specialisation | Different warps take different roles, such as loading tiles or calculating results. Their handoff needs synchronisation. |

See [NVIDIA's SIMT model](https://docs.nvidia.com/cuda/cuda-programming-guide/03-advanced/advanced-kernel-programming.html#simt-execution-model),
[AMD architecture references](https://gpuopen.com/amd-gpu-architecture-programming-documentation/)
and [Vulkan subgroups](https://docs.vulkan.org/guide/latest/subgroups.html).

### Participation, control and collectives

| Term | Meaning |
| --- | --- |
| Uniform control / divergent control | All participants choose the same path, or different lanes choose different paths. Uniformity is relative to a group. |
| Divergence / reconvergence | Lanes take different paths, then meet again at a common point. Masked execution can spend time on paths with few active lanes. |
| Active mask / execution mask | The lanes participating at a point in execution. An instantaneous active mask may differ from the intended membership of a later collective. |
| Predication | Enable an instruction's effects according to a per-thread predicate. Masked instructions and divergent branches have different costs. |
| Warp scheduler / issue | Hardware chooses runnable warp instructions to issue. Source code controls the mapping of work onto lanes. |
| Independent thread scheduling | Hardware can track thread progress more independently. Assuming implicit warp lockstep is unsafe for communication without the specified synchronisation. |
| Collective / subgroup operation | Threads cooperate in an exchange, vote or reduction. Required participants reach the operation with compatible membership and operands. |
| Warp shuffle / subgroup shuffle | Read a value held by another participating lane, without a general shared-memory round trip. The operation requires a valid source lane and participation mask. |
| Shuffle up / down / XOR | Select a neighbour at a lower or higher lane index, or a lane whose ID differs by an XOR mask. Boundaries and subgroup width matter. |
| Broadcast / read-first-lane | Share a selected participating lane's value with the group. Read-first selects according to the API's active-lane rules. |
| Ballot | Collect one predicate bit per participating lane into a bitset. This is related to CPU movemask, with thread participation semantics. |
| Vote / any / all | Ask whether some or all participating threads satisfy a predicate. The participating set matters. |
| Match / elect / leader | Match groups lanes with equal values. Elect chooses one participating lane to perform group work. |
| Subgroup reduction / scan | Combine thread values or produce prefix results within a participating group. Numerical order and inactive inputs require defined rules. |
| Barrier | A rendezvous at a specified scope, with the API's memory-ordering guarantees. Correct execution requires all specified participants to reach it. |
| Warp synchronisation / block synchronisation | Coordinate a subgroup or a whole block. A warp barrier cannot synchronise other warps. |
| Memory fence / acquire / release | Order memory visibility. Thread rendezvous requires a separate synchronization operation, such as a barrier. |
| Atomic / read-modify-write / CAS | An indivisible memory operation, such as increment or compare-and-swap, with specified memory order and scope. Contention can serialise accesses. |
| Scope | The threads or agents covered by an operation's visibility or synchronisation, such as subgroup, workgroup, device or system. |
| Race / deadlock | A race involves conflicting unsynchronised accesses. Deadlock leaves participants waiting without possible progress. |

The [PTX instruction reference](https://docs.nvidia.com/cuda/parallel-thread-execution/index.html#data-movement-and-conversion-instructions-shfl-sync)
specifies shuffle membership. NVIDIA's [synchronisation guide](https://docs.nvidia.com/cuda/cuda-programming-guide/03-advanced/advanced-kernel-programming.html#advanced-synchronization-primitives)
defines barriers, scopes and ordered communication.

### Memory movement and matrix operations

| Term | Meaning |
| --- | --- |
| Global / device memory | Device-wide memory, typically backed by GPU DRAM and accessed through caches. |
| Shared memory / workgroup memory | Programmer-managed storage shared within a block or workgroup. It has capacity, bank and synchronisation constraints. |
| Local memory / private memory | Thread-private storage. CUDA “local memory” can reside in device memory, including spilled values. OpenCL “local” instead means workgroup-shared memory. |
| Registers | Storage for thread values. Register allocation and resource limits affect how many groups can remain resident. |
| Constant / read-only memory | Storage or access paths intended for read-only data, with architecture-specific caching and broadcast behaviour. |
| Texture / image access | An API and hardware path for indexed spatial data, sometimes with filtering or specialised cache behaviour. |
| Coalescing / coalesced access | Combine nearby lane memory requests into transactions. Alignment, element size and the address pattern determine the transactions. |
| Memory transaction / sector | A hardware transfer unit for memory requests. Its size and the access pattern determine how lane requests combine into transactions. |
| Gather / scatter | Each lane loads or stores an indexed address. These can be coalesced when the resulting addresses are close enough. |
| Bank / bank conflict | Shared memory is partitioned into banks. Different addresses in the same bank can force extra service steps. Same-address broadcasts have separate rules. |
| Padding / tiling / transpose | Change a layout or process blocks of data to improve locality, coalescing or bank use. The improvement depends on the actual mapping. |
| Async copy / double buffering | Start a transfer and overlap useful calculation. Alternating buffers let loading and processing advance separately, with completion synchronisation. |
| Unified memory / migration | A managed address space with data placement or movement handled by the runtime. Access costs include any required migration and transfer. |
| Pinned memory / DMA | Host memory fixed for device transfers, and direct memory access. Transfer time depends on the interconnect, byte count and access pattern. |
| CUDA stream / command queue | An ordered sequence of submitted operations, such as transfers and kernel launches. This is a queue of work, distinct from a data stream. Dependencies and available device resources determine overlap between queues. |
| Event | A completion marker used to observe progress or establish dependencies between submitted operations. |
| Tensor core / matrix engine | Hardware for supported matrix operations and precisions. It has a different data and execution contract from ordinary lane arithmetic. |
| MMA / WMMA / matrix fragment | Matrix multiply-accumulate, a warp-level interface, and the distributed piece of a matrix held by participants. Fragment layout can be opaque or architecture-specific. |

[CUDA memory guidance](https://docs.nvidia.com/cuda/cuda-c-best-practices-guide/index.html#memory-optimizations)
explains coalescing and bank conflicts. [CUDA matrix operations](https://docs.nvidia.com/cuda/cuda-programming-guide/05-appendices/cpp-language-extensions.html#warp-matrix-functions)
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
<figcaption>High occupancy can coexist with low lane utilisation. Neither quantity alone establishes elapsed time.</figcaption>
</figure>

| Term | Meaning |
| --- | --- |
| Occupancy / residency | Resident warps relative to supported capacity, and the groups currently kept on an execution unit. Registers and shared memory can limit residency. |
| Theoretical / achieved occupancy | A resource-based limit for a launch, and occupancy observed during execution. Inputs and scheduling affect the observed value. |
| Utilisation / active-lane efficiency | How much execution capacity performs useful work. Lane participation and overall device utilisation are separate measurements. |
| Register pressure / spill | Demand for per-thread registers and movement of values to device-backed local storage when necessary. Spill checks inspect memory instructions and data flow as well as stack and local-storage reports. |
| Latency hiding | Run independent warps while others wait for memory or dependencies. It requires enough eligible work. |
| Load balancing / work distribution | Spread work so groups finish at similar times. Divergence and unequal task sizes can both cause imbalance. |
| Grid-stride loop / persistent kernel | A thread revisits elements separated by the grid size, or a long-lived kernel consumes successive work. These can preserve parallel lane mapping. |
| Serial lane emulation | One thread loops over elements that were meant to execute across lanes. This differs from a grid-stride loop with simultaneous work in all threads. |
| Throughput / FLOPS / bandwidth | Completed work per time, floating operations per second and bytes transferred per second. Device specifications give peak rates, and application measurements give achieved rates. |
| GPU compute / GPGPU | General-purpose calculation on a graphics processor, using compute kernels rather than requiring graphics rendering. |
| Arithmetic intensity / roofline | Work per transferred byte, and a model relating bandwidth and arithmetic ceilings. Launch and host-transfer costs can matter separately. |
| Launch overhead / transfer overhead | Costs of submitting kernels and moving data. Tiny workloads can spend more time here than calculating. |
| PTX / virtual ISA | NVIDIA's intermediate instruction language. NVIDIA's toolchain performs final physical lowering. |
| SASS / cubin | NVIDIA physical instruction assembly and a compiled device artifact containing executable code and metadata. |
| ptxas / AOT / JIT | NVIDIA's assembler/compiler, ahead-of-time compilation before loading, and just-in-time compilation during loading or execution. |
| SPIR-V / Vulkan / OpenCL / Metal / HIP | A portable intermediate representation, and graphics or compute interfaces/toolchains. Each has its own execution, memory and compilation rules. |
| Disassembly / resource report | Inspect decoded instructions and quantities such as registers or local memory. Reports support checking, while neither establishes every control-flow or spill property alone. |
| Artifact verification | Check claimed properties of exact executable bytes for a specified architecture and toolchain. A certificate for one artifact cannot be transferred to a different rebuild. |

[CUDA's resource discussion](https://docs.nvidia.com/cuda/cuda-programming-guide/02-basics/writing-cuda-kernels.html#registers)
and [binary utilities](https://docs.nvidia.com/cuda/cuda-binary-utilities/)
cover registers, occupancy and artifact inspection. Rake's proposed contract
checks lane mapping and designated register and memory properties. Kernel
speed, achieved occupancy and physical memory traffic still need measurement.
