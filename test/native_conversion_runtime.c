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
extern integer_rack conversion_keep_integer(integer_rack);
extern integer_rack conversion_keep_float(float_rack);
extern float_rack masked_signed_to_float(float_rack, integer_rack);
extern float_rack masked_unsigned_to_float(float_rack, unsigned_rack);
extern integer_rack masked_float_to_signed(float_rack, float_rack);

typedef struct {
    const float    *values;
    const int32_t  *words;
    const int16_t  *compact;
    const uint32_t *unsigned_words;
} conversion_input;
typedef struct { const uint16_t *words; } compact_unsigned_input;
typedef struct { int32_t *words; float *values; } conversion_output;
extern void convert_to_signed(const conversion_input *, int32_t, int32_t *);
extern void convert_to_float(const conversion_input *, int64_t, float *);
extern void convert_compact(const conversion_input *, int32_t, float *);
extern void convert_unsigned(const conversion_input *, int32_t, float *);
extern void convert_unsigned_compact(const compact_unsigned_input *, int32_t, float *);
extern void unsigned_conversion_destination(const conversion_input *, int64_t, const conversion_output *);
extern void conversion_destination(const conversion_input *, int64_t, const conversion_output *);
extern void conversion_update(const conversion_output *, int32_t);

static const uint32_t edge_values[] = {
    0, 1, 0xffffffffu, 0x7fffffffu, 0x80000000u, 0x80000001u,
    16777215, 16777216, 16777217, 16777218, 16777219,
    0x4effffffu, 0x4f000000u, 0x4f000001u,
    0xceffffffu, 0xcf000000u, 0xcf000001u,
    65535, 65536, 65537, 0x8000007fu, 0x80000080u, 0x80000081u,
    0xffffff7fu, 0xffffff80u, 0xffffff81u
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
        int16_t *compact = (int16_t *)((char *)memory[2] + page) - count;
        uint32_t *output = (uint32_t *)((char *)memory[3] + page) - count;
        uint32_t *destination = (uint32_t *)((char *)memory[4] + page) - count;
        for (int32_t i = 0; i < count; ++i) {
            raw[i] = i % 2 ? rounding_inputs[(i + count) % rounding_count] : edge_values[(i + count) % edge_count];
            words[i] = edge_values[(i + count) % edge_count];
            compact[i] = (int16_t)(i * 1003 - 32000);
        }
        conversion_input input = { (const float *)raw, (const int32_t *)words, compact, words };
        conversion_output result = { (int32_t *)destination, (float *)raw };
        convert_to_signed(&input, count, (int32_t *)output);
        conversion_destination(&input, count, &result);
        for (int32_t i = 0; i < count; ++i) {
            check_word(output[i], expected_float_to_signed(raw[i]));
            check_word(destination[i], output[i]);
        }
        convert_to_float(&input, count, (float *)output);
        for (int32_t i = 0; i < count; ++i) check_word(output[i], expected_signed_to_float(words[i]));
        convert_compact(&input, count, (float *)output);
        for (int32_t i = 0; i < count; ++i) check_word(output[i], expected_signed_to_float((uint32_t)(int32_t)compact[i]));
        conversion_update(&result, count);
        for (int32_t i = 0; i < count; ++i) check_word(raw[i], expected_signed_to_float(destination[i]));
        convert_unsigned(&input, count, (float *)output);
        for (int32_t i = 0; i < count; ++i) check_word(output[i], expected_unsigned_to_float(words[i]));
        unsigned_conversion_destination(&input, count, &result);
        for (int32_t i = 0; i < count; ++i) check_word(raw[i], output[i]);
        compact_unsigned_input compact_input = { (const uint16_t *)compact };
        convert_unsigned_compact(&compact_input, count, (float *)output);
        for (int32_t i = 0; i < count; ++i)
            check_word(output[i], expected_unsigned_to_float((uint16_t)compact[i]));
        convert_unsigned(&input, count, (float *)words);
        for (int32_t i = 0; i < count; ++i)
            check_word(words[i], expected_unsigned_to_float(edge_values[(i + count) % edge_count]));
    }
    conversion_input inaccessible = { memory[0], memory[1], memory[2], memory[1] };
    convert_to_signed(&inaccessible, -1, NULL);
    convert_to_float(&inaccessible, -1, NULL);
    convert_unsigned(&inaccessible, -1, NULL);
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
