# Glossary

Terms from SIMD programming, from compilers and from Rake itself, as the
documentation uses them.

## Rake's terms

| Term | Meaning |
| --- | --- |
| rack | one vector value of the target profile, such as an `f32s`: a physical vector register on x86 or Arm, and one `v128` in WebAssembly |
| lane | one element position in a rack: an `f32s` on AVX2 has eight |
| uniform | one scalar shared by every lane, marked `<name>` |
| tine | a named mask of lanes, written `#name` |
| through block | code that computes under a tine, with a value for the other lanes |
| sweep | the choice of each lane's result from tines in priority order, ending in `_` |
| crunch | a function of racks without masks |
| rake | a function of racks with tines, through blocks and a sweep |
| run | vector code over memory: views, packs and traversals |
| slow code | scalar code, marked `slow`, that holds no racks |
| slow block | `slow { ... }`, a lexical scalar escape inside a run or slow function, optionally producing a scalar value |
| fused binding | `\| name <\| e`, one stage of a pure fused computation |
| stack | the declared columns of structure-of-arrays storage |
| pack | the columns of a stack, supplied by the caller |
| traversal | `for chunk in pack using f32s up to <n>:`, a rack of records at a time |
| view | `[]T`, elements with a count, borrowed from the caller |
| profile | a named target, such as `x86-avx2`, that fixes the rack width and the rules |
| widening | converting narrow stored elements, such as `u8`, to wider lanes without changing their values |

## SIMD terms

| Term | Meaning |
| --- | --- |
| SIMD | single instruction, multiple data: one instruction applies an operation to several values held in a vector register |
| vector register | a register that holds several numbers for one instruction to process together |
| SSE, AVX | families of x86 vector instructions, with 128-bit SSE2 registers, 256-bit AVX2 registers and 512-bit AVX-512 registers |
| NEON | Arm's 128-bit vector instructions, called Advanced SIMD on 64-bit Arm |
| WebAssembly SIMD128 | WebAssembly's 128-bit vector type, `v128`, and its instructions |
| YMM register | a 256-bit x86 register used by AVX and AVX2, which holds eight 32-bit floats |
| mask, predication | a true or false choice for each lane, and execution that uses one to decide which lanes contribute |
| broadcast | copying one scalar into every lane, such as turning 0.5 into eight copies for AVX2 |
| partial operation | an operation valid only for some inputs, such as the square root of a negative number |
| reduction, scan | a reduction combines all the lanes into one value, and a scan gives every running partial result, such as all prefix sums |
| gather, scatter | loading from or storing to addresses that aren't contiguous, one per lane |
| structure of arrays | a layout that stores each field in its own contiguous column, where an array of structures stores each record's fields together |
| intrinsic | a function a compiler provides to request a particular machine instruction without writing assembly |
| autovectorisation | a compiler finding vector operations in an ordinary scalar loop |
| spill | moving a value from a register to memory because there are too few registers to keep it |
| scalarise | replacing one vector operation with separate operations on each value |
| FMA | fused multiply-add: a multiplication and an addition with one rounding step |
| f32 | a 32-bit IEEE 754 floating-point number, a `float` in C |

## Compiler terms

| Term | Meaning |
| --- | --- |
| front end, back end | the front end parses and checks source, and the back end selects instructions, assigns registers and writes the program |
| SSA | static single assignment: a representation in which each value is defined once, which makes data dependencies explicit |
| binding, reference | a binding gives a value a name, and a reference uses the name. It means the value, not a memory address |
| instruction selection | choosing the machine instructions for each operation |
| register allocation | assigning each value to a physical register. Rake does this for its physical targets, while a WebAssembly runtime does it for `v128` values |
| object code | encoded machine instructions and data, ready for a linker |
| assembler | the tool that encodes textual assembly as object code |
| ABI | application binary interface: the rules for passing arguments, returning values and laying out data |
| System V ABI | the calling convention most Unix-like x86-64 systems use |
| AAPCS64 | the procedure call standard for 64-bit Arm |
| conformance corpus | the accepted and rejected example programs that check the compiler against the language's rules |
| OCaml, Dune, Nix | the language the compiler is written in, its build system, and the package manager that pins the tools in `nix develop` |

## GPU terms

These appear in [the GPU design](GPU.md).

| Term | Meaning |
| --- | --- |
| GPU compute | using a graphics processor for general parallel calculation |
| SPIR-V | a standard binary format for GPU programs, which a driver translates into the device's instructions |
| Vulkan | a cross-platform interface for submitting graphics and compute work to GPUs |
| driver | the vendor's software that translates portable GPU programs into device instructions and schedules them |
| shader invocation | one execution of a GPU program, over one element of the data |
| subgroup | a set of invocations that execute together and exchange values directly, called a warp or wave by vendors |
| workgroup | a programmer-declared batch of invocations that may share local memory, containing one or more subgroups |
| SPMD, SIMT | single program, multiple data: many instances of one program. GPUs call their hardware model single instruction, multiple threads |
| ISPC | Intel's compiler for a C-like language that runs one program across a group of CPU SIMD lanes |
| LLVM | a compiler infrastructure that provides optimisation, instruction selection and register allocation for many targets |
