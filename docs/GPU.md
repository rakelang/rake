# GPU profiles

This page defines the planned GPU execution contract. Rake currently has no
GPU compiler, runtime or device-artifact verifier. CPU coverage and native
C interoperation come first. The first GPU backend will target NVIDIA PTX
and verify an ahead-of-time cubin. Portable SPIR-V and a direct physical
backend are later directions.

The purpose is to preserve useful parallel work across GPU lanes, keep
temporary values in registers where the profile requires it, and make memory
and synchronisation costs explicit. Hardware schedules warps. Rake will
control the algorithm's lane mapping and check the resulting execution structure.

<figure class="diagram diagram-gpu-rack">
<div class="diagram-scroll" tabindex="0" role="region" aria-label="GPU rack diagram, scroll horizontally on a narrow screen">
<svg viewBox="0 0 680 264" role="img" aria-labelledby="gpu-rack-title gpu-rack-description">
<title id="gpu-rack-title">A GPU rack spans a warp</title>
<desc id="gpu-rack-description">A column maps to 32 thread lanes. Each lane calculates its own value. A mask disables selected lanes. Hardware schedules the warp, while Rake defines and verifies the lane mapping.</desc>
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
<figcaption>One rack spans a warp. Grey lanes illustrate a programmer-selected mask, not a compiler fallback.</figcaption>
</figure>

## A rack is a group of lanes

A CPU rack occupies one vector register. A GPU rack will span a specified
warp, wave or subgroup, with each invocation holding one lane's value.
Arithmetic in each invocation is the parallel lowering. A hidden loop that
processes all rack elements inside one invocation would violate the contract.
NVIDIA's [SIMT model](https://docs.nvidia.com/cuda/cuda-programming-guide/03-advanced/advanced-kernel-programming.html#simt-execution-model)
describes warp execution and masked paths.

| Property | Physical CPU profile | Proposed NVIDIA profile |
| --- | --- | --- |
| Rack | one vector register | one 32-thread warp |
| Lane | a register component | a value held by one thread |
| Uniform | one scalar broadcast into the rack | one value shared by the warp |
| Tine | a vector mask | a predicate for each thread |
| Lane exchange | vector shuffle or reduction | explicit warp collective |
| Physical registers | allocated by Rake | allocated by NVIDIA, then checked in the cubin |
| Scheduling | Rake's instruction sequence, executed by the CPU | NVIDIA's instruction schedule and hardware warp scheduling |

Partial masks are legitimate program choices. Rake cannot make arbitrary
inputs keep every lane active. It can distinguish uniform control from
lane-varying control and refuse compiler-introduced serialization. A declared
masked path may still use fewer lanes while it executes.

## First profile: NVIDIA PTX

