# Rake alpha release checklist

Run this checklist from sibling `rake`, `tree-sitter-rake`, and
`rake-lang.org` checkouts. A release is one coordinated compiler, grammar,
documentation, and website snapshot.

1. Update `src/lib/version.ml`, then copy that exact version into the metadata
   locations reported by `tools/check_release_identity.sh`.
2. Build `rakec`, run `rakec --version`, and review
   `rakec --print-capabilities` and `rakec --print-targets`.
3. Run `bash test/run_tests.sh`, `bash test/full_tests.sh`, and
   `dune runtest --force` in the pinned development environment. Run
   `bash test/parser_differential.sh` with Tree-sitter available.
4. Compile representative AVX2 programs with `--verify-native`; inspect the
   runtime comparison for graph-stable semantics, the optimized SSA for
   optimizer-sensitive arithmetic, and the stored disassembly obligations.
5. Run `tree-sitter generate && tree-sitter test` in `tree-sitter-rake`.
6. Run `nix develop --command bash tools/check_website.sh` and inspect the
   website at desktop and mobile widths. Follow `docs/WEBSITE_DEPLOYMENT.md`
   for the authorized publish command and post-deployment checks.
7. Tag and publish the compiler and grammar packages only after the checks pass.
   Deploy the matching website last and verify its displayed release label.
