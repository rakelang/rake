# GPU profiles

This page is a design. Rake has no SPIR-V backend, no Vulkan runtime profile
and no device certification. Building them would need executable semantics,
rejection tests, SPIR-V inspection and validation on supported devices.

The design maps Rake's lanes to Vulkan shader invocations, the individual
executions of a GPU program. Invocations run in subgroups, sets of
invocations that execute together and exchange values directly. Where a CPU
rack is one SIMD register, a GPU rack would span one subgroup, one lane to
each invocation. The [glossary](GLOSSARY.md#gpu-terms) defines the GPU terms.

## SPIR-V is the portable boundary

On a CPU, Rake controls instruction selection, register assignment,
assembly and the object file. For Vulkan it would emit SPIR-V instead, a
portable binary program that the vendor's driver translates into device
instructions. Rake could verify the SPIR-V module and the requirements it
declares, and the driver would own the final instructions and registers.

```text
Rake source
  |
  +-- CPU profile -- Rake machine form -- register allocation -- assembly -- object
  |                  Rake controls and verifies all of it
  |
  +-- GPU profile -- validated SPIR-V -- Vulkan driver -- device code
                     Rake proves this    the driver controls the rest
```

## A GPU rack is a subgroup

A SPIR-V vector is a small value of two to four components inside one
invocation. A Vulkan subgroup is a set of invocations that can exchange data
and run collective operations efficiently, which hardware executes together
as a wave or warp, although Vulkan defines the subgroup's behaviour rather
than an instruction format.

In the design, each rack lane is one invocation of a subgroup. Rack
arithmetic becomes scalar arithmetic in each invocation, reductions and
shuffles become SPIR-V subgroup operations, and tines become predicates in
each invocation. A 32-lane rack spans 32 invocations. It isn't an
`OpTypeVector` of 32 components in one invocation.

| | CPU rack | GPU rack |
| --- | --- | --- |
| What it is | one SIMD register | one subgroup, spread across invocations |
| A lane | one component of the register | one scalar owned by an invocation |
| The width | the element type and the CPU profile | the subgroup size the Vulkan pipeline profile requires |
| Evidence | the register-assigned program and the encoded instructions | validated SPIR-V, its declared capabilities and the pipeline's requirements |
| Register allocation | Rake's | the driver's |

The 400 particles of [the comparison harness](COMPARISONS.md#ways-to-write-simd-code)
would take twelve full racks and a last rack of 16 active invocations on a
`vulkan-subgroup32` profile, and six full racks and the same last rack on
`vulkan-subgroup64`. Vulkan also rounds a dispatch up to the workgroup size,
so padding invocations run, and Rake's bounds predicate would keep them from
touching memory or computing partial operations.

| Profile | Rack width | 400 particles |
| --- | --- | --- |
| `x86-avx2` | 8 values | 50 full racks |
| `vulkan-subgroup32` | 32 invocations | 12 full racks and 16 active invocations |
| `vulkan-subgroup64` | 64 invocations | 6 full racks and 16 active invocations |

## Checks on the SPIR-V

A Vulkan profile would fix a SPIR-V version, the Vulkan features it needs, the
subgroup width, floating-point modes, the memory model and the operations it
allows. Creating the pipeline would check the device and reject a profile
whose subgroup size or capabilities it lacks. The profile would require:

- a fixed subgroup width, requested by the runtime, with incompatible devices
  and shader stages refused,
- no loop over logical lanes: rack arithmetic stays spread across
  invocations,
- subgroup collectives, such as reductions, shuffles, ballots and
  broadcasts, as SPIR-V subgroup operations instead of algorithms through
  workgroup memory,
- typed uniformity, so a value shared by the subgroup and a value for each
  invocation can't be confused,
- safe inactive invocations, with tail predicates and benign operands,
- inspectable memory access: adjacent lanes address adjacent elements, and the
  SPIR-V shows the address calculation,
- a source-located error for an unavailable operation or execution mode, and
- SPIR-V validation and Rake's own structural checks before the shader
  reaches Vulkan.

## What the driver decides

Vulkan drivers compile SPIR-V into device executables when a pipeline is
created, and may change instruction selection, scheduling and register
allocation, or spill. A portable SPIR-V profile therefore can't promise any
of these from the module alone:

- no spills, because SPIR-V identifiers don't fix GPU registers,
- one instruction for each operation, because the driver may expand or combine
  them,
- a register count or occupancy, which depend on the driver and the whole
  pipeline,
- coalesced memory transactions: Rake can prove that addresses are adjacent,
  and the hardware decides the transactions and caching, and
- identical code across driver versions.

## Certifying one device

Verification for one device would name the device and the driver. A tool
would create the pipeline, capture its executable statistics and any internal
representation the driver exposes, and run a vendor-specific checker for
spills, register use, helper code and forbidden instructions. The certificate
would bind the SPIR-V hash, pipeline state, device, driver version, subgroup
size and checker version.

Vulkan exposes executable statistics and internal representations through
an optional [developer extension](https://docs.vulkan.org/refpages/latest/refpages/source/VK_KHR_pipeline_executable_properties.html).
What it shows depends on the implementation, and may include the final shader
assembly, so a device without it couldn't be certified. A certificate would
hold for that device and driver, and not for every device that accepts the
module.

The GPU profiles would share the CPU profiles' lane semantics, column
declarations and predication. The [SPIR-V
specification](https://registry.khronos.org/SPIR-V/specs/unified1/SPIRV.html)
and Vulkan's [subgroup guide](https://docs.vulkan.org/guide/latest/subgroups.html)
describe the target.
