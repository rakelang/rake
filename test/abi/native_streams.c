#define _GNU_SOURCE
#include <fenv.h>
#include <stdbool.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include "../rounding_values.h"

/* Independently authored C descriptor for AMD64 and AAPCS64, including an unread byte
   column. Each populated column ends directly before inaccessible memory. */
typedef struct {
    const float *first, *second, *third, *fourth;
    const uint8_t *tag;
} rake_stack_Paired_v1;
typedef struct {
    float *first, *second, *third, *fourth;
    uint8_t *tag;
} rake_mut_stack_Paired_v1;
typedef struct {
    uint8_t *tag;
    float *value;
} rake_mut_stack_Roots_v1;
typedef struct {
    const uint8_t *tag;
    const int32_t *first, *second;
    const uint32_t *bits;
    const float *value;
} rake_stack_Words_v1;
typedef struct {
    uint8_t *tag;
    int32_t *first, *second;
    uint32_t *bits;
    float *value;
} rake_mut_stack_Words_v1;
typedef struct {
    int32_t *signed_value;
    uint8_t *tag;
    uint32_t *unsigned_value;
} rake_mut_stack_WordResults_v1;
typedef struct {
    const uint8_t *byte;
    const int16_t *small;
    const uint16_t *word;
    const int8_t *tiny;
    const int32_t *value;
} rake_stack_Compact_v1;
typedef struct {
    uint8_t *byte;
    int16_t *small;
    uint16_t *word;
    int8_t *tiny;
    int32_t *value;
} rake_mut_stack_Compact_v1;
extern void widened_words(const rake_stack_Compact_v1 *, int64_t, int32_t, int32_t *);
extern void widened_unsigned(const rake_stack_Compact_v1 *, int32_t, uint32_t *);
extern void widened_update(const rake_mut_stack_Compact_v1 *, int32_t, int32_t);
extern void widened_destination(const rake_stack_Compact_v1 *, int64_t,
    const rake_mut_stack_WordResults_v1 *);
extern void signed_words(const rake_stack_Words_v1 *, int32_t, int32_t *);
extern void unsigned_words(const rake_stack_Words_v1 *, int64_t, uint32_t, uint32_t, uint32_t *);
extern void shifted_words(const rake_stack_Words_v1 *, int32_t, int32_t *);
extern void reinterpreted_words(const rake_stack_Words_v1 *, int32_t, int32_t *);
extern void reinterpreted_unsigned(const rake_stack_Words_v1 *, int32_t, uint32_t *);
extern void selected_words(const rake_stack_Words_v1 *, int64_t, bool, int32_t *);
extern void update_words(const rake_mut_stack_Words_v1 *, int32_t, int32_t);
extern void write_words(const rake_stack_Words_v1 *, int64_t, const rake_mut_stack_WordResults_v1 *, bool);
extern void paired_roots(const rake_stack_Paired_v1 *, int32_t, float *);
extern void absolute_rows(const rake_stack_Paired_v1 *, int32_t, float *);
extern void minimum_rows(const rake_stack_Paired_v1 *, int64_t, float *);
extern void maximum_rows(const rake_stack_Paired_v1 *, int64_t, float *);
extern void floor_rows(const rake_stack_Paired_v1 *, int32_t, float *);
extern void ceil_rows(const rake_stack_Paired_v1 *, int32_t, float *);
extern void trunc_rows(const rake_stack_Paired_v1 *, int32_t, float *);
extern void nearest_rows(const rake_stack_Paired_v1 *, int32_t, float *);
extern void three_roots(const rake_stack_Paired_v1 *, int64_t, float *);
extern void four_roots(const rake_stack_Paired_v1 *, int64_t, float *);
extern void weighted_roots(const rake_stack_Paired_v1 *, int64_t, float, float, float, float *);
extern void signed_roots(const rake_stack_Paired_v1 *, int64_t, float, float *);
extern void integer_roots(const rake_stack_Paired_v1 *, int32_t,
    int32_t, float, uint32_t, bool, float, float *);
extern void integer_update(const rake_mut_stack_Paired_v1 *, int64_t,
    int32_t, float, float, uint32_t, float, bool);
extern void integer_destination(const rake_stack_Paired_v1 *, int64_t,
    const rake_mut_stack_Roots_v1 *, int32_t, float, uint32_t, bool);
