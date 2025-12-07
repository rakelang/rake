(lang dune 3.20)
(using menhir 3.0)
(name rake)
(version 0.3.0)
(generate_opam_files true)

(package
 (name rake)
 (synopsis "Rake: A vector-first language for CPU SIMD with divergent control flow")
 (description "Rake makes predicated SIMD execution a first-class language construct.
Data 'rakes through' tine declarations (mask patterns), enabling elegant expression
of divergent parallel computations that auto-vectorizers fail to optimize.")
 (depends
  (ocaml (>= 5.1.0))
  (menhir (>= 20231231))
  (ppx_deriving (>= 6.0.0))
  (cmdliner (>= 1.2.0))))
