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
| `future` | `examples/future/` | a design sketch, not compiled |

To add a case, put one `.rk` file in its directory and one row in
`manifest.tsv`. A rejection records a stable substring of the diagnostic,
without its location.

The suites run from the development shell. `test/run_tests.sh` checks the
release identity, the manifest's fixtures and the documentation's examples:

```sh
nix develop --command bash -c 'dune build && bash test/run_tests.sh'
```

`test/full_tests.sh` adds the target profiles, the x86 backend's runtime
differential, the whole-program differential and the C boundary of runs:

```sh
nix develop --command bash -c 'dune build && bash test/full_tests.sh'
```

`tools/release_gate.sh` runs every check, including the OCaml unit tests
(`dune runtest`), the AArch64 differential under QEMU, the capability
evidence in `capability_evidence.tsv`, the parser differential and the
website.

`test/x86_profiles_test.sh` checks SSE2, AVX2 and AVX-512 against independent
scalar results, including ordered reductions, masked partial operations and
NaNs. SSE2 and AVX2 execute on the test host. AVX-512 executes on hardware with
AVX-512F, or through Intel SDE supplied as `RAKE_SDE=/absolute/path/to/sde64`.
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
locals, synchronous C callback re-entry and repeated calls. C checks the
returned records and independently derived sums after each thread unwinds.
Mixed-program fixtures check the final object's kernels,
signed-zero transfer through the scalar C boundary, and x86 reductions against
both the selected-profile interpreter and hand-derived lane counts. Native
memory runs remain work in progress.

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
two parsers must accept and reject the same sources:

```sh
nix shell nixpkgs#tree-sitter --command bash test/parser_differential.sh
```