The proposed identifier is `nvidia-ptx-sm120`. It fixes PTX ISA 8.7,
`sm_120`, 64-bit addressing and a 32-lane rack. It supports only that SM
architecture initially. The selected toolchain is CUDA 12.8.1, with the exact
tool binaries to be pinned by hash in the implementation. See the [PTX 8.7
specification](https://docs.nvidia.com/cuda/archive/12.8.1/parallel-thread-execution/index.html)
and [CUDA 12.8.1 component versions](https://docs.nvidia.com/cuda/archive/12.8.1/cuda-toolkit-release-notes/index.html#cuda-toolkit-major-component-versions).

The initial operation set below is a design boundary, not available support.
Other architectures and operations require a checked profile extension.
Unsupported constructs must report their source location, profile and failed
obligation before any artifact is accepted.

| Area | Initial contract |
| --- | --- |
| Values | `f32` lane values and predicates, 32-bit integer indices and 64-bit device addresses. Uniformity is tracked separately |
| Arithmetic | binary32 add, subtract, multiply, divide, square root, explicit FMA, ordered comparisons and selection. Divide and square root require correctly rounded forms |
| Floating point | round to nearest, ties to even, with subnormals preserved. Explicit FMA has one rounding. Fused regions may contract under published rules. No implicit fast-math |
| Masks | source through/sweep priority, no inactive memory effects, safe operands or verified predication for partial arithmetic |
| Collectives | broadcast, static shuffle, ballot and ordered float reductions/scans through published warp-shuffle sequences. Participation and reduction order are explicit |
| Memory | typed structure-of-arrays global loads/stores, with alignment, count and lane-to-address mapping. Tails suppress out-of-bounds accesses |
| Control | uniform bounds and source traversal control are permitted. Pure fused regions forbid calls and hidden lane loops |
| Initial exclusions | shared-memory collectives, atomics, dynamic allocation, recursion, device callbacks, tensor operations, scatter and unsupported numerical functions |

Every launched warp will contain 32 invocations. Padding invocations remain
present until required collectives finish, with neutral operands for inactive
data lanes. All participants reach the same collective with the same
membership mask. The checker must reject reads from unavailable shuffle
sources and collectives whose participation cannot be established. Execution
never relies on implicit lockstep between threads.

For 400 records the mapping needs twelve full racks and a rack with sixteen
data lanes. Additional dispatch padding may be needed for the block size.
Padding invocations never touch out-of-bounds records.

## Compilation and final-code verification

The backend belongs in Rake's profile, lowering and verifier pipeline:

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
instruction scheduling on this virtual profile. Rake's verifier must
establish the promised properties of the resulting artifact. Passing it
does not transfer those allocation decisions to Rake.

The verifier will inspect every reachable instruction and control-flow path,
relating register/data flow to the lane, mask, memory and collective contract.
It must reject unknown instructions, opaque helper paths, unexplained loops
and insufficient evidence. In designated pure regions it must establish no
spills or reloads, no calls and no hidden serial lane loop. Explicit address
and traversal work has separate obligations.

Zero `LOCAL` or `STACK` bytes alone do not prove those properties. NVIDIA's
[binary utilities](https://docs.nvidia.com/cuda/cuda-binary-utilities/)
supply disassembly, control-flow output and resource reports. The verifier
must also check actual memory instructions and their data flow.

## Artifact identity and runtime boundary

Verification will bind the exact cubin and kernel hashes to the source,
profile, compiler revision, PTX hash, toolchain binaries and flags, target
SM, verifier version and launch/parameter ABI. Runtime evidence also records
device and driver identity. A driver or runtime change requires refreshed
compatibility checks and execution evidence.

The runtime will load those cubin bytes and confirm target and kernel identity.
It will refuse unverified PTX JIT fallback, a rebuild with different flags,
or verification transferred to different bytes.

The host interface is a separate C ABI for loading a verified artifact and
launching a kernel with an explicit CUDA context, stream and parameter layout.
Column arguments will be device addresses with counts and alignment
requirements. The caller owns allocation, lifetimes, stream ordering and
synchronisation. Launch errors remain visible. CUDA supplies the execution
interface, while Rake emits PTX directly. Rake source need not be CUDA C++.

The compiler/runtime handoff requires a versioned parameter layout and launch
contract, semantic checks and an exact artifact identity. Engine adoption
additionally requires CPU, official-engine and GPU parity, then bounded
resource and throughput measurements. Compiler availability alone does not
satisfy those engine gates.

## Guarantees and measurements

| Compilation or artifact verification | Execution and measurement |
| --- | --- |
| lanes map to threads, without a hidden serial lane loop | enough independent warps to use the device |
| permitted predicates, control flow and collective participation | input-dependent inactive lanes |
| no forbidden spills, reloads or helpers in checked regions | achieved occupancy and whether another register policy is faster |
| parameter layout and lane-to-address pattern | memory transactions, caches and transfer overhead |
| numerical semantics and explicit synchronisation scopes | elapsed time and application throughput |

More registers per thread can leave room for fewer resident warps. A strict
no-spill profile will reject a forbidden spill even when another policy
might run faster. Any relaxed resource policy must be an explicit separate
choice, never a fallback. Balanced workloads and enough independent work
remain program responsibilities. NVIDIA's [register and occupancy
discussion](https://docs.nvidia.com/cuda/cuda-programming-guide/02-basics/writing-cuda-kernels.html#registers)
explains that trade-off.

## Acceptance checks

Independent numerical and CPU reference results will check lane mapping,
mask priority, tails, collectives and floating-point edge cases. Boundary
counts include empty data and partial warps. Collective checks include
missing participants and unavailable shuffle sources.

Final-code negative fixtures will contain spills/reloads, helper calls,
serial lane loops, unexpected divergent control, incorrect address patterns
and unknown instructions. The verifier must refuse them even when a resource
summary appears acceptable. Artifact checks will change bytes, architecture,
flags and launch metadata to ensure verification cannot follow a different
kernel silently.

## Later portable and physical profiles

SPIR-V/Vulkan is a later portable virtual profile. A rack will span a required
subgroup width, rather than a large `OpTypeVector` inside one invocation.
Profiles such as `vulkan-subgroup32` and `vulkan-subgroup64` will specify
SPIR-V/Vulkan versions, memory model, numerical modes, operations and
collective participation. Pipeline creation must reject incompatible devices.
The [SPIR-V specification](https://registry.khronos.org/SPIR-V/specs/unified1/SPIRV.html)
and [Vulkan subgroup guide](https://docs.vulkan.org/guide/latest/subgroups.html)
define those interfaces.

Source and module verification can preserve the lane contract. Physical
resource claims require the particular driver-generated executable. Vulkan's
optional [pipeline executable properties extension](https://docs.vulkan.org/refpages/latest/refpages/source/VK_KHR_pipeline_executable_properties.html)
may expose statistics or representations, depending on the implementation.
Insufficient final-code evidence means rejection of certification. Evidence
must bind the module, pipeline state, device, driver and verifier.

A later physical profile could use a sufficiently documented ISA, such as
one in [AMD's architecture documentation](https://gpuopen.com/amd-gpu-architecture-programming-documentation/).
Rake would own selection, allocation and instruction scheduling as well as
final-object verification. That is a possible stronger ownership contract,
not a prerequisite for useful verified GPU execution. This plan includes
neither an unofficial NVIDIA SASS encoder nor a GPU purchase.

[Rake and other languages](COMPARISONS.md#gpu-execution-rake-ispc-and-bend)
compares this lane contract with ISPC's gangs and Bend 2's fork–join tasks.