extern void eight_uniforms(const rake_stack_Paired_v1 *, int64_t,
    float, float, float, float, float, float, float, float, float *);
extern void update_first(const rake_mut_stack_Paired_v1 *, int32_t, float, float);
extern void update_second(const rake_mut_stack_Paired_v1 *, int64_t, float, float);
extern void update_fourth(const rake_mut_stack_Paired_v1 *, int64_t);
extern void write_roots(const rake_stack_Paired_v1 *, int32_t,
    const rake_mut_stack_Roots_v1 *, float, float);
extern int rake_stream_program_main(void);

/* A conforming C caller may leave the upper half of an i32 register argument
   unspecified. Exercise that ABI property independently of GCC's usual
   zero-extending argument moves, for both positive and negative counts. */
extern void paired_roots_dirty_count(const rake_stack_Paired_v1 *, int32_t, float *);
extern void integer_roots_dirty_bool(const rake_stack_Paired_v1 *, int32_t,
    int32_t, float, uint32_t, bool, float, float *);
#if defined(__x86_64__)
__asm__(".text\n"
    ".globl paired_roots_dirty_count\n"
    ".type paired_roots_dirty_count, @function\n"
    "paired_roots_dirty_count:\n"
    "mov %esi, %esi\n"
    "movabs $0x5a5a5a5a00000000, %rax\n"
    "or %rax, %rsi\n"
    "jmp paired_roots\n"
    ".size paired_roots_dirty_count, .-paired_roots_dirty_count\n"
    ".globl integer_roots_dirty_bool\n"
    ".type integer_roots_dirty_bool, @function\n"
    "integer_roots_dirty_bool:\n"
    "movzbl %r8b, %r8d\n"
    "or $0x5a5a0100, %r8d\n"
    "jmp integer_roots\n"
    ".size integer_roots_dirty_bool, .-integer_roots_dirty_bool\n");
#elif defined(__aarch64__)
__asm__(".text\n"
    ".globl paired_roots_dirty_count\n"
    ".type paired_roots_dirty_count, %function\n"
    "paired_roots_dirty_count:\n"
    "mov w1, w1\n"
    "movz x9, #0x5a5a, lsl #32\n"
    "orr x1, x1, x9\n"
    "b paired_roots\n"
    ".size paired_roots_dirty_count, .-paired_roots_dirty_count\n"
    ".globl integer_roots_dirty_bool\n"
    ".type integer_roots_dirty_bool, %function\n"
    "integer_roots_dirty_bool:\n"
    "and w4, w4, #1\n"
    "orr w4, w4, #0x100\n"
    "movk w4, #0x5a5a, lsl #16\n"
    "b integer_roots\n"
    ".size integer_roots_dirty_bool, .-integer_roots_dirty_bool\n");
#else
#error Native traversal oracle requires AMD64 or AAPCS64
#endif

static uint32_t bits(float value)
{
    uint32_t result;
    memcpy(&result, &value, sizeof(result));
    return result;
}

static float root(float value)
{
    return value >= 0.0f ? sqrtf(value) : 0.0f;
}

