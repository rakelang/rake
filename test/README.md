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
| `abi` | `test/abi/` | a C harness calls its runs and checks the results |
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
