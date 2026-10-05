#define _GNU_SOURCE
#include <fenv.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include "conversion_values.h"
#include "rounding_values.h"

typedef float float_rack __attribute__((vector_size(4 * LANES)));
typedef int32_t integer_rack __attribute__((vector_size(4 * LANES)));
typedef uint32_t unsigned_rack __attribute__((vector_size(4 * LANES)));
extern float_rack signed_to_float(integer_rack);
extern float_rack unsigned_to_float(unsigned_rack);
extern float_rack conversion_keep_unsigned(unsigned_rack);
extern integer_rack float_to_signed(float_rack);
extern unsigned_rack float_to_unsigned(float_rack);
extern unsigned_rack conversion_unsigned_roundtrip(unsigned_rack);
extern integer_rack conversion_keep_integer(integer_rack);
extern integer_rack conversion_keep_float(float_rack);
extern unsigned_rack conversion_keep_unsigned_float(float_rack);
extern float_rack masked_signed_to_float(float_rack, integer_rack);
extern float_rack masked_unsigned_to_float(float_rack, unsigned_rack);
extern integer_rack masked_float_to_signed(float_rack, float_rack);
extern unsigned_rack masked_float_to_unsigned(float_rack, float_rack);

typedef struct {
    int64_t count;
    float    *values;
    int32_t  *words;
    int16_t  *small;
    uint32_t *unsigned_words;
} conversion_input;
typedef struct { int64_t count; uint16_t *words; } compact_unsigned_input;
typedef struct { int64_t count; int32_t *words; float *values; uint32_t *unsigned_words; } conversion_output;
extern void convert_to_signed(const conversion_input *, conversion_output *);
extern void convert_to_unsigned(const conversion_input *, conversion_output *);
extern void unsigned_conversion_update(conversion_output *);
extern void convert_to_float(const conversion_input *, conversion_output *);
extern void convert_compact(const conversion_input *, conversion_output *);
extern void conversion_update(conversion_output *);
extern void convert_unsigned(const conversion_input *, conversion_output *);
extern void convert_unsigned_compact(const compact_unsigned_input *, conversion_output *);

static const uint32_t edge_values[] = {
    0, 1, 0xffffffffu, 0x7fffffffu, 0x80000000u, 0x80000001u,
    16777215, 16777216, 16777217, 16777218, 16777219,
    0x4effffffu, 0x4f000000u, 0x4f000001u,
    0xceffffffu, 0xcf000000u, 0xcf000001u,
    65535, 65536, 65537, 0x8000007fu, 0x80000080u, 0x80000081u,
    0xffffff7fu, 0xffffff80u, 0xffffff81u,
    0x4f7fffffu, 0x4f800000u, 0x4f800001u
};

static void check_word(uint32_t actual, uint32_t expected)
{
    if (actual != expected) {
        fprintf(stderr, "conversion bits: %08x != %08x\n", actual, expected);
        abort();
    }
}

