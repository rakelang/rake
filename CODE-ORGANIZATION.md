# Rake Compiler Code Organization

This document is the durable review ledger for the Rake compiler. It covers every
compiler source and build-definition file under `src/`, including files that are
later renamed, split, or deleted. A completed row records one canonical owner and
the verified disposition of the reviewed file.

## Governing principles

1. Execution is direct. The executable parses platform input and calls the library
   API; reusable compiler workflows and policy belong to the library.
2. Each domain structure and workflow has one clearly named owner. Mutable
   representation stays private to that owner.
3. Domain schema, parsing, semantic analysis, lowering, optimization, verification,
   register allocation, instruction selection, assembly emission, toolchain use,
   and presentation remain separate responsibilities.
4. Every public item has one public path. Facade modules, convenience re-exports,
   compatibility aliases, and duplicate application-data shapes are not allowed.
5. Visibility is the narrowest needed by the intended dependency. Public exposure
   must describe a deliberate external API rather than repair an ownership error.
6. Names state the full owned concept or operation. Short generic names are not
   used when a longer specific name makes responsibility or execution clear.
7. File boundaries follow coherent ownership and dependency direction. Broad
   dumping-ground modules and chains of forwarding execution modules are not
   allowed.
8. Canonical compiler data is consumed directly. Consumers may add only rendering
   or interaction state, primitive indexes, or references; they may not copy,
   rename, reshape, or redefine domain fields.
9. When an implementation is replaced, its producers, types, registrations,
   aliases, wrappers, callers, and empty directories are removed before the new
   path is introduced.
10. The OCaml standard library is used for standard operations. A local helper is
    justified only by project-specific behaviour or a measured unmet requirement.
11. Core behaviour is implemented first. Debugging, convenience, presentation,
    observability, and extension surfaces are added only for a demonstrated need.
12. Compilation, tests, linting, and application execution are deferred until every
    known in-scope source rewrite is finished. Final compiler-driven cleanup is a
    separate last phase and does not substitute for source review.

## Status definitions

- **Pending**: inventoried, but no file-specific review has begun.
- **Assigned**: one subagent is reviewing and implementing this file.
- **Changes requested**: the orchestrator read the result and found concrete work
  that must be corrected before acceptance.
- **Reviewed**: the orchestrator read the complete resulting file and accepted its
  ownership, execution flow, naming, visibility, and boundary decisions.
- **Blocked**: a material ownership decision cannot be made without user direction;
  the unresolved choice is recorded in the row.
- **Superseded**: the old file was fully removed after its owned material acquired
  one reviewed canonical destination. The destination is recorded in the row.
- **Compiler cleanup**: source review is accepted, but deferred compiler feedback
  still needs to be resolved after all rewrite rows are reviewed or superseded.

## File checklist

| File | Status | Canonical owner or unresolved issue | Review record |
|---|---|---|---|
| `src/bin/dune` | Pending | Executable build ownership unresolved pending review. | — |
| `src/bin/main.ml` | Pending | Command-line and platform-adapter boundary unresolved pending review. | — |
| `src/lib/aarch64_neon_asm.ml` | Pending | AArch64 NEON assembly-emission ownership unresolved pending review. | — |
| `src/lib/aarch64_neon_isel.ml` | Pending | AArch64 NEON instruction-selection ownership unresolved pending review. | — |
| `src/lib/aarch64_neon_mir.ml` | Pending | AArch64 NEON machine-IR schema ownership unresolved pending review. | — |
| `src/lib/aarch64_neon_regalloc.ml` | Pending | AArch64 NEON register-allocation ownership unresolved pending review. | — |
| `src/lib/ast.ml` | Pending | Source-language syntax-tree schema ownership unresolved pending review. | — |
| `src/lib/capabilities.ml` | Pending | Target capability-policy ownership unresolved pending review. | — |
| `src/lib/dune` | Pending | Compiler-library build ownership unresolved pending review. | — |
| `src/lib/layout.ml` | Pending | Data-layout ownership unresolved pending review. | — |
| `src/lib/lexer.mll` | Pending | Lexical-analysis ownership unresolved pending review. | — |
| `src/lib/masked_safety.ml` | Pending | Masked-operation safety-policy ownership unresolved pending review. | — |
| `src/lib/native_backend.ml` | Pending | Native compilation orchestration ownership unresolved pending review. | — |
| `src/lib/native_ir.ml` | Pending | Target-independent native IR schema ownership unresolved pending review. | — |
| `src/lib/native_lower.ml` | Pending | Native-IR lowering ownership unresolved pending review. | — |
| `src/lib/native_optimize.ml` | Pending | Native-IR optimization ownership unresolved pending review. | — |
| `src/lib/native_reference.ml` | Pending | Scalar reference-semantics ownership unresolved pending review. | — |
| `src/lib/native_semantics.ml` | Pending | Facade/duplicate public path observed; canonical semantics owner unresolved pending full review. | — |
| `src/lib/native_toolchain.ml` | Pending | External native-toolchain invocation ownership unresolved pending review. | — |
| `src/lib/native_verify.ml` | Pending | Native-IR verification ownership unresolved pending review. | — |
| `src/lib/parser.mly` | Pending | Parsing and source-syntax construction ownership unresolved pending review. | — |
| `src/lib/target.ml` | Pending | Compilation-target schema and selection ownership unresolved pending review. | — |
| `src/lib/typecheck.ml` | Pending | Semantic/type-analysis ownership unresolved pending review. | — |
| `src/lib/types.ml` | Pending | Source-language type schema ownership unresolved pending review. | — |
| `src/lib/version.ml` | Pending | Release-identity ownership unresolved pending review. | — |
| `src/lib/x86_avx2_asm.ml` | Pending | x86 AVX2 assembly-emission ownership unresolved pending review. | — |
| `src/lib/x86_avx2_isel.ml` | Pending | x86 AVX2 instruction-selection ownership unresolved pending review. | — |
| `src/lib/x86_avx2_mir.ml` | Pending | x86 AVX2 machine-IR schema ownership unresolved pending review. | — |
| `src/lib/x86_avx2_regalloc.ml` | Pending | x86 AVX2 register-allocation ownership unresolved pending review. | — |

## Deferred compiler-driven cleanup

No compilation, generated-parser build, test, linter, or executable run is permitted
until every checklist row is `Reviewed` or `Superseded` and every discovered current
compiler feature has received the same delegated implementation and read-review
cycle. Compiler diagnostics are then recorded and resolved here without weakening
the ownership decisions above.

