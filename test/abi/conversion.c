/* Independent bit-level numerical checks across the wasm32 vector ABI. */
#include <stdint.h>
#include <wasm_simd128.h>
#include "../conversion_values.h"

extern v128_t unsigned_to_float(v128_t);
extern v128_t masked_unsigned_to_float(v128_t, v128_t);

int test(void)
{
    uint32_t random = 0x81d73890u;
    const uint32_t boundaries[] = {
        0, 1, 65535, 65536, 16777215, 16777216, 16777217,
        0x7fffffffu, 0x80000000u, 0x8000007fu, 0x80000080u,
        0x80000081u, 0xffffff7fu, 0xffffff80u, 0xffffff81u, 0xffffffffu
    };
    for (unsigned sample = 0; sample < 4096; ++sample) {
        uint32_t values[4], results[4];
        float selector[4];
        for (unsigned lane = 0; lane < 4; ++lane) {
            random = random * 1664525u + 1013904223u;
            values[lane] = sample < 16 ? boundaries[(sample + lane) % 16] : random;
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
    }
    return 0;
}
