# GPU profiles

Rake doesn't have a GPU compiler, runtime or device-artifact verifier yet,
because CPU coverage and native C interoperation come first. In this design,
the hardware schedules warps while Rake controls the algorithm's lane
mapping, keeps temporaries in registers where the profile requires it, and
makes memory and synchronisation costs explicit. The first backend will
target NVIDIA PTX and verify an ahead-of-time cubin.

<figure class="diagram diagram-gpu-rack">
<div class="diagram-scroll" tabindex="0" role="region" aria-label="GPU rack diagram, scroll horizontally on a narrow screen">
<svg viewBox="0 0 680 264" role="img" aria-labelledby="gpu-rack-title gpu-rack-description">
<title id="gpu-rack-title">A GPU rack spans a warp</title>
<desc id="gpu-rack-description">A column maps to 32 thread lanes, and a mask disables selected lanes. Hardware schedules the warp, while Rake defines and verifies the lane mapping.</desc>
<text class="diagram-label" x="18" y="24">Proposed NVIDIA rack: 32 thread lanes</text>
<rect class="diagram-cell diagram-cell-active" x="18" y="40" width="644" height="34" rx="4"/>
<text class="diagram-value" x="340" y="57">Column in memory: values 0 … 31</text>
<path class="diagram-flow" d="M68 80 V104 M176 80 V104 M284 80 V104 M392 80 V104 M500 80 V104 M610 80 V104"/>
<rect class="diagram-cell diagram-cell-active" x="18" y="110" width="100" height="40" rx="4"/>
<rect class="diagram-cell diagram-cell-idle" x="126" y="110" width="100" height="40" rx="4"/>
<rect class="diagram-cell diagram-cell-active" x="234" y="110" width="100" height="40" rx="4"/>
<rect class="diagram-cell diagram-cell-active" x="342" y="110" width="100" height="40" rx="4"/>
<rect class="diagram-cell diagram-cell-idle" x="450" y="110" width="100" height="40" rx="4"/>
<rect class="diagram-cell diagram-cell-active" x="558" y="110" width="104" height="40" rx="4"/>
<text class="diagram-value" x="68" y="130">lane 0</text>
<text class="diagram-value" x="176" y="130">lane 1</text>
<text class="diagram-value" x="284" y="130">lane 2</text>
<text class="diagram-value" x="392" y="130">…</text>
<text class="diagram-value" x="500" y="130">lane 30</text>
<text class="diagram-value" x="610" y="130">lane 31</text>
<rect class="diagram-operation" x="18" y="178" width="644" height="36" rx="4"/>
<text class="diagram-instruction" x="340" y="196">The operation runs in each participating lane.</text>
<text class="diagram-label" x="18" y="249">Rake checks the mapping. Hardware schedules the warp.</text>
</svg>
</div>
<figcaption>One rack spans a warp. Grey lanes illustrate a programmer-selected mask.</figcaption>
</figure>

## Racks and lanes

