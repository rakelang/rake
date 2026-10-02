# Release checklist

A release is one compiler, Tree-sitter grammar, documentation set and
website, from sibling checkouts of `rake`, `tree-sitter-rake` and
`rake-lang.org`.

1. Set the version in `src/lib/version.ml`, then copy it to every place
   `tools/check_release_identity.sh` reads: `dune-project`, `rake.opam`, the
   README, the grammar's `package.json` and `tree-sitter.json`, and the
   changelog's heading.
2. Build `rakec`, and review `rakec --version`, `rakec --print-capabilities`
   and `rakec --print-targets`.
3. Rebuild the website with `tools/build.sh` in `rake-lang.org`, so its pages
   show the new version and the current documentation.
4. Run `tools/release_gate.sh` in the development shell, with Tree-sitter
   available for the parser differential. It runs every test suite, the
   documentation examples, the release identity and the website check.
5. Run `tree-sitter generate && tree-sitter test` in `tree-sitter-rake`.
6. Look at the website's pages at desktop and phone widths, served on
   127.0.0.1.
7. Tag the compiler and grammar as `vVERSION` once the checks pass, so Go's
   module tooling recognises the grammar release. Publish the packages, then
   deploy the website as its README describes and confirm the release shown
   in its footer.