static void check_widened_columns(unsigned char *const storage[5], size_t page)
{
    const uint8_t byte_values[] = { 0, 1, 127, 128, 255, 17, 254 };
    const int16_t small_values[] = { -32768, -1, 0, 1, 32767, 128, -128 };
    const uint16_t word_values[] = { 0, 1, 32767, 32768, 65535, 128, 65408 };
    const int8_t tiny_values[] = { -128, -1, 0, 1, 127, 17, -17 };
    const int32_t offsets[] = { INT32_MIN, -1, 0, INT32_MAX };
    for (size_t count = 0; count <= 65; ++count) {
        uint8_t *byte = storage[0] + page - count;
        int16_t *small = (int16_t *)(storage[1] + page) - count;
        uint16_t *word = (uint16_t *)(storage[2] + page) - count;
        int8_t *tiny = (int8_t *)(storage[3] + page) - count;
        uint32_t *output = (uint32_t *)(storage[4] + page) - count;
        const rake_stack_Compact_v1 input = { byte, small, word, tiny, NULL };
        const rake_mut_stack_Compact_v1 mutable_input = {
            byte, small, word, tiny, (int32_t *)output
        };
        const rake_mut_stack_WordResults_v1 destination = { NULL, NULL, output };
        for (size_t i = 0; i < count; ++i) {
            byte[i] = byte_values[(i + count) % 7];
            small[i] = small_values[(i + count + 1) % 7];
            word[i] = word_values[(i + count + 3) % 7];
            tiny[i] = tiny_values[(i + count + 5) % 7];
        }
        for (size_t scenario = 0; scenario < 4; ++scenario) {
            const int32_t offset = offsets[scenario];
            widened_words(&input, (int64_t)count, offset, (int32_t *)output);
            for (size_t i = 0; i < count; ++i) {
                const int64_t sum = (int64_t)byte[i] + small[i] + word[i] + tiny[i] + offset;
                if (output[i] != (uint32_t)sum) abort();
            }
            widened_update(&mutable_input, (int32_t)count, offset);
            for (size_t i = 0; i < count; ++i) {
                const int64_t sum = (int64_t)byte[i] + small[i] + word[i] + tiny[i] + offset;
                if (output[i] != (uint32_t)sum
                    || byte[i] != byte_values[(i + count) % 7]
                    || small[i] != small_values[(i + count + 1) % 7]
                    || word[i] != word_values[(i + count + 3) % 7]
                    || tiny[i] != tiny_values[(i + count + 5) % 7]) abort();
            }
        }
        widened_unsigned(&input, (int32_t)count, output);
        for (size_t i = 0; i < count; ++i) {
            const uint32_t expected = tiny[i] >= 0
                ? (uint32_t)byte[i] * word[i] : (uint32_t)byte[i] + word[i];
            if (output[i] != expected) abort();
        }
        widened_destination(&input, (int64_t)count, &destination);
        for (size_t i = 0; i < count; ++i)
            if (output[i] != (uint32_t)byte[i] + word[i]) abort();
    }
    widened_words(NULL, 0, INT32_MAX, NULL);
    widened_words(NULL, -1, INT32_MIN, NULL);
    widened_unsigned(NULL, INT32_MIN, NULL);
    widened_update(NULL, -1, INT32_MIN);
    widened_destination(NULL, 0, NULL);
}