static void check_registers(void)
{
    uint32_t random = 0x219da482u;
    const size_t rounding_count = sizeof(rounding_inputs) / sizeof(rounding_inputs[0]);
    const size_t edge_count = sizeof(edge_values) / sizeof(edge_values[0]);
    for (size_t sample = 0; sample < 4096; ++sample) {
        uint32_t raw[LANES], words[LANES], result[LANES];
        float selector[LANES];
        for (unsigned lane = 0; lane < LANES; ++lane) {
            random = random * 1664525u + 1013904223u;
            raw[lane] = sample < rounding_count ? rounding_inputs[(sample + lane) % rounding_count]
                : sample < rounding_count + edge_count ? edge_values[(sample + lane) % edge_count] : random;
            words[lane] = sample < edge_count ? edge_values[(sample + lane) % edge_count] : random;
        }
        float_rack floats; integer_rack integers;
        memcpy(&floats, raw, sizeof(floats)); memcpy(&integers, words, sizeof(integers));
        float_rack converted_float = signed_to_float(integers);
        memcpy(result, &converted_float, sizeof(result));
        for (unsigned lane = 0; lane < LANES; ++lane)
            check_word(result[lane], expected_signed_to_float(words[lane]));
        unsigned_rack unsigned_integers; memcpy(&unsigned_integers, words, sizeof(unsigned_integers));
        converted_float = unsigned_to_float(unsigned_integers);
        memcpy(result, &converted_float, sizeof(result));
        for (unsigned lane = 0; lane < LANES; ++lane)
            check_word(result[lane], expected_unsigned_to_float(words[lane]));
        converted_float = conversion_keep_unsigned(unsigned_integers);
        memcpy(result, &converted_float, sizeof(result));
        for (unsigned lane = 0; lane < LANES; ++lane) {
            const uint32_t first_bits = expected_unsigned_to_float(words[lane]);
            const uint32_t second_bits = expected_unsigned_to_float(words[lane] + 1u);
            float first, second, sum;
            memcpy(&first, &first_bits, sizeof(first)); memcpy(&second, &second_bits, sizeof(second));
            sum = first + second;
            uint32_t expected; memcpy(&expected, &sum, sizeof(expected));
            check_word(result[lane], expected);
        }
        integer_rack retained = conversion_keep_integer(integers);
        memcpy(result, &retained, sizeof(result));
        for (unsigned lane = 0; lane < LANES; ++lane)
            check_word(result[lane], words[lane] + expected_float_to_signed(expected_signed_to_float(words[lane])));
        unsigned_rack unsigned_retained = conversion_unsigned_roundtrip(unsigned_integers);
        memcpy(result, &unsigned_retained, sizeof(result));
        for (unsigned lane = 0; lane < LANES; ++lane)
            check_word(result[lane], words[lane] + expected_float_to_unsigned(expected_unsigned_to_float(words[lane])));
        for (int phase = -1; phase < 3; ++phase) {
            int invalid = 0;
            for (unsigned lane = 0; lane < LANES; ++lane) {
                const int active = phase < 0 || (phase < 2 && (lane + (unsigned)phase) % 2 == 0);
                selector[lane] = active ? 1.0f : -1.0f;
                invalid |= active && rounding_signaling(raw[lane]);
            }
            float_rack mask; memcpy(&mask, selector, sizeof(mask));
            feclearexcept(FE_ALL_EXCEPT);
            integer_rack converted = phase < 0 ? float_to_signed(floats) : masked_float_to_signed(mask, floats);
            memcpy(result, &converted, sizeof(result));
            if (!!fetestexcept(FE_INVALID) != invalid
                || fetestexcept(FE_DIVBYZERO | FE_OVERFLOW | FE_UNDERFLOW)
                || (phase == 2 && fetestexcept(FE_ALL_EXCEPT))) abort();
            for (unsigned lane = 0; lane < LANES; ++lane) {
                const int active = phase < 0 || (phase < 2 && (lane + (unsigned)phase) % 2 == 0);
                check_word(result[lane], active ? expected_float_to_signed(raw[lane]) : 0xfffffffeu);
            }
            feclearexcept(FE_ALL_EXCEPT);
            unsigned_rack unsigned_converted = phase < 0 ? float_to_unsigned(floats) : masked_float_to_unsigned(mask, floats);
            memcpy(result, &unsigned_converted, sizeof(result));
            if (!!fetestexcept(FE_INVALID) != invalid
                || fetestexcept(FE_DIVBYZERO | FE_OVERFLOW | FE_UNDERFLOW)
                || (phase == 2 && fetestexcept(FE_ALL_EXCEPT))) abort();
            for (unsigned lane = 0; lane < LANES; ++lane) {
                const int active = phase < 0 || (phase < 2 && (lane + (unsigned)phase) % 2 == 0);
                check_word(result[lane], active ? expected_float_to_unsigned(raw[lane]) : 0xfffffffeu);
            }
            feclearexcept(FE_ALL_EXCEPT);
            converted_float = masked_signed_to_float(mask, integers);
            memcpy(result, &converted_float, sizeof(result));
            if (phase == 2 && fetestexcept(FE_ALL_EXCEPT)) abort();
            for (unsigned lane = 0; lane < LANES; ++lane)
                check_word(result[lane], selector[lane] > 0 ? expected_signed_to_float(words[lane]) : 0xc0000000u);
            feclearexcept(FE_ALL_EXCEPT);
            converted_float = masked_unsigned_to_float(mask, unsigned_integers);
            memcpy(result, &converted_float, sizeof(result));
            if (fetestexcept(FE_INVALID | FE_DIVBYZERO | FE_OVERFLOW | FE_UNDERFLOW)
                || (phase == 2 && fetestexcept(FE_ALL_EXCEPT))) abort();
            for (unsigned lane = 0; lane < LANES; ++lane)
                check_word(result[lane], selector[lane] > 0 ? expected_unsigned_to_float(words[lane]) : 0xc0000000u);
        }
    }
    float finite[LANES];
    for (unsigned lane = 0; lane < LANES; ++lane) finite[lane] = (float)lane - 3.5f;
    float_rack input; memcpy(&input, finite, sizeof(input));
    integer_rack retained = conversion_keep_float(input);
    uint32_t result[LANES]; memcpy(result, &retained, sizeof(result));
    for (unsigned lane = 0; lane < LANES; ++lane) {
        const float shifted = finite[lane] + 0.25f;
        uint32_t first, second;
        memcpy(&first, &finite[lane], sizeof(first)); memcpy(&second, &shifted, sizeof(second));
        check_word(result[lane], expected_float_to_signed(first) + expected_float_to_signed(second));
    }
    unsigned_rack unsigned_retained = conversion_keep_unsigned_float(input);
    memcpy(result, &unsigned_retained, sizeof(result));
    for (unsigned lane = 0; lane < LANES; ++lane) {
        const float shifted = finite[lane] + 0.25f;
        uint32_t first, second;
        memcpy(&first, &finite[lane], sizeof(first)); memcpy(&second, &shifted, sizeof(second));
        check_word(result[lane], expected_float_to_unsigned(first) + expected_float_to_unsigned(second));
    }
}

