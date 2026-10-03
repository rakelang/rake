#define _GNU_SOURCE
#include <fenv.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

/* Independent C ABI oracle: one SoA pointer, a signed count and an output
   column. No C loop calls a register kernel. roots owns its entire loop. */
typedef struct { const float *value; } rake_stack_Samples_v1;
extern void roots(const rake_stack_Samples_v1 *, int64_t, float *);
extern void safe_root_c(const float *, float *, size_t);

static uint32_t bits(float value) {
    uint32_t result;
    memcpy(&result, &value, sizeof(result));
    return result;
}

static void check_tail_memory(void) {
    const size_t page = (size_t)sysconf(_SC_PAGESIZE);
    unsigned char *input = mmap(NULL, page * 2, PROT_READ | PROT_WRITE,
        MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    unsigned char *output = mmap(NULL, page * 2, PROT_READ | PROT_WRITE,
        MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (input == MAP_FAILED || output == MAP_FAILED ||
        mprotect(input + page, page, PROT_NONE) ||
        mprotect(output + page, page, PROT_NONE)) abort();
    const float special[] = { -4.0f, -0.0f, 0.0f, 1.0f, 2.0f,
        INFINITY, -INFINITY, NAN, 25.0f, -1.0f, 0.25f };
    for (size_t count = 0; count <= 65; ++count) {
        float *values = (float *)(input + page) - count;
        float *results = (float *)(output + page) - count;
        float expected[65];
        for (size_t i = 0; i < count; ++i) values[i] = special[i % 11];
        safe_root_c(values, expected, count);
        rake_stack_Samples_v1 stack = { values };
        feclearexcept(FE_ALL_EXCEPT);
        roots(&stack, (int64_t)count, results);
        if (fetestexcept(FE_INVALID | FE_DIVBYZERO | FE_OVERFLOW)) abort();
        for (size_t i = 0; i < count; ++i)
            if (bits(results[i]) != bits(expected[i])) abort();
        /* Exact in-place operation is defined. Other overlaps are excluded. */
        roots(&stack, (int64_t)count, values);
        for (size_t i = 0; i < count; ++i)
            if (bits(values[i]) != bits(expected[i])) abort();
    }
    roots(NULL, -1, NULL);
    munmap(input, page * 2);
    munmap(output, page * 2);
}

static double now(void) {
    struct timespec time;
    if (clock_gettime(CLOCK_MONOTONIC, &time)) abort();
    return time.tv_sec + time.tv_nsec * 1e-9;
}

static int order(const void *a, const void *b) {
    const double left = *(const double *)a, right = *(const double *)b;
    return (left > right) - (left < right);
}

int main(int argc, char **argv) {
    check_tail_memory();
    if (argc == 2 && strcmp(argv[1], "--check-only") == 0) {
        puts("native safe-root guard-page and scalar-oracle checks passed");
        return 0;
    }
    if (argc != 1) abort();
    const size_t count = 1000000;
    float *values = malloc((count + 3) * sizeof(float));
    float *expected = malloc((count + 3) * sizeof(float));
    float *actual = malloc((count + 3) * sizeof(float));
    if (!values || !expected || !actual) abort();
    uint32_t random = 0x31415926u;
    for (size_t i = 0; i < count + 3; ++i) {
        random ^= random << 13; random ^= random >> 17; random ^= random << 5;
        values[i] = (float)((int32_t)(random % 2000001u) - 1000000) * 0.001f;
    }
    rake_stack_Samples_v1 stack = { values };
    safe_root_c(values, expected, count + 3);
    roots(&stack, (int64_t)count + 3, actual);
    for (size_t i = 0; i < count + 3; ++i)
        if (bits(actual[i]) != bits(expected[i])) abort();
    double c_time[31], rake_time[31];
    for (int repeat = -4; repeat < 31; ++repeat) {
        for (int turn = 0; turn < 2; ++turn) {
            const int use_rake = (turn + repeat) & 1;
            const double start = now();
            /* Each pass is an external function call; no LTO or dead-code
               removal. Alternate the order, sharing inputs and warm caches. */
            for (int pass = 0; pass < 4; ++pass) {
                if (use_rake) roots(&stack, (int64_t)count, actual);
                else safe_root_c(values, expected, count);
            }
            const double elapsed = (now() - start) / 4;
            if (repeat >= 0) (use_rake ? rake_time : c_time)[repeat] = elapsed;
        }
    }
    qsort(c_time, 31, sizeof(double), order);
    qsort(rake_time, 31, sizeof(double), order);
    printf("elements\tc_median_ms\trake_median_ms\tc_over_rake\n");
    printf("%zu\t%.6f\t%.6f\t%.3f\n", count,
        c_time[15] * 1000, rake_time[15] * 1000, c_time[15] / rake_time[15]);
    volatile uint32_t checksum = bits(actual[count - 1]) ^ bits(expected[count - 1]);
    free(values); free(expected); free(actual);
    return checksum != 0;
}
