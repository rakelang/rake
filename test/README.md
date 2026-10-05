# Rake's tests

`manifest.tsv` lists every `.rk` file under `test/` and `examples/`, once
each, with the category its directory implies:

| Category | Directory | What passing means |
| --- | --- | --- |
| `frontend` | `test/frontend/` | parses and type-checks |
| `native` | `test/native/` | emits native IR and a verified object for its targets |
| `reject` | `test/reject/` | the checker rejects it with the recorded diagnostic substring |
| `program` | `test/program/` | `main` gives the same result in `rakec --interpret` and as WebAssembly built from the emitted C |
| `trap` | `test/program/trap/` | traps in both |
| `abi` | `test/abi/` | independently compiled C checks layouts and calls across the C boundary |
| `future` | `examples/future/` | a design sketch outside compiler checks |

To add a case, put one `.rk` file in its directory and one row in
`manifest.tsv`. A rejection records a stable substring of the diagnostic,
without its location.

`dune runtest` runs the portable compiler tests. It needs only the OCaml
dependencies declared in `rake.opam`, and runs during `opam install
--with-test`. Parsing, lowering, executable semantics and assembly-text
checks do not require an assembler, a disassembler or a target runtime.

The object integration suites have explicit aliases:

```sh
dune build @runtest-native   # GNU ELF binutils for x86-64 and AArch64
dune build @runtest-wasm     # Clang's wasm32 target and llvm-objdump
```

