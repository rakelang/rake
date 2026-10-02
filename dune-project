(lang dune 3.20)
(using menhir 3.0)
(name rake)
(version 0.5.0-beta)
(generate_opam_files true)

(package
 (name rake)
 (maintainers "Kieran Hannigan")
 (authors "Kieran Hannigan")
 (license MIT)
 (homepage "https://rake-lang.org")
 (bug_reports "https://github.com/rakelang/rake/issues")
 (source (github rakelang/rake))
 (synopsis "Rake: A vector-first language for predictable SIMD")
 (description "Rake makes predicated SIMD execution a first-class language construct.
Data rakes through tine declarations (mask patterns), enabling divergent parallel
computations on physical vector targets and the WebAssembly SIMD virtual machine.")
 (depends
  (ocaml (>= 5.1.0))
  (menhir (>= 20231231))
  (ppx_deriving (>= 6.0.0))
  (js_of_ocaml (>= 6.0.0))
  (js_of_ocaml-ppx (>= 6.0.0))
  (cmdliner (>= 1.2.0))))