static void check_integer_columns(unsigned char *const storage[5], size_t page)
{
    const uint32_t inputs[] = { 0, 1, 0x7fffffffu, 0x80000000u,
        0x80000001u, UINT32_MAX, 17, 0xfffffffdu, 0x40000000u };
    const uint32_t low = 0x80000000u, offset = UINT32_MAX;
    for (size_t count = 0; count <= 65; ++count) {
        int32_t *first = (int32_t *)(storage[0] + page) - count;
        int32_t *second = (int32_t *)(storage[1] + page) - count;
        uint32_t *words = (uint32_t *)(storage[2] + page) - count;
        float *values = (float *)(storage[3] + page) - count;
        uint32_t *output = (uint32_t *)(storage[4] + page) - count;
        uint32_t expected[65], original_first[65], original_second[65];
        const rake_stack_Words_v1 input = { NULL, first, second, words, values };
        const rake_mut_stack_Words_v1 mutable_input = { NULL, first, second, words, values };
        rake_mut_stack_WordResults_v1 destination = { NULL, NULL, output };
        for (size_t i = 0; i < count; ++i) {
            original_first[i] = inputs[(i + count) % 9];
            original_second[i] = inputs[(i + count + 3) % 9];
            memcpy(&first[i], &original_first[i], sizeof(int32_t));
            memcpy(&second[i], &original_second[i], sizeof(int32_t));
            words[i] = inputs[(i + count + 5) % 9];
            values[i] = i % 3 == 0 ? NAN : i % 3 == 1 ? -1.0f : 1.0f;
            const uint32_t magnitude = (uint32_t)(first[i] < 0 ? -(int64_t)first[i] : first[i]);
            expected[i] = first[i] < second[i]
                ? original_first[i] * original_second[i] : magnitude + original_second[i];
        }
        reinterpreted_words(&input, (int32_t)count, (int32_t *)output);
        for (size_t i = 0; i < count; ++i)
            if (output[i] != (words[i] >= 0x80000000u ? words[i] : words[i] + 1u)) abort();
        reinterpreted_unsigned(&input, (int32_t)count, output);
        for (size_t i = 0; i < count; ++i) {
            uint32_t original;
            memcpy(&original, &first[i], sizeof(original));
            if (output[i] != original + 1u) abort();
        }
        signed_words(&input, (int32_t)count, (int32_t *)output);
        for (size_t i = 0; i < count; ++i)
            if (output[i] != expected[i]) abort();
        shifted_words(&input, (int32_t)count, (int32_t *)output);
        for (size_t i = 0; i < count; ++i)
            if (output[i] != (first[i] < 0 ? UINT32_MAX : 0)) abort();
        unsigned_words(&input, (int64_t)count, low, offset, output);
        for (size_t i = 0; i < count; ++i) {
            uint32_t bounded = words[i] < low ? low : words[i];
            if (bounded == UINT32_MAX) --bounded;
            if (output[i] != bounded + offset) abort();
        }
        for (int enabled = 0; enabled < 2; ++enabled) {
            selected_words(&input, (int64_t)count, enabled != 0, (int32_t *)output);
            for (size_t i = 0; i < count; ++i) {
                expected[i] = enabled
                    ? (words[i] >= low ? original_first[i] : original_second[i])
                    : original_first[i] + 1u;
                if (output[i] != expected[i]) abort();
            }
            feclearexcept(FE_ALL_EXCEPT);
            write_words(&input, (int64_t)count, &destination, enabled != 0);
            if (fetestexcept(FE_ALL_EXCEPT)) abort();
            for (size_t i = 0; i < count; ++i) {
                expected[i] = enabled && !(values[i] >= 0.0f) ? words[i] + 1u : words[i];
                if (output[i] != expected[i]) abort();
            }
        }
        /* Every source rack is read before an aliased output column changes. */
        signed_words(&input, (int32_t)count, first);
        for (size_t i = 0; i < count; ++i) {
            int32_t original;
            memcpy(&original, &original_first[i], sizeof(original));
            const uint32_t magnitude = (uint32_t)(original < 0 ? -(int64_t)original : original);
            expected[i] = original < second[i]
                ? original_first[i] * original_second[i] : magnitude + original_second[i];
            uint32_t actual;
            memcpy(&actual, &first[i], sizeof(actual));
            if (actual != expected[i]) abort();
            memcpy(&first[i], &original_first[i], sizeof(int32_t));
        }
        update_words(&mutable_input, (int32_t)count, INT32_MAX);
        for (size_t i = 0; i < count; ++i) {
            const uint32_t magnitude = (uint32_t)(first[i] < 0 ? -(int64_t)first[i] : first[i]);
            uint32_t actual;
            memcpy(&actual, &second[i], sizeof(actual));
            if (actual != magnitude + (uint32_t)INT32_MAX) abort();
            memcpy(&actual, &first[i], sizeof(actual));
            if (actual != original_first[i] || words[i] != inputs[(i + count + 5) % 9]) abort();
        }
        destination.unsigned_value = words;
        write_words(&input, (int64_t)count, &destination, true);
        for (size_t i = 0; i < count; ++i) {
            const uint32_t expected_word = inputs[(i + count + 5) % 9] + (values[i] >= 0.0f ? 0u : 1u);
            if (words[i] != expected_word) abort();
        }
    }
    signed_words(NULL, 0, NULL);
    signed_words(NULL, INT32_MIN, NULL);
    unsigned_words(NULL, -1, low, offset, NULL);
    shifted_words(NULL, -1, NULL);
    selected_words(NULL, 0, true, NULL);
    update_words(NULL, -1, INT32_MIN);
    write_words(NULL, 0, NULL, true);
}