static void check_streams(void)
{
    const size_t page = (size_t)sysconf(_SC_PAGESIZE);
    void *memory[5];
    for (unsigned i = 0; i < 5; ++i) {
        memory[i] = mmap(NULL, 2 * page, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (memory[i] == MAP_FAILED || mprotect((char *)memory[i] + page, page, PROT_NONE)) abort();
    }
    const size_t edge_count = sizeof(edge_values) / sizeof(edge_values[0]);
    const size_t rounding_count = sizeof(rounding_inputs) / sizeof(rounding_inputs[0]);
    for (int32_t count = 0; count <= 65; ++count) {
        uint32_t *raw = (uint32_t *)((char *)memory[0] + page) - count;
        uint32_t *words = (uint32_t *)((char *)memory[1] + page) - count;
        int16_t *small = (int16_t *)((char *)memory[2] + page) - count;
        uint32_t *output = (uint32_t *)((char *)memory[3] + page) - count;
        uint32_t *destination = (uint32_t *)((char *)memory[4] + page) - count;
        for (int32_t i = 0; i < count; ++i) {
            raw[i] = i % 2 ? rounding_inputs[(i + count) % rounding_count] : edge_values[(i + count) % edge_count];
            words[i] = edge_values[(i + count) % edge_count];
            small[i] = (int16_t)(i * 1003 - 32000);
        }
        conversion_input input = { count, (float *)raw, (int32_t *)words, small, words };
        conversion_output out = { count, (int32_t *)output, (float *)output, output };
        conversion_output result = { count, (int32_t *)destination, (float *)raw, destination };
        convert_to_unsigned(&input, &out);
        for (int32_t i = 0; i < count; ++i) check_word(output[i], expected_float_to_unsigned(raw[i]));
        convert_to_unsigned(&input, &result);
        for (int32_t i = 0; i < count; ++i) check_word(destination[i], output[i]);
        unsigned_conversion_update(&result);
        for (int32_t i = 0; i < count; ++i)
            check_word(destination[i], expected_float_to_unsigned(expected_unsigned_to_float(output[i])));
        convert_to_signed(&input, &out);
        for (int32_t i = 0; i < count; ++i) check_word(output[i], expected_float_to_signed(raw[i]));
        convert_to_signed(&input, &result);
        for (int32_t i = 0; i < count; ++i) check_word(destination[i], output[i]);
        convert_to_float(&input, &out);
        for (int32_t i = 0; i < count; ++i) check_word(output[i], expected_signed_to_float(words[i]));
        convert_compact(&input, &out);
        for (int32_t i = 0; i < count; ++i) check_word(output[i], expected_signed_to_float((uint32_t)(int32_t)small[i]));
        /* The result's values column is the input's values column, element for element. */
        conversion_update(&result);
        for (int32_t i = 0; i < count; ++i) {
            const uint32_t original = i % 2 ? rounding_inputs[(i + count) % rounding_count] : edge_values[(i + count) % edge_count];
            check_word(raw[i], expected_signed_to_float(expected_float_to_signed(original)));
            raw[i] = original;
        }
        convert_unsigned(&input, &out);
        for (int32_t i = 0; i < count; ++i) check_word(output[i], expected_unsigned_to_float(words[i]));
        compact_unsigned_input compact_input = { count, (uint16_t *)small };
        convert_unsigned_compact(&compact_input, &out);
        for (int32_t i = 0; i < count; ++i)
            check_word(output[i], expected_unsigned_to_float((uint16_t)small[i]));
        /* Exact in-place results over input columns. */
        conversion_output over_raw = { count, NULL, NULL, raw };
        convert_to_unsigned(&input, &over_raw);
        for (int32_t i = 0; i < count; ++i)
            check_word(raw[i], expected_float_to_unsigned(i % 2 ? rounding_inputs[(i + count) % rounding_count] : edge_values[(i + count) % edge_count]));
        conversion_output over_words = { count, NULL, (float *)words, NULL };
        convert_unsigned(&input, &over_words);
        for (int32_t i = 0; i < count; ++i)
            check_word(words[i], expected_unsigned_to_float(edge_values[(i + count) % edge_count]));
    }
    conversion_input inaccessible = { -1, memory[0], memory[1], memory[2], memory[1] };
    conversion_output none = { -1, NULL, NULL, NULL };
    convert_to_signed(&inaccessible, &none);
    convert_to_unsigned(&inaccessible, &none);
    convert_to_float(&inaccessible, &none);
    convert_unsigned(&inaccessible, &none);
    for (unsigned i = 0; i < 5; ++i) if (munmap(memory[i], 2 * page)) abort();
}

int main(void)
{
    if (fesetround(FE_TONEAREST)) abort();
    check_registers();
    check_streams();
    puts("signed/unsigned conversions, masks, retained inputs and guard-page streams passed");
    return 0;
}
