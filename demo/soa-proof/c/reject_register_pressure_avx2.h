#ifndef RAKE_DEMO_SOA_PROOF_C_REJECT_REGISTER_PRESSURE_AVX2_H
#define RAKE_DEMO_SOA_PROOF_C_REJECT_REGISTER_PRESSURE_AVX2_H

#include <immintrin.h>

#if !defined(__AVX2__)
#error "reject_register_pressure_avx2.h requires compilation with AVX2 enabled"
#endif

/* This deliberately mirrors the Rake rejection example.  It contains no
 * volatile objects, barriers, inline assembly, or other optimization controls.
 */
__m256 reject_register_pressure_avx2(__m256 a, __m256 b, __m256 c, __m256 d,
                                    __m256 e, __m256 f, __m256 g, __m256 h);

#endif
