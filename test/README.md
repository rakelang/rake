# Rake's tests

`manifest.tsv` lists every `.rk` file under `test/` and `examples/`, once
each, with the category implied by its directory:

| Category | Directory | Passing means |
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

## Running the tests

`dune runtest` runs the portable compiler tests. It needs only the OCaml
dependencies declared in `rake.opam`, and runs during `opam install
--with-test`. Parsing, lowering, executable semantics and assembly-text
checks don't need an assembler, a disassembler or a target runtime.

The object integration suites have their own aliases:

```sh
dune build @runtest-native   # GNU ELF binutils for x86-64 and AArch64
dune build @runtest-wasm     # Clang's wasm32 target and llvm-objdump
```

Both fail when a required tool is missing, so a missing dependency never
becomes a skipped or passing check. The package CI runs the portable tests on
Linux, macOS and Windows, and object integration in a Linux job with both
target toolchains. The
[compiler reference](../docs/RAKEC.md#tools-and-environment) lists the
executable overrides and installation commands.

The remaining suites run from the development shell. `test/run_tests.sh`
checks the release identity, the manifest's fixtures and the documentation's
examples, and `test/full_tests.sh` adds the target profiles, the native
runtime differential, the whole-program differential and the C boundary of
runs:

```sh
nix develop --command bash -c 'dune build && bash test/run_tests.sh'
nix develop --command bash -c 'dune build && bash test/full_tests.sh'
```

`tools/release_gate.sh` runs every check, including both object integration
aliases, the AArch64 selection checks, the capability evidence in
`capability_evidence.tsv`, the capability report against every fixture, the
parser differential and the website.

## Target checks

`test/native_runtime_test.sh` runs compiled kernels on SSE2, AVX2, AVX-512,
NEON, `wasm-simd128` and `wasm-simd128-relaxed`. `test/reference_harness.ml`
turns one case table, `test/native/reference_cases.tsv`, into a C harness for
each profile. The harness takes types and lane counts from the profile's
native IR and expected bits from the reference interpreter, so a new case or
profile needs no hand-written expected values. Each case also states whether
it has to avoid floating-point exceptions and whether a NaN result has to
match bit for bit.

The physical profiles also run `test/native_oracle_runtime.c` against the
oracles in `test/*_oracle.h`, which are specified independently of the
compiler. They cover ordered reductions and scans against a scalar left fold,
masked partial operations, signalling NaNs, and all six comparison operators
against scalar ordered predicates. Shared C oracles also check comparison
masks, uniform conditions, Boolean choices and absolute values bit for bit,
including signed zeros, infinities and NaN payloads.

SSE2 and AVX2 run on the test host, NEON under QEMU and WebAssembly under
wasmtime. AVX-512 runs on hardware with AVX-512F, or through Intel SDE,
pinned by the development shell as `RAKE_SDE`, and the suite fails if neither
is available, so object verification never stands in for a runtime result.

The other native suites follow the same pattern, comparing compiled code with
independent C on all four physical profiles:

| Script | Checks |
| --- | --- |
| `native_program_test.sh` | slow code against the interpreter, including recursive frames, pointers, traps and recursive large locals on 128 KiB thread stacks, and the C ABI through imported and exported functions, padded structs and callbacks |
| `native_stream_test.sh` | stack runs, with every column ending at a guard page for counts from zero to 65, compact columns, masked updates and compaction |
| `native_conversion_test.sh` | integer and float conversions against an integer-only binary32 oracle, covering ties, saturation, infinities and NaNs |
| `native_lane_transfer_test.sh` | extraction, insertion and shuffles for every lane, with exact float and integer bits |
| `native_integer_rack_test.sh` | 32-bit integer arithmetic, extrema, shifts, comparisons and shuffles, using unsigned C arithmetic for exact overflow bits |

These suites also assemble objects independently of the compiler, so they
can check that the verifier rejects instructions outside Rake's selection,
such as scalar arithmetic in a kernel, narrowed vectors, wrong registers or
missing normalisation. Composed expressions check that still-live inputs survive
register allocation.

`wasm_simd128_verify_test.ml` compiles C objects with packed comparisons and
extending multiplies, and checks that the verifier rejects them without
operand bounds and accepts them when source-derived bounds justify the
instructions.

The `abi` fixtures check callbacks, unions and process arguments against
independently authored C, on every physical profile and WebAssembly. The
argument fixture runs through actual process startup, and `test/abi_test.sh`
also runs it with WASI libc and wasmtime. The same script calls WebAssembly
runs from C for every count from 0 to 20, with misaligned columns, sentinels
after each column and null columns for empty counts.

## Documentation and parser checks

`tools/check_documentation_examples.sh` compiles every ` ```rake ` block in
the README, the documentation and the website's pages. The pages own their
examples, so a language change that breaks one fails here until the page is
updated. Its header lists the checks available to a page.

`test/parser_differential.sh` compares the compiler's parser with the
Tree-sitter grammar in a sibling `tree-sitter-rake` checkout. Both parsers
need to make the same accept and reject decisions on every manifest fixture
and on the malformed sources in `parser/manifest.tsv`:

```sh
nix shell nixpkgs#tree-sitter --command bash test/parser_differential.sh
```
