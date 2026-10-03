#define _GNU_SOURCE
#include <fenv.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

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
extern void paired_roots(const rake_stack_Paired_v1 *, int32_t, float *);
extern void absolute_rows(const rake_stack_Paired_v1 *, int32_t, float *);
extern void three_roots(const rake_stack_Paired_v1 *, int64_t, float *);
extern void four_roots(const rake_stack_Paired_v1 *, int64_t, float *);
extern void weighted_roots(const rake_stack_Paired_v1 *, int64_t, float, float, float, float *);
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
#if defined(__x86_64__)
__asm__(".text\n"
    ".globl paired_roots_dirty_count\n"
    ".type paired_roots_dirty_count, @function\n"
    "paired_roots_dirty_count:\n"
    "mov %esi, %esi\n"
    "movabs $0x5a5a5a5a00000000, %rax\n"
    "or %rax, %rsi\n"
    "jmp paired_roots\n"
    ".size paired_roots_dirty_count, .-paired_roots_dirty_count\n");
#elif defined(__aarch64__)
__asm__(".text\n"
    ".globl paired_roots_dirty_count\n"
    ".type paired_roots_dirty_count, %function\n"
    "paired_roots_dirty_count:\n"
    "mov w1, w1\n"
    "movz x9, #0x5a5a, lsl #32\n"
    "orr x1, x1, x9\n"
    "b paired_roots\n"
    ".size paired_roots_dirty_count, .-paired_roots_dirty_count\n");
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
    for (size_t count = 0; count <= 65; ++count) {
        const float scale = (float)(count % 3 + 1);
        const float bias = (float)(count % 5) - 2.0f;
        const float threshold = (float)(count % 4);
        float *columns[5];
        for (size_t column = 0; column < 5; ++column)
            columns[column] = (float *)(storage[column] + page) - count;
        float expected_pair[65], expected_three[65], expected_four[65];
        for (size_t i = 0; i < count; ++i) {
            for (size_t column = 0; column < 4; ++column)
                columns[column][i] = inputs[(i + column * 3) % 11];
            expected_pair[i] = root(columns[0][i]) + root(columns[1][i]);
            expected_three[i] = expected_pair[i] + root(columns[2][i]);
            expected_four[i] = expected_three[i] + root(columns[3][i]);
        }
        rake_stack_Paired_v1 stack = {
            columns[0], columns[1], columns[2], columns[3], NULL
        };
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
    }
    paired_roots(NULL, 0, NULL);
    absolute_rows(NULL, 0, NULL);
    absolute_rows(NULL, -1, NULL);
    paired_roots(NULL, INT32_MIN, NULL);
    paired_roots_dirty_count(NULL, 0, NULL);
    paired_roots_dirty_count(NULL, -1, NULL);
    paired_roots_dirty_count(NULL, INT32_MIN, NULL);
    four_roots(NULL, -1, NULL);
    eight_uniforms(NULL, 0, 1.0f, 2.0f, 3.0f, 4.0f, 5.0f, 6.0f, 7.0f, 8.0f, NULL);
    weighted_roots(NULL, -1, NAN, NAN, NAN, NULL);
    update_first(NULL, 0, NAN, NAN);
    update_fourth(NULL, -1);
    update_second(NULL, -1, NAN, NAN);
    write_roots(NULL, 0, NULL, NAN, NAN);
    write_roots(NULL, -1, NULL, NAN, NAN);
    for (size_t column = 0; column < 5; ++column)
        if (munmap(storage[column], page * 2)) abort();
    puts("native multi-column guard-page and scalar-oracle checks passed");
    return 0;
}
