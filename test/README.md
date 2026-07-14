# Rake conformance tests

`manifest.tsv` is the source of truth for every `.rk` fixture under `test/`
and `examples/`. Its classes are:

- `frontend`: must parse and pass the typechecker, but is not claimed to be
  production-executable yet;
- `native`: must emit rack-preserving native SSA and a verified production
  object for `x86-avx2`;
- `reject`: must stop in the checker with the recorded diagnostic substring;
- `future`: is a design sketch under `examples/future` and is not executable
  language documentation.

From the pinned development shell, build once and run the concise default
suite:

```sh
nix develop --command bash -c 'dune build && bash test/run_tests.sh'
```

Run focused target-profile and native C ABI execution explicitly:

```sh
nix develop --command bash -c 'dune build && bash test/full_tests.sh'
```

Compare the Menhir and Tree-sitter parsers from a checkout where the `rake`
and `tree-sitter-rake` repositories are siblings:

```sh
nix shell nixpkgs#tree-sitter --command bash test/parser_differential.sh
```

The parser runner derives supported and proposed examples from `manifest.tsv`,
then checks the malformed constructs in `parser/manifest.tsv`. Extra source
paths on the command line are treated as supported examples, which lets the
website example extractor use the same check without copying source files.

`tools/check_documentation_examples.sh` is the source-conformance gate for the
named examples in the README, specifications, and website. It fails whenever
an executable fixture lags the canonical documented syntax; a documentation
change therefore creates a visible compiler-migration obligation instead of
silently preserving an obsolete example. `tools/check_website.sh` adds static
HTML reference, asset, release-identity, and stale-claim checks.

To add a case, place one canonical `.rk` source in its class directory and add
one row to `manifest.tsv`. For a rejection, record a stable checker diagnostic
substring rather than an entire location-bearing message. Put a fixture in
`native/` only when both native SSA emission and verified object emission pass;
plain checker acceptance belongs in `frontend/`.
