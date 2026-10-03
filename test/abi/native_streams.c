#define _GNU_SOURCE
#include <fenv.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

/* Independently authored System V descriptor, including an unread byte
   column. Each populated column ends directly before inaccessible memory. */
typedef struct {
    const float *first, *second, *third, *fourth;
    const uint8_t *tag;
} rake_stack_Paired_v1;
extern void paired_roots(const rake_stack_Paired_v1 *, int64_t, float *);
extern void four_roots(const rake_stack_Paired_v1 *, int64_t, float *);

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
        float *columns[5];
        for (size_t column = 0; column < 5; ++column)
            columns[column] = (float *)(storage[column] + page) - count;
        float expected_pair[65], expected_four[65];
        for (size_t i = 0; i < count; ++i) {
            for (size_t column = 0; column < 4; ++column)
                columns[column][i] = inputs[(i + column * 3) % 11];
            expected_pair[i] = root(columns[0][i]) + root(columns[1][i]);
            expected_four[i] = (expected_pair[i] + root(columns[2][i]))
                              + root(columns[3][i]);
        }
        rake_stack_Paired_v1 stack = {
            columns[0], columns[1], columns[2], columns[3], NULL
        };
        feclearexcept(FE_ALL_EXCEPT);
        paired_roots(&stack, (int64_t)count, columns[4]);
        for (size_t i = 0; i < count; ++i)
            if (bits(columns[4][i]) != bits(expected_pair[i])) abort();
        four_roots(&stack, (int64_t)count, columns[4]);
        for (size_t i = 0; i < count; ++i)
            if (bits(columns[4][i]) != bits(expected_four[i])) abort();
        four_roots(&stack, (int64_t)count, columns[0]);
        for (size_t i = 0; i < count; ++i)
            if (bits(columns[0][i]) != bits(expected_four[i])) abort();
        if (fetestexcept(FE_INVALID | FE_DIVBYZERO | FE_OVERFLOW)) abort();
    }
    paired_roots(NULL, 0, NULL);
    four_roots(NULL, -1, NULL);
    for (size_t column = 0; column < 5; ++column)
        if (munmap(storage[column], page * 2)) abort();
    puts("native multi-column guard-page and scalar-oracle checks passed");
    return 0;
}
