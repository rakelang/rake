# SoA machine-contract proof

This harness compares one runtime-length SoA operation in Rake, strict C, and
stable Rust. The formula is shared; the arithmetic contracts are deliberately
reported rather than assumed to be identical:

```text
output_x[i] = position_x[i] + velocity_x[i] * dt
```

The headline input contains 400 particles. An `f32s` rack contains 4 lanes on
SSE2 or NEON, 8 on AVX2, and 16 on AVX-512. Consequently 400 elements require
100, 50, or 25 full-rack iterations respectively. `stack` declares the SoA
field schema; it has no length. The caller supplies the pack and an explicit
runtime count.

One Rake source is intended to be compiled separately for each target profile.
It is not runtime dispatch. C and Rust can instead use scalar loops and rely on
autovectorization, or write and dispatch separate width-specific intrinsic
functions. Rake's distinguishing contract is that an accepted rack may not be
split, scalarized, spilled, or lowered through a helper call. If the selected
profile cannot preserve that contract, compilation fails.

## What the harness proves today

The current production compiler can compile the rack-level positive kernel for
AVX2 and NEON. It treats the named intermediate as a transparent fused alias,
then emits one scalar broadcast and one packed FMA. The strict C build disables
contraction, and the hand-written Rust intrinsic functions explicitly request
separate multiply and add operations. Producing one FMA there requires a
different compiler contract or an explicit FMA intrinsic. This contrast is the
point of the positive case: Rake chooses the faster legal graph without making
the source spell a target width or an optimization request.

Native `run`/pack traversal is still unavailable, so the 400-element Rake
source is checked only by the frontend. It must not be presented as a completed
end-to-end traversal comparison yet.

The primary negative comparison is strict sine. C and Rust accept an ordinary
runtime-count `sin` loop; under the recorded strict builds they emit scalar
`sinf` calls rather than a packed sine implementation. Rake accepts the source
semantics but rejects native emission because it owns no call-free rack sine
lowering. This demonstrates fail-closed compilation, not that C or Rust can
never vectorize sine under other libraries or relaxed flags.

The identical register-pressure DAG produces another instructive result. C and
Rust common-subexpression-eliminate its nine equal `a + b` values and avoid a
spill. Rake currently preserves the source fused graph and conservatively
rejects it at 17 live YMM values. That is evidence of Rake's contract, but not
evidence of better optimization. Separate 20/24-stream stress kernels show the
other side: Rust and C compile non-collapsible AVX2 pressure by emitting vector
stack traffic instead of rejecting the program.

## Run

From the repository root:

```console
nix develop -c dune build
nix develop -c bash demo/soa-proof/run_demo.sh
```

The runner:

1. checks the Rake pack source at its honest frontend stage;
2. verifies the current AVX2 rack object;
3. requires the Rake sine and pressure cases to reject;
4. runs C and Rust correctness checks at counts 400 and 403; and
5. builds `out/report.json`, `out/report.tsv`, `out/report.txt`, compiler logs,
   and function-bounded disassembly through `tools/soa_report.py`.

The report records instruction widths, packed/scalar operations, calls,
branches, stack references, symbol sizes, compiler versions, flags, and source
duplication. It deliberately does not collapse these observations into a
subjective “better assembly” score.

## Fairness and claims

- The positive sources express the same formula, but not the same rounding
  contract. Rake permits and currently selects one-rounding FMA. Canonical C is
  compiled with `-ffp-contract=off`, while the Rust SIMD variants explicitly
  call multiply and add intrinsics. Results can therefore differ on inputs that
  expose fused versus separately rounded arithmetic.
- The report is machine-code and contract evidence, not a numerical-equivalence
  claim between those arithmetic policies.
- The canonical ABI permits output to be disjoint from the inputs or exactly
  alias one complete input field. Partial overlap is invalid.
- ISA ceilings are recorded per object. An AVX2 row may not use AVX-512.
- Stable Rust 1.96 does not expose stable AVX-512 intrinsics/target-feature
  annotations, so the Rust intrinsic comparison honestly stops at AVX2.
- Assembly evidence is not benchmark evidence. No performance claim is made.
- C/Rust scalar, autovectorized, and hand-intrinsic rows are reported
  separately because they operate at different abstraction levels.

Counts 399 and 401 belong in the completed pack/tail gate. For lane counts
4/8/16, their full-plus-tail decompositions are respectively `99+3`, `49+7`,
`24+15` and `100+1`, `50+1`, `25+1`.
