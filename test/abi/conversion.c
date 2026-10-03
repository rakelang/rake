/* Independent bit-level numerical checks across the wasm32 vector ABI. */
#include <stdint.h>
#include <wasm_simd128.h>
#include "../conversion_values.h"

extern v128_t unsigned_to_float(v128_t);
extern v128_t masked_unsigned_to_float(v128_t, v128_t);
extern v128_t float_to_unsigned(v128_t);
extern v128_t masked_float_to_unsigned(v128_t, v128_t);

int test(void)
{
    uint32_t random = 0x81d73890u;
    const uint32_t boundaries[] = {
        0, 1, 65535, 65536, 16777215, 16777216, 16777217,
        0x7fffffffu, 0x80000000u, 0x8000007fu, 0x80000080u,
        0x80000081u, 0xffffff7fu, 0xffffff80u, 0xffffff81u, 0xffffffffu,
        0x3f000000u, 0x3f000001u, 0x3fc00000u, 0x40200000u,
        0x4effffffu, 0x4f000000u, 0x4f000001u, 0x4f7fffffu,
        0x4f800000u, 0x4f800001u, 0x7f800000u, 0xff800000u,
        0x7fc00000u, 0x7f800001u
    };
    const unsigned boundary_count = sizeof(boundaries) / sizeof(boundaries[0]);
    for (unsigned sample = 0; sample < 4096; ++sample) {
        uint32_t values[4], results[4];
        float selector[4];
        for (unsigned lane = 0; lane < 4; ++lane) {
            random = random * 1664525u + 1013904223u;
            values[lane] = sample < boundary_count ? boundaries[(sample + lane) % boundary_count] : random;
            selector[lane] = (sample + lane) % 2 ? 1.0f : -1.0f;
        }
        const v128_t input = wasm_v128_load(values);
        wasm_v128_store(results, unsigned_to_float(input));
        for (unsigned lane = 0; lane < 4; ++lane)
            if (results[lane] != expected_unsigned_to_float(values[lane])) return 1;
        wasm_v128_store(results, masked_unsigned_to_float(wasm_v128_load(selector), input));
        for (unsigned lane = 0; lane < 4; ++lane)
            if (results[lane] != (selector[lane] > 0.0f
                    ? expected_unsigned_to_float(values[lane]) : 0xc0000000u)) return 2;
        wasm_v128_store(results, float_to_unsigned(input));
        for (unsigned lane = 0; lane < 4; ++lane)
            if (results[lane] != expected_float_to_unsigned(values[lane])) return 3;
        wasm_v128_store(results, masked_float_to_unsigned(wasm_v128_load(selector), input));
        for (unsigned lane = 0; lane < 4; ++lane)
            if (results[lane] != (selector[lane] > 0.0f
                    ? expected_float_to_unsigned(values[lane]) : 0xfffffffeu)) return 4;
    }
    return 0;
}