Both suites fail when a required tool is missing. They never turn a missing
dependency into a skipped or passing verification check. The package CI runs
portable tests on Linux, macOS and Windows, and runs object integration in a
Linux job with both target toolchains installed. The
[compiler reference](../docs/RAKEC.md#tools-and-environment) lists executable
overrides and installation commands.

The remaining suites run from the development shell. `test/run_tests.sh` checks the
release identity, the manifest's fixtures and the documentation's examples:

```sh
nix develop --command bash -c 'dune build && bash test/run_tests.sh'
```

`test/full_tests.sh` adds the target profiles, the x86 backend's runtime
differential, the whole-program differential and the C boundary of runs:

```sh
nix develop --command bash -c 'dune build && bash test/full_tests.sh'
```

The whole-program stack-run fixture compares nested integer and Boolean
uniform choices with scalar expected values over full and partial WebAssembly
racks, for stacks of every length from zero to seven. Final-object verification
also checks that the choices stay on racks before partial stores.

`tools/release_gate.sh` runs every check, including the OCaml unit tests
(`dune runtest` and both object integration aliases), the AArch64 differential under QEMU, the capability
evidence in `capability_evidence.tsv`, the parser differential and the
website.

`test/x86_profiles_test.sh` checks SSE2, AVX2 and AVX-512 against independent
scalar results, including ordered reductions, masked partial operations and
NaNs. All six comparison operators agree with scalar ordered predicates
without raising invalid-operation exceptions for quiet NaNs. SSE2 and AVX2
execute on the test host. AVX-512 executes on hardware with
AVX-512F, or through the Intel SDE that the development shell pins as `RAKE_SDE`.
The suite fails if neither is available, rather than treating object
verification as runtime agreement.

`test/native_program_test.sh` compares scalar semantics, including
recursive frames, integer bit casts and checked traps, with the interpreter.
The pointer fixture checks storage identity after scalar and whole-aggregate
assignment, including read-only pointers and borrowed views.
An independent C harness calls imported and exported functions through
native pointers and a padded struct with a by-value result. The same checks
run on x86 profiles and AArch64 under QEMU. These establish slow C lowering
and ABI agreement. Two threads with 128 KiB stacks exercise recursive large
locals, including 64-byte-aligned C records nested in arrays and Rake records,
synchronous C callback re-entry and repeated calls. C checks the
returned records and independently derived sums after each thread unwinds.
Mixed-program fixtures check the final object's kernels,
signed-zero transfer and Boolean/bitset returns through the scalar C boundary, and x86 reductions against
both the selected-profile interpreter and hand-derived lane counts. Native
general memory runs remain work in progress.

`test/native_stream_test.sh` checks stack runs on SSE2, AVX2, AVX-512 and NEON
against independent scalar C. Every column ends at a guard page, for counts
from zero through 65, so a transfer past the count faults. The checks cover
every tail remainder, a read-only input stack beside the result's, an exact
in-place result over an input column, inactive-lane arithmetic without
floating-point exceptions, and empty stacks with null columns. Two replaced
columns share one kernel. Compact `u8`, `i16`, `u16` and `i8` columns are
widened into 32-bit lanes and checked against scalar sums. Integer, float and
Boolean uniforms arrive in every register class, including a `bool` whose
upper bits a trampoline sets, and eight `f32` uniforms survive across racks.
An unrolled `repeat` multiplies by 59,049 over ten iterations. A masked
update changes only the selected particles, and two compactions keep 8-, 16-
and 32-bit columns in order, one replacing a column of the kept records, with
the descriptor's count checked after each. Each profile also checks a
million-element safe-root pass plus a three-element tail, and the fixture's
`main` agrees between the selected-profile interpreter and WebAssembly.
AVX-512 uses capable hardware or Intel SDE, and NEON uses AArch64 QEMU.

`test/native_conversion_test.sh` checks signed `i32s`/`f32s` and
unsigned `u32s`/`f32s` conversions
against an integer-only binary32 oracle, independent of host conversion
instructions. Boundary values and raw bit patterns cover nearest-even ties,
saturation, infinities and NaNs on all four physical profiles. Fused
compositions retain their input racks, masked calls check exception flags,
and stack-run inputs and results end at guard pages for every count from zero
through 65. Those runs include compact signed and unsigned input, a separate
result stack and exact in-place updates. Independent assembled objects reject
scalar and narrowed conversion instructions. The whole-program fixture
agrees with explicit expected values in each selected-profile interpreter
and compiled WebAssembly. The unsigned integer-bit oracle also checks the
WebAssembly vector ABI in both directions, including masked use, in both addressing modes.

`wasm_simd128_verify_test.ml` independently compiles packed comparison and
extending-multiply C objects. The verifier rejects them without narrower
operand bounds, then accepts them when source-derived bounds justify the
instructions. The stack-run fixture also compiles and agrees with scalar
expected values in both WebAssembly addressing modes.

The shared fold oracle compares the four reductions and inclusive scans with
a volatile scalar left fold on each physical profile. Adversarial addition
checks rounding order, and integer binary32 ordering checks strict extrema,
signed zero and canonical NaNs at every input position. A composed scan also
checks that allocation preserves a still-live input rack. Independent NEON
object fixtures check source-authorised lane transfers while scalar arithmetic
and stack use remain rejected.

`test/native_lane_transfer_test.sh` generates extraction, insertion and shuffle
fixtures for every lane on all four physical profiles. Independent C checks
the exact float and signed/unsigned 32-bit integer bits through scalar
arguments, returns and rebroadcasts, including signalling NaNs without
floating-point exceptions. Integer signatures independently check the
platform's integer argument and return registers, including high-bit values.
Composed arithmetic checks that extracting
or inserting a lane preserves a still-live source rack and uniform argument.
Replacement literals and values extracted from another lane agree bit for bit
with the C oracle. One- and two-rack shuffles compare reverse, rotate, repeat,
identity, interleave and mixed selections against independent index arithmetic,
including moves across AVX register subdivisions. Composed expressions check
both still-live inputs and a shuffle whose two arguments share a register.
Malformed sources check the selected profile's index and width diagnostics.
Independent assembled objects require authorization for permutations and
literal index loads, while a rack store remains rejected even with that
authorization. Native stack-run sources check refusal of lane transfers whose
partial-rack participation is not yet defined.

The same C oracle checks every possible float comparison mask at each
physical width. `all`, `any` and `bitmask` agree with independently assembled
scalar lane patterns, including inverted and composed masks. Quiet NaNs and
signed zeros stay gaps without floating-point exceptions. Independently
assembled verifier fixtures require the exact scalar result transfer at
the terminal return, and reject wrong registers, wrong lanes, missing or
intermediate transfers, and scalar arithmetic inside the kernel.

The same oracle compares all six uniform `f32` conditions with scalar ordered
predicates, including signed zeros, subnormals, infinities and quiet NaNs.
Exact selected lane bits cross the mixed vector/scalar C ABI. Literal
operands, an extracted scalar, untaken roots and division, and conditions
nested inside a through mask check the composed participation contract.

Boolean choices use the same C oracle, including every `all` and `any`
lane-mask pattern. Exact selected bits include signed zeros, infinities and
NaN payloads. Fused expressions, six Boolean arguments, eight SIMD arguments
alongside a Boolean, untaken roots and nested through masks check allocation
and floating-point participation. Separate assembly callers set unspecified
bits above a valid C Boolean byte and inspect the raw return register, so
both false and true normalise independently of those upper bits.

`test/native_integer_rack_test.sh` compares 32-bit wrapping add/subtract/multiply,
signed negation and absolute value, signed and unsigned extrema, literal bit shifts, bitwise
AND/OR/XOR/AND-NOT and all six signed and unsigned comparisons with independent scalar C
on the four physical profiles. The oracle uses unsigned
arithmetic for exact overflow bits and reinterprets signed predicates
separately. It checks literal
broadcasts, mask bitsets, integer/float selection through the vector C ABI,
through/gaps coverage and still-live inputs in fused expressions. Negation
checks include the minimum signed value, retained input racks and both arms
of a lane-masked conditional. Absolute value uses widened 64-bit C arithmetic
before converting back to lane bits, including the wrapping minimum value,
still-live input racks, reused intermediates, nested calls and lane masks.
Unsigned comparison checks cover the boundary at bit 31, literals on either
side, equal operands, all/any reductions, global tines and gap inversion.
Hand-specified interpreter masks cover all six predicates at each CPU width.
`test/program/unsigned_comparisons.rk` checks unsigned rack selection,
extrema, clamps and uniform broadcasts against explicit values in both the interpreter and
compiled WebAssembly. High-bit masks check comparisons at 2³¹ and 2³¹−1,
including reversed operands and every unsigned boundary value.
AND-NOT checks operand order, equal inputs, full-width unsigned literals
and destructive register reuse. Multiplication checks all lanes against unsigned
C products, including overflow, shared operands and still-live inputs that
force destructive register reuse on SSE2. Signed extrema checks cover boundary
values, aliased operands, nested clamps, lane masks and retained inputs.
Unsigned extrema use independent `uint32_t` ordering across bit 31 and the
full lane range, including literal-first operations and preservation of
live inputs. Hand-specified interpreter extrema cover four, eight and
sixteen lanes.
The C oracle also checks signed and unsigned uniform arguments across the
platform's separate integer and SIMD register counters. Boundary values
include zero, bit 31 and all-one bits, with retained racks, unsigned clamps,
six integer arguments on x86, eight on AArch64, and eight SIMD arguments
alongside an integer uniform. Direct uniform conditions
compare all six signed and unsigned predicates with scalar C, including
boundary values, literals on either side and preserved input racks. Nested
conditions inside a through mask check both selected results and the absence
of floating-point exceptions from untaken work. Slow callers and the
WebAssembly fixture exercise direct integer conditions too.
Independently assembled fixtures require exact
entry imports and reject wrong, missing, repeated and body-local transfers.
Bit-shift checks cover every literal count from 0 to 31 on signed and unsigned
racks, and runtime `u32` counts with high bits set, normalised modulo 32.
Counts arrive through both the integer C ABI and lane extraction. Unsigned
scalar bit operations independently compute sign extension, and composition
checks preserve live inputs and the original count across shifts and lane masks.
Static integer shuffles compare every output lane with independent C index
arithmetic for reverse, rotation, repeated, identity, interleaved and mixed
selections. Both signed and unsigned racks cross the vector C ABI. Fused
expressions preserve both input racks, and aliased arguments check destructive
register reuse. Hand-specified interpreter cases cover signed boundary bits
and cross-register subdivisions at four, eight and sixteen lanes.
Independently assembled machine objects check
rejection of narrowed integer vectors, scalar arithmetic
and memory work inside a register kernel. SSE2 also rejects direct SSE4.1
extrema and SSSE3 absolute-value instructions. Shift fixtures require the
selected normalisation sequence for runtime counts and reject unnormalised
counts, out-of-range immediates, narrowed data and scalar instructions.

The shared absolute-value oracle supplies explicit binary32 input and output
bits for signed zeros, subnormals, infinities and quiet and signalling NaNs.
Both direct and masked rack calls preserve magnitude bits without raising
floating-point exceptions on the four native profiles. Traversals check
absolute values against scalar C for every guarded tail.

The callback fixture uses independently authored C prototypes and padded
structs. C retains and invokes Rake function pointers, and Rake invokes
pointers returned by C, including callbacks with opaque contexts, mixed
integer/float arguments and void results. It also checks independently declared
read-only pointers in callback arguments and C return values. These checks run
on every physical profile and WebAssembly. The local callback fixture agrees
with the interpreter, including the trap on an indirect call through a null pointer.

The union fixture includes overlapping integer, floating-point, pointer,
array and padded-struct members. Independent C calls check member access,
storage identity, by-value returns, imported by-value arguments and callbacks.
It runs on the four physical CPU profiles and WebAssembly. C union storage
has an explicit interpreter diagnostic instead of a guessed layout.

The argument fixture runs through actual process startup and compares its
byte-level result with independent C and the interpreter. It covers no extra
arguments, empty strings, option-like strings and UTF-8 bytes. The WASI check
in `test/abi_test.sh` exercises the same fixture with WASI libc and wasmtime.

`tools/check_documentation_examples.sh` compiles every ` ```rake ` block in
the README, the documentation and the website's pages. The pages own their
examples, so a change to the language that breaks one fails here until the
page is updated. Its header lists the checks a page can ask for.

`test/parser_differential.sh` compares the compiler's parser with the
Tree-sitter grammar in a sibling `tree-sitter-rake` checkout. It parses every
manifest fixture and the malformed sources in `parser/manifest.tsv`, and the
check requires identical accept and reject decisions from both parsers:

```sh
nix shell nixpkgs#tree-sitter --command bash test/parser_differential.sh
```