A CPU rack occupies one vector register, whereas a GPU rack will span a
specified warp, wave or subgroup, with each invocation holding one lane's
value, as in NVIDIA's
[SIMT model](https://docs.nvidia.com/cuda/cuda-programming-guide/03-advanced/advanced-kernel-programming.html#simt-execution-model).
A hidden loop that processes every rack element inside one invocation breaks
the profile's rules.

| Property | Physical CPU profile | Proposed NVIDIA profile |
| --- | --- | --- |
| Rack | one vector register | one 32-thread warp |
| Lane | a register component | a value held by one thread |
| Uniform | one scalar broadcast into the rack | one value shared by the warp |
| Tine | a vector mask | a predicate for each thread |
| Lane exchange | vector shuffle or reduction | explicit warp collective |
| Physical registers | allocated by Rake | allocated by NVIDIA, then checked in the cubin |
| Scheduling | Rake's instruction sequence, executed by the CPU | NVIDIA's instruction schedule and hardware warp scheduling |

Partial masks are legitimate program choices, and Rake can't make arbitrary
inputs keep every lane active. It can tell uniform control from lane-varying
control, though, and refuse serialization introduced by the compiler.

## First profile: NVIDIA PTX

The proposed profile, `nvidia-ptx-sm120`, fixes [PTX ISA
8.7](https://docs.nvidia.com/cuda/archive/12.8.1/parallel-thread-execution/index.html),
`sm_120`, 64-bit addressing and a 32-lane rack, and initially supports only
that SM architecture. It uses [CUDA
12.8.1](https://docs.nvidia.com/cuda/archive/12.8.1/cuda-toolkit-release-notes/index.html#cuda-toolkit-major-component-versions),
with the exact tool binaries pinned by hash. Other architectures and
operations need a checked profile extension, and the compiler will report an
unsupported construct's source location, profile and failed obligation.

| Area | Initial support |
| --- | --- |
| Values | `f32` lane values and predicates, 32-bit integer indices and 64-bit device addresses. Uniformity is tracked separately |
| Arithmetic | binary32 add, subtract, multiply, divide, square root, explicit FMA, ordered comparisons and selection. Divide and square root require correctly rounded forms |
| Floating point | round to nearest, ties to even, with subnormals preserved. Explicit FMA has one rounding. Fused regions may contract under published rules. No implicit fast-math |
| Masks | source through/sweep priority, no inactive memory effects, safe operands or verified predication for partial arithmetic |
| Collectives | broadcast, static shuffle, ballot and ordered float reductions/scans through published warp-shuffle sequences. Participation and reduction order are explicit |
| Memory | typed structure-of-arrays global loads/stores, with alignment, count and lane-to-address mapping. Tails suppress out-of-bounds accesses |
| Control | uniform bounds and source traversal control are permitted. Pure fused regions forbid calls and hidden lane loops |
| Initial exclusions | shared-memory collectives, atomics, dynamic allocation, recursion, device callbacks, tensor operations, scatter and unsupported numerical functions |

Every launched warp will contain 32 invocations. Padding invocations stay
present until the required collectives finish, supplying neutral operands
for inactive data lanes, and never touch out-of-bounds records. Every
participant reaches the same collective with the same membership mask.
Execution never relies on implicit lockstep between threads, so the checker
will reject reads from unavailable shuffle sources, and any collective when
it can't establish which lanes take part.

## Compilation and final-code verification

```text
Rake source and GPU lane contract
  -> checked IR: uniformity, masks and memory effects
  -> inspectable PTX 8.7 for sm_120
  -> pinned ptxas: ahead-of-time cubin
  -> nvdisasm and cuobjdump: instructions, control flow and resources
  -> Rake's sm_120 artifact verifier
  -> exact verified cubin loaded by the runtime
```

NVIDIA owns final instruction selection, physical register allocation and
instruction scheduling on this virtual profile, so Rake verifies the
resulting artifact instead. Using NVIDIA's
[binary utilities](https://docs.nvidia.com/cuda/cuda-binary-utilities/),
the verifier will inspect every reachable instruction and control-flow path,
relate register and data flow to the profile's lane, mask, memory and
collective rules, and check the `LOCAL` and `STACK` resource counts. It
rejects unknown instructions, opaque helper paths and unexplained loops,
and rejects the artifact whenever the evidence is insufficient. Designated pure regions forbid
spills, reloads, calls and hidden serial lane loops, while explicit address
and traversal work has separate obligations.

## Artifact identity and runtime boundary

Verification will bind the exact cubin and kernel hashes to the source,
profile, compiler revision, PTX hash, toolchain binaries and flags, target
SM, verifier version and launch/parameter ABI, and runtime evidence also
records the device and driver. A driver or runtime change requires refreshed
compatibility checks and execution evidence. The runtime will load only those
verified bytes, and refuse PTX JIT fallback or a rebuild with different
flags.

The host interface is a separate C ABI for loading a verified artifact and
launching a kernel with an explicit CUDA context, stream and versioned
parameter layout. Column arguments will be device addresses with counts and
alignment requirements, and the caller owns allocation, lifetimes, stream
ordering and synchronisation, and launch errors stay visible to it. CUDA
supplies the execution interface, while Rake source compiles directly
to PTX.

## Guarantees and measurements

| Compilation or artifact verification | Execution and measurement |
| --- | --- |
| lanes map to threads, without a hidden serial lane loop | enough independent warps to use the device |
| permitted predicates, control flow and collective participation | input-dependent inactive lanes |
| no forbidden spills, reloads or helpers in checked regions | achieved occupancy and whether another register policy is faster |
| parameter layout and lane-to-address pattern | memory transactions, caches and transfer overhead |
| numerical semantics and explicit synchronisation scopes | elapsed time and application throughput |

More registers per thread can leave room for fewer resident warps, as
NVIDIA's [register and occupancy
discussion](https://docs.nvidia.com/cuda/cuda-programming-guide/02-basics/writing-cuda-kernels.html#registers)
explains. A strict no-spill profile will still reject a forbidden spill when
another policy might run faster, and a relaxed resource policy will get a
profile of its own.

## Verification tests

Independent numerical and CPU reference results will check lane mapping,
mask priority, tails, collectives and floating-point edge cases, including
empty data, partial warps, missing participants and unavailable shuffle
sources. Negative fixtures will give the verifier each forbidden pattern,
including incorrect address patterns and unexpected divergent control, and
it refuses them even when a resource summary looks acceptable. Artifact
checks will alter bytes, architecture, flags and launch metadata, so
verification can't silently carry over to a different kernel.

## Later portable and physical profiles

A later [SPIR-V](https://registry.khronos.org/SPIR-V/specs/unified1/SPIRV.html)/Vulkan
profile, such as `vulkan-subgroup32` or `vulkan-subgroup64`, will span a rack
across a required
[subgroup](https://docs.vulkan.org/guide/latest/subgroups.html) width rather
than a large `OpTypeVector` inside one invocation. Each will specify its
SPIR-V and Vulkan versions, memory model, numerical modes, operations and
collective participation, and pipeline creation will reject incompatible
devices. Physical resource verification needs the driver-generated
executable, and Vulkan's optional
[pipeline executable properties extension](https://docs.vulkan.org/refpages/latest/refpages/source/VK_KHR_pipeline_executable_properties.html)
may expose it. Rake refuses certification without enough final-code evidence,
and binds that evidence to the module, pipeline state, device, driver and
verifier.

A physical profile for a sufficiently documented ISA, such as one in
[AMD's architecture documentation](https://gpuopen.com/amd-gpu-architecture-programming-documentation/),
would let Rake own selection, allocation and scheduling as well as
verification.

[Rake and other languages](COMPARISONS.md#gpu-execution-rake-ispc-and-bend)
compares this design with ISPC's gangs and Bend 2's fork–join tasks.
