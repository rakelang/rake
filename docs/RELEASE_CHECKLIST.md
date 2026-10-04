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
   127.0.0.1. Review every `must`, `claim`, `promise` and `not` hit in
   GPT-written public prose, in both the owning sources and generated pages,
   following the global deslop skill. Keep operators, exact diagnostics and
   substantive requirements. Rewrite defensive caveats and stock wording
   before publication.
7. Build the release archives from the exact source commits. In a clean opam
   switch outside the development shell, install the compiler archive with
   `opam install . --with-test --with-doc` and run the installed `rakec`.
   Run the opam metadata linter too. Test the exact source and checksums in
   the repository submission, including any patches, before pushing that
   submission.
8. Run the grammar's package checks on the actual npm tarball, Python source
   archive and repaired wheel, and Cargo crate in fresh consumers. The
   grammar's `Check generated bindings` workflow owns these checks. Its
   publication workflow requires them and uploads the tested artifacts.
9. Push source changes and require green compiler and grammar GitHub checks
   for those exact commits before tagging or uploading packages. The compiler
   workflow installs through opam on its supported host matrix, runs object
   checks with their toolchains, and compares its parser with Tree-sitter.
   Registry acceptance is an additional check, never our first smoke suite.
10. Tag the checked compiler and grammar commits as `vVERSION`, so Go's module
    tooling recognises the grammar release. Publish the packages and update
    repository submissions. Inspect their final checks and clear failures
    before calling the release complete. Deploy the website as its README
    describes and confirm the release shown in its footer.
