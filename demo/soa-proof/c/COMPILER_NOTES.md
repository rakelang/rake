# C compiler observations

These observations use strict floating-point compilation: no `-ffast-math`, no
finite-math assumptions, no vector math library, and contraction disabled.
Objects were built independently so that only the intrinsic translation units
enable their required ISA.

Consequently the advance kernels retain separate multiply and add rounding.
They express the same formula as the Rake example but do not promise the same
bits for inputs that distinguish separate rounding from FMA. Enabling
contraction or writing `_mm256_fmadd_ps` would be a different C variant; Rake's
ordinary fused-flow source selects that FMA automatically.

```sh
COMMON="-std=c11 -O3 -Wall -Wextra -Wpedantic -Werror -ffp-contract=off"
clang $COMMON -mavx2 -c reject_register_pressure_avx2.c
clang $COMMON -c reject_sin.c
gcc $COMMON -mavx2 -c reject_register_pressure_avx2.c
gcc $COMMON -c reject_sin.c
```

The inspected compilers were Clang 21.1.8 and GCC 15.2.0 on x86-64.

## Aliasing contract

The canonical advance kernels permit `output_x` to exactly alias either
`position_x` or `velocity_x`; otherwise all arrays must be disjoint. Partial
overlap is outside the contract. The explicit SIMD implementations load both
input vectors before storing each output vector, matching Rake's chunk
load-before-store semantics. `selftest.c` exercises disjoint output and both
exact-alias cases for every count from 0 through 417.

`sin_array_scalar` likewise permits its output to exactly alias its input.
Removing `restrict` for this rule does not change the strict-code observations
below for either inspected compiler.

## Exact register-pressure rejection DAG

For `reject_register_pressure_avx2`, both compilers common-subexpression
eliminate the nine identical `a + b` operations into one `vaddps`. They then
use that result repeatedly in the required left-associated additions. Neither
compiler spills or recomputes `a + b`, and neither reassociates the additions
under these strict flags. This is legal C optimization, but means that the C
compiler silently changes the source-level live-rack structure which Rake uses
as a checked contract.

## Unsupported vector operation

For `sin_array_scalar`, both compilers accept the ordinary loop and emit scalar
calls to `sinf`. Clang unrolls the loop four times but still makes four scalar
calls; GCC emits one scalar call per loop iteration. Neither emits packed SIMD
arithmetic. Rake's corresponding example rejects the unsupported rack-level
operation instead of accepting a scalar fallback.

## Secondary pressure stress

`pressure_sum_avx2` is intentionally a less minimal secondary stress case.
Clang 21.1.8 emits vector stack spills for its 24 loop-carried accumulators.
GCC 15.2.0 keeps the accumulator array stack-backed and updates it through
memory. It should not be presented as the primary apples-to-apples rejection
example.