int main(void)
{
    if (rake_stream_program_main() != 160) abort();
    const size_t page = (size_t)sysconf(_SC_PAGESIZE);
    unsigned char *storage[5];
    for (size_t column = 0; column < 5; ++column) {
        storage[column] = mmap(NULL, page * 2, PROT_READ | PROT_WRITE,
            MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (storage[column] == MAP_FAILED
            || mprotect(storage[column] + page, page, PROT_NONE)) abort();
    }
    const float inputs[] = { -4.0f, -0.0f, 0.0f, 1.0f, 2.0f,
        INFINITY, -INFINITY, NAN, 25.0f, -1.0f, 0.25f };
    const struct { uint32_t left, right, minimum, maximum; int invalid; } extrema[] = {
        {0x00000000u, 0x80000000u, 0x80000000u, 0x00000000u, 0},
        {0x80000000u, 0x00000000u, 0x80000000u, 0x00000000u, 0},
        {0x80000001u, 0x00000001u, 0x80000001u, 0x00000001u, 0},
        {0x00000001u, 0x80000001u, 0x80000001u, 0x00000001u, 0},
        {0xbf800000u, 0x3f800000u, 0xbf800000u, 0x3f800000u, 0},
        {0x7f800000u, 0xff800000u, 0xff800000u, 0x7f800000u, 0},
        {0x7fc12345u, 0x3f800000u, 0x7fc00000u, 0x7fc00000u, 0},
        {0xbf800000u, 0xffc12345u, 0x7fc00000u, 0x7fc00000u, 0},
        {0x7f812345u, 0xbf800000u, 0x7fc00000u, 0x7fc00000u, 1},
        {0x3f800000u, 0xff812345u, 0x7fc00000u, 0x7fc00000u, 1}
    };
    for (size_t count = 0; count <= 65; ++count) {
        const float scale = (float)(count % 3 + 1);
        const float bias = (float)(count % 5) - 2.0f;
        const float threshold = (float)(count % 4);
        float *columns[5];
        for (size_t column = 0; column < 5; ++column)
            columns[column] = (float *)(storage[column] + page) - count;
        rake_stack_Paired_v1 stack = {
            columns[0], columns[1], columns[2], columns[3], NULL
        };
        void (*const round_rows[])(const rake_stack_Paired_v1 *, int32_t, float *) = {
            floor_rows, ceil_rows, trunc_rows, nearest_rows
        };
        const size_t round_count = sizeof(rounding_inputs) / sizeof(rounding_inputs[0]);
        for (int mode = ROUND_FLOOR; mode <= ROUND_NEAREST; ++mode) {
            int round_invalid = 0;
            for (size_t i = 0; i < count; ++i) {
                const uint32_t input = rounding_inputs[(i + count) % round_count];
                memcpy(&columns[0][i], &input, sizeof(float));
                round_invalid |= rounding_signaling(input);
            }
            feclearexcept(FE_ALL_EXCEPT);
            round_rows[mode](&stack, (int32_t)count, columns[4]);
            if (!!fetestexcept(FE_INVALID) != round_invalid
                || fetestexcept(FE_DIVBYZERO | FE_OVERFLOW | FE_UNDERFLOW)
                || (count == 0 && fetestexcept(FE_ALL_EXCEPT))) abort();
            for (size_t i = 0; i < count; ++i)
                if (!rounding_matches(bits(columns[4][i]),
                    rounding_expected(bits(columns[0][i]), mode))) abort();
        }
        int invalid = 0;
        for (size_t i = 0; i < count; ++i) {
            memcpy(&columns[0][i], &extrema[i % 10].left, sizeof(float));
            memcpy(&columns[1][i], &extrema[i % 10].right, sizeof(float));
            invalid |= extrema[i % 10].invalid;
        }
        for (int maximum = 0; maximum < 2; ++maximum) {
            feclearexcept(FE_ALL_EXCEPT);
            if (maximum) maximum_rows(&stack, (int64_t)count, columns[4]);
            else minimum_rows(&stack, (int64_t)count, columns[4]);
            if (!!fetestexcept(FE_INVALID) != invalid
                || fetestexcept(FE_DIVBYZERO | FE_OVERFLOW | FE_UNDERFLOW | FE_INEXACT)) abort();
            for (size_t i = 0; i < count; ++i) {
                const uint32_t expected = maximum ? extrema[i % 10].maximum : extrema[i % 10].minimum;
                const uint32_t actual = bits(columns[4][i]);
                if (expected == 0x7fc00000u) {
                    if ((actual & 0x7fc00000u) != 0x7fc00000u) abort();
                } else if (actual != expected) abort();
            }
        }
        float expected_pair[65], expected_three[65], expected_four[65];
        for (size_t i = 0; i < count; ++i) {
            for (size_t column = 0; column < 4; ++column)
                columns[column][i] = inputs[(i + column * 3) % 11];
            expected_pair[i] = root(columns[0][i]) + root(columns[1][i]);
            expected_three[i] = expected_pair[i] + root(columns[2][i]);
            expected_four[i] = expected_three[i] + root(columns[3][i]);
        }
        feclearexcept(FE_ALL_EXCEPT);
        absolute_rows(&stack, (int32_t)count, columns[4]);
        if (fetestexcept(FE_ALL_EXCEPT)) abort();
        for (size_t i = 0; i < count; ++i)
            if (bits(columns[4][i]) != bits(fabsf(columns[0][i]))) abort();
        paired_roots(&stack, (int32_t)count, columns[4]);
        for (size_t i = 0; i < count; ++i)
            if (bits(columns[4][i]) != bits(expected_pair[i])) abort();
        paired_roots_dirty_count(&stack, (int32_t)count, columns[4]);
        for (size_t i = 0; i < count; ++i)
            if (bits(columns[4][i]) != bits(expected_pair[i])) abort();
        three_roots(&stack, (int64_t)count, columns[4]);
        for (size_t i = 0; i < count; ++i)
            if (bits(columns[4][i]) != bits(expected_three[i])) abort();
        four_roots(&stack, (int64_t)count, columns[4]);
        for (size_t i = 0; i < count; ++i)
            if (bits(columns[4][i]) != bits(expected_four[i])) abort();
        four_roots(&stack, (int64_t)count, columns[0]);
        for (size_t i = 0; i < count; ++i)
            if (bits(columns[0][i]) != bits(expected_four[i])) abort();
        if (fetestexcept(FE_INVALID | FE_DIVBYZERO | FE_OVERFLOW)) abort();
        /* A mutable descriptor has no separate output pointer. Only its
           selected column changes; every rack sees the pre-update inputs. */
        uint32_t original[4][65];
        for (size_t i = 0; i < count; ++i) {
            for (size_t column = 0; column < 4; ++column) {
                columns[column][i] = inputs[(i + column * 3) % 11];
                original[column][i] = bits(columns[column][i]);
            }
            expected_pair[i] = root(columns[0][i]) * scale + bias;
        }
        rake_mut_stack_Paired_v1 mutable_stack = {
            columns[0], columns[1], columns[2], columns[3], NULL
        };
        feclearexcept(FE_ALL_EXCEPT);
        update_first(&mutable_stack, (int32_t)count, scale, bias);
        if (fetestexcept(FE_INVALID | FE_DIVBYZERO | FE_OVERFLOW)) abort();
        for (size_t i = 0; i < count; ++i) {
            if (bits(columns[0][i]) != bits(expected_pair[i])) abort();
            for (size_t column = 1; column < 4; ++column)
                if (bits(columns[column][i]) != original[column][i]) abort();
            columns[0][i] = inputs[i % 11];
            original[0][i] = bits(columns[0][i]);
            expected_four[i] = ((root(columns[0][i]) + root(columns[1][i]))
                + root(columns[2][i])) + root(columns[3][i]);
        }
        feclearexcept(FE_ALL_EXCEPT);
        update_fourth(&mutable_stack, (int64_t)count);
        for (size_t i = 0; i < count; ++i) {
            if (bits(columns[3][i]) != bits(expected_four[i])) abort();
            for (size_t column = 0; column < 3; ++column)
                if (bits(columns[column][i]) != original[column][i]) abort();
        }
        if (fetestexcept(FE_INVALID | FE_DIVBYZERO | FE_OVERFLOW)) abort();
        for (size_t i = 0; i < count; ++i) {
            columns[0][i] = inputs[i % 11];
            expected_pair[i] = root(columns[0][i]) * scale + bias;
        }
        rake_mut_stack_Paired_v1 two_columns = {
            columns[0], columns[1], NULL, NULL, NULL
        };
        feclearexcept(FE_ALL_EXCEPT);
        update_second(&two_columns, (int64_t)count, scale, bias);
        for (size_t i = 0; i < count; ++i)
            if (bits(columns[1][i]) != bits(expected_pair[i])
                || bits(columns[0][i]) != bits(inputs[i % 11])) abort();
        if (fetestexcept(FE_INVALID | FE_DIVBYZERO | FE_OVERFLOW)) abort();
        /* A separately shaped output descriptor puts its float column after
           an unused byte column. The kernel must use the destination layout. */
        rake_stack_Paired_v1 one_column = { columns[0], NULL, NULL, NULL, NULL };
        rake_mut_stack_Roots_v1 destination = { NULL, columns[4] };
        feclearexcept(FE_ALL_EXCEPT);
        write_roots(&one_column, (int32_t)count, &destination, scale, bias);
        for (size_t i = 0; i < count; ++i)
            if (bits(columns[4][i]) != bits(expected_pair[i])
                || bits(columns[0][i]) != bits(inputs[i % 11])) abort();
        if (fetestexcept(FE_INVALID | FE_DIVBYZERO | FE_OVERFLOW)) abort();
        destination.value = columns[0];
        write_roots(&one_column, (int32_t)count, &destination, scale, bias);
        for (size_t i = 0; i < count; ++i)
            if (bits(columns[0][i]) != bits(expected_pair[i])) abort();
        if (fetestexcept(FE_INVALID | FE_DIVBYZERO | FE_OVERFLOW)) abort();
        /* Refill after the in-place operation, then vary uniforms between
           calls. Both entry ABIs must preserve every argument over many racks. */
        for (size_t i = 0; i < count; ++i)
            columns[0][i] = inputs[i % 11];
        for (size_t i = 0; i < count; ++i) {
            expected_pair[i] = columns[0][i] >= threshold
                ? root(columns[0][i]) * scale + bias : 0.0f;
        }
        feclearexcept(FE_ALL_EXCEPT);
        weighted_roots(&stack, (int64_t)count, scale, bias, threshold, columns[4]);
        for (size_t i = 0; i < count; ++i)
            if (bits(columns[4][i]) != bits(expected_pair[i])) abort();
        weighted_roots(&stack, (int64_t)count, scale, bias, NAN, columns[4]);
        for (size_t i = 0; i < count; ++i)
            if (bits(columns[4][i]) != bits(0.0f)) abort();
        if (fetestexcept(FE_INVALID | FE_DIVBYZERO | FE_OVERFLOW)) abort();
        const float parameters[8] = {
            scale, bias, threshold, -0.5f, 0.25f, -2.0f, 4.0f, -8.0f
        };
        for (size_t i = 0; i < count; ++i) {
            for (size_t column = 0; column < 4; ++column)
                columns[column][i] = (float)((int)(i + column * 7) % 17 - 8);
            float expected = ((columns[0][i] + columns[1][i])
                + columns[2][i]) + columns[3][i];
            for (size_t uniform = 0; uniform < 8; ++uniform)
                expected += parameters[uniform];
            expected_four[i] = expected;
        }
        eight_uniforms(&stack, (int64_t)count,
            parameters[0], parameters[1], parameters[2], parameters[3],
            parameters[4], parameters[5], parameters[6], parameters[7], columns[0]);
        for (size_t i = 0; i < count; ++i)
            if (bits(columns[0][i]) != bits(expected_four[i])) abort();
        for (int scenario = 0; scenario < 3; ++scenario) {
            const int positive = scenario == 0;
            const float mode = positive ? 1.0f : scenario == 1 ? -1.0f : NAN;
            for (size_t i = 0; i < count; ++i) {
                const float magnitude = (float)((i + 1) * (i + 1));
                columns[0][i] = positive ? magnitude : -magnitude;
            }
            feclearexcept(FE_ALL_EXCEPT);
            signed_roots(&stack, (int64_t)count, mode, columns[4]);
            if (fetestexcept(FE_ALL_EXCEPT)) abort();
            for (size_t i = 0; i < count; ++i) {
                const float expected = (positive ? 1.0f : -1.0f) * (float)(i + 1);
                if (bits(columns[4][i]) != bits(expected)) abort();
            }
            signed_roots(&stack, (int64_t)count, mode, columns[0]);
            for (size_t i = 0; i < count; ++i) {
                const float expected = (positive ? 1.0f : -1.0f) * (float)(i + 1);
                if (bits(columns[0][i]) != bits(expected)) abort();
            }
        }
        const int32_t signed_modes[] = { INT32_MIN, -1, 0, INT32_MAX };
        const uint32_t pivots[] = { 0, 0x7fffffffu, 0x80000000u, UINT32_MAX };
        for (size_t scenario = 0; scenario < 32; ++scenario) {
            const bool positive = (scenario & 1) != 0;
            const int32_t mode = signed_modes[(scenario >> 1) & 3];
            const uint32_t pivot = pivots[(scenario >> 3) & 3];
            for (size_t i = 0; i < count; ++i) {
                const float magnitude = (float)((i + 1) * (i + 1));
                columns[0][i] = positive ? magnitude : -magnitude;
                columns[1][i] = (float)((i + 2) * (i + 2));
                expected_pair[i] = positive
                    ? (float)(mode < 0 || pivot >= 0x80000000u ? i + 1 : i + 2) * scale + bias
                    : -(float)(i + 1);
            }
            feclearexcept(FE_ALL_EXCEPT);
            integer_roots_dirty_bool(&stack, (int32_t)count,
                mode, scale, pivot, positive, bias, columns[4]);
            if (fetestexcept(FE_ALL_EXCEPT)) abort();
            for (size_t i = 0; i < count; ++i)
                if (bits(columns[4][i]) != bits(expected_pair[i])) abort();
            integer_roots(&stack, (int32_t)count,
                mode, scale, pivot, positive, bias, columns[0]);
            for (size_t i = 0; i < count; ++i)
                if (bits(columns[0][i]) != bits(expected_pair[i])) abort();
            /* Six persistent slots, interleaved C argument classes,
               and a separately shaped destination exercise distinct ABIs. */
            for (size_t i = 0; i < count; ++i) {
                columns[0][i] = (float)(i + 1);
                expected_pair[i] = columns[0][i];
                if (positive && mode < 0 && pivot >= 0x80000000u) {
                    expected_pair[i] += 1.0f;
                    expected_pair[i] += 2.0f;
                    expected_pair[i] += 3.0f;
                }
            }
            integer_update(&mutable_stack, (int64_t)count,
                mode, 1.0f, 2.0f, pivot, 3.0f, positive);
            for (size_t i = 0; i < count; ++i) {
                if (bits(columns[0][i]) != bits(expected_pair[i])) abort();
                if (positive && mode < 0 && pivot >= 0x80000000u)
                    expected_pair[i] *= scale;
            }
            destination.value = columns[4];
            integer_destination(&stack, (int64_t)count, &destination,
                mode, scale, pivot, positive);
            for (size_t i = 0; i < count; ++i)
                if (bits(columns[4][i]) != bits(expected_pair[i])) abort();
        }
    }
    paired_roots(NULL, 0, NULL);
    absolute_rows(NULL, 0, NULL);
    absolute_rows(NULL, -1, NULL);
    minimum_rows(NULL, 0, NULL);
    minimum_rows(NULL, -1, NULL);
    maximum_rows(NULL, 0, NULL);
    maximum_rows(NULL, -1, NULL);
    floor_rows(NULL, 0, NULL);
    floor_rows(NULL, -1, NULL);
    ceil_rows(NULL, 0, NULL);
    ceil_rows(NULL, -1, NULL);
    trunc_rows(NULL, 0, NULL);
    trunc_rows(NULL, -1, NULL);
    nearest_rows(NULL, 0, NULL);
    nearest_rows(NULL, -1, NULL);
    paired_roots(NULL, INT32_MIN, NULL);
    paired_roots_dirty_count(NULL, 0, NULL);
    paired_roots_dirty_count(NULL, -1, NULL);
    paired_roots_dirty_count(NULL, INT32_MIN, NULL);
    four_roots(NULL, -1, NULL);
    eight_uniforms(NULL, 0, 1.0f, 2.0f, 3.0f, 4.0f, 5.0f, 6.0f, 7.0f, 8.0f, NULL);
    weighted_roots(NULL, -1, NAN, NAN, NAN, NULL);
    signed_roots(NULL, 0, NAN, NULL);
    signed_roots(NULL, -1, NAN, NULL);
    integer_roots(NULL, 0, INT32_MIN, NAN, UINT32_MAX, true, NAN, NULL);
    integer_roots_dirty_bool(NULL, -1, INT32_MIN, NAN, UINT32_MAX, true, NAN, NULL);
    integer_update(NULL, -1, INT32_MIN, NAN, NAN, UINT32_MAX, NAN, true);
    integer_destination(NULL, 0, NULL, INT32_MIN, NAN, UINT32_MAX, true);
    update_first(NULL, 0, NAN, NAN);
    update_fourth(NULL, -1);
    update_second(NULL, -1, NAN, NAN);
    write_roots(NULL, 0, NULL, NAN, NAN);
    write_roots(NULL, -1, NULL, NAN, NAN);
    check_integer_columns(storage, page);
    check_widened_columns(storage, page);
    for (size_t column = 0; column < 5; ++column)
        if (munmap(storage[column], page * 2)) abort();
    puts("native multi-column guard-page and scalar-oracle checks passed");
    return 0;
}
