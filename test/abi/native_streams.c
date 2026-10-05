#define _GNU_SOURCE
#include <fenv.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

/* Independently authored C descriptors for AMD64 and AAPCS64. Every
   populated column ends directly before inaccessible memory. */
typedef struct { int64_t count; float *value; uint8_t *tag; } Samples;
typedef struct { int64_t count; uint8_t *tag; float *root; } Roots;
typedef struct { int64_t count; float *first, *second; } Pair;
typedef struct { int64_t count; uint8_t *tag; int32_t *first, *second; uint32_t *bits; float *value; } Words;
typedef struct { int64_t count; uint8_t *byte; int16_t *small; uint16_t *word; int8_t *tiny; int32_t *total; } Compact;
typedef struct { int64_t count; float *x, *v; uint8_t *alive; int16_t *charge; uint32_t *id; } Particle;

extern void roots(const Samples *, Roots *, float, float);
extern void sum_and_difference(Pair *);
extern void combine(Compact *, int32_t);
extern void integer_mix(Words *, int32_t, float, uint32_t, bool, float);
extern void eight_uniforms(Pair *, float, float, float, float, float, float, float, float);
extern void repeated(Words *);
extern void advance(Particle *, float);
extern void survivors(Particle *);
extern void fast_survivors(Particle *, float);
extern int rake_stream_program_main(void);

/* A conforming C caller may leave the bits above a bool unspecified. */
extern void integer_mix_dirty_bool(Words *, int32_t, float, uint32_t, bool, float);
#if defined(__x86_64__)
__asm__(".text\n"
    ".globl integer_mix_dirty_bool\n"
    ".type integer_mix_dirty_bool, @function\n"
    "integer_mix_dirty_bool:\n"
    "movzbl %cl, %ecx\n"
    "or $0x5a5a0100, %ecx\n"
    "jmp integer_mix\n"
    ".size integer_mix_dirty_bool, .-integer_mix_dirty_bool\n");
#elif defined(__aarch64__)
__asm__(".text\n"
    ".globl integer_mix_dirty_bool\n"
    ".type integer_mix_dirty_bool, %function\n"
    "integer_mix_dirty_bool:\n"
    "and w3, w3, #1\n"
    "orr w3, w3, #0x100\n"
    "movk w3, #0x5a5a, lsl #16\n"
    "b integer_mix\n"
    ".size integer_mix_dirty_bool, .-integer_mix_dirty_bool\n");
#else
#error Native stack run oracle requires AMD64 or AAPCS64
#endif

enum { SLOTS = 6 };
static unsigned char *storage[SLOTS];
static size_t page;

/* Count elements of the given size ending at slot's guard page. */
static void *guarded(int slot, size_t count, size_t size)
{
    return storage[slot] + page - count * size;
}

static uint32_t bits(float value)
{
    uint32_t result;
    memcpy(&result, &value, sizeof result);
    return result;
}

static float root(float value) { return value >= 0.0f ? sqrtf(value) : 0.0f; }

static void check_roots(size_t count)
{
    const float inputs[] = { -4.0f, -0.0f, 0.0f, 1.0f, 25.0f, INFINITY, -INFINITY, NAN };
    float *value = guarded(0, count, 4), *out = guarded(1, count, 4);
    uint8_t *tag = guarded(2, count, 1), *out_tag = guarded(3, count, 1);
    for (size_t i = 0; i < count; ++i) { value[i] = inputs[(i + count) % 8]; tag[i] = 7; out_tag[i] = 9; }
    const Samples input = { (int64_t)count, value, tag };
    Roots output = { (int64_t)count, out_tag, out };
    feclearexcept(FE_ALL_EXCEPT);
    roots(&input, &output, 2.0f, 3.0f);
    if (fetestexcept(FE_INVALID | FE_DIVBYZERO | FE_OVERFLOW)) abort();
    if (output.count != (int64_t)count) abort();
    for (size_t i = 0; i < count; ++i) {
        if (bits(out[i]) != bits(root(value[i]) * 2.0f + 3.0f)) abort();
        if (out_tag[i] != 9 || tag[i] != 7) abort();
    }
    /* The result may be the same column as an input, element for element. */
    Roots in_place = { (int64_t)count, out_tag, value };
    roots(&input, &in_place, 1.0f, 0.0f);
    for (size_t i = 0; i < count; ++i)
        if (bits(value[i]) != bits(root(inputs[(i + count) % 8]) * 1.0f + 0.0f)) abort();
}

static void check_pairs(size_t count)
{
    float *first = guarded(0, count, 4), *second = guarded(1, count, 4);
    for (size_t i = 0; i < count; ++i) { first[i] = (float)i * 0.5f; second[i] = (float)(count - i); }
    Pair pair = { (int64_t)count, first, second };
    sum_and_difference(&pair);
    for (size_t i = 0; i < count; ++i) {
        const float a = (float)i * 0.5f, b = (float)(count - i);
        if (bits(first[i]) != bits(a + b) || bits(second[i]) != bits(a - b)) abort();
    }
    eight_uniforms(&pair, 1.0f, 2.0f, 3.0f, 4.0f, 5.0f, 6.0f, 7.0f, 8.0f);
    for (size_t i = 0; i < count; ++i) {
        float expected = first[i];
        for (int k = 1; k <= 8; ++k) expected += (float)k;
        if (bits(second[i]) != bits(expected)) abort();
    }
}

static void check_compact_columns(size_t count)
{
    const uint8_t byte_values[] = { 0, 1, 127, 128, 255, 17, 254 };
    const int16_t small_values[] = { -32768, -1, 0, 1, 32767, 128, -128 };
    const uint16_t word_values[] = { 0, 1, 32767, 32768, 65535, 128, 65408 };
    const int8_t tiny_values[] = { -128, -1, 0, 1, 127, 17, -17 };
    uint8_t *byte = guarded(0, count, 1);
    int16_t *small = guarded(1, count, 2);
    uint16_t *word = guarded(2, count, 2);
    int8_t *tiny = guarded(3, count, 1);
    int32_t *total = guarded(4, count, 4);
    for (size_t i = 0; i < count; ++i) {
        byte[i] = byte_values[(i + count) % 7];
        small[i] = small_values[(i + count + 1) % 7];
        word[i] = word_values[(i + count + 3) % 7];
        tiny[i] = tiny_values[(i + count + 5) % 7];
    }
    Compact compact = { (int64_t)count, byte, small, word, tiny, total };
    combine(&compact, INT32_MAX);
    for (size_t i = 0; i < count; ++i) {
        const uint32_t expected = (uint32_t)byte[i] + (uint32_t)(int32_t)small[i] + (uint32_t)word[i]
            + (uint32_t)(int32_t)tiny[i] + (uint32_t)INT32_MAX;
        if ((uint32_t)total[i] != expected) abort();
    }
}

static void check_words(size_t count)
{
    const uint32_t samples[] = { 0, 1, 0x7fffffffu, 0x80000000u, UINT32_MAX, 17 };
    const int32_t modes[] = { INT32_MIN, 0, 5 };
    const uint32_t pivots[] = { 0, 0x80000000u };
    int32_t *first = guarded(0, count, 4), *second = guarded(1, count, 4);
    uint32_t *word_bits = guarded(2, count, 4);
    float *value = guarded(3, count, 4);
    uint8_t *tag = guarded(4, count, 1);
    for (int m = 0; m < 3; ++m)
        for (int p = 0; p < 2; ++p)
            for (int positive = 0; positive < 2; ++positive) {
                for (size_t i = 0; i < count; ++i) {
                    memcpy(&first[i], &samples[(i + count) % 6], 4);
                    memcpy(&second[i], &samples[(i + count + 2) % 6], 4);
                    word_bits[i] = samples[(i + count + 4) % 6];
                    value[i] = (float)i - 3.0f;
                    tag[i] = 0;
                }
                Words words = { (int64_t)count, tag, first, second, word_bits, value };
                (positive & 1 ? integer_mix_dirty_bool : integer_mix)(&words, modes[m], 2.0f, pivots[p], positive, 0.5f);
                for (size_t i = 0; i < count; ++i) {
                    int32_t a, b;
                    memcpy(&a, &samples[(i + count) % 6], 4);
                    memcpy(&b, &samples[(i + count + 2) % 6], 4);
                    const int32_t chosen = modes[m] < 0 ? a : (pivots[p] >= 0x80000000u ? a : b);
                    const uint32_t magnitude = chosen < 0 ? 0u - (uint32_t)chosen : (uint32_t)chosen;
                    const int32_t expected_second = positive ? (int32_t)(magnitude + 7u) : chosen;
                    const uint32_t expected_bits = ((samples[(i + count + 4) % 6] << 3) >> 3) + 1u;
                    const float expected_value = positive ? ((float)i - 3.0f) * 2.0f + 0.5f : (float)i - 3.0f;
                    if (second[i] != expected_second || word_bits[i] != expected_bits || bits(value[i]) != bits(expected_value)) abort();
                }
            }
    for (size_t i = 0; i < count; ++i) memcpy(&first[i], &samples[(i + count) % 6], 4);
    Words words = { (int64_t)count, tag, first, second, word_bits, value };
    repeated(&words);
    for (size_t i = 0; i < count; ++i)
        if ((uint32_t)first[i] != samples[(i + count) % 6] * 59049u) abort();
}

static void fill_particles(size_t count, float *x, float *v, uint8_t *alive, int16_t *charge, uint32_t *id)
{
    for (size_t i = 0; i < count; ++i) {
        x[i] = (float)i;
        v[i] = (float)((int)(i % 7) - 3);
        alive[i] = (uint8_t)((i * 5 + count) % 3 != 0);
        charge[i] = (int16_t)(i % 2 ? -(int)(i * 1000) : (int)(i * 1000));
        id[i] = 0x80000000u + (uint32_t)i;
    }
}

static void check_particles(size_t count)
{
    float *x = guarded(0, count, 4), *v = guarded(1, count, 4);
    uint8_t *alive = guarded(2, count, 1);
    int16_t *charge = guarded(3, count, 2);
    uint32_t *id = guarded(4, count, 4);
    fill_particles(count, x, v, alive, charge, id);
    Particle p = { (int64_t)count, x, v, alive, charge, id };
    advance(&p, 0.5f);
    if (p.count != (int64_t)count) abort();
    for (size_t i = 0; i < count; ++i) {
        const float expected = alive[i] ? (float)i + v[i] * 0.5f : (float)i;
        if (bits(x[i]) != bits(expected)) abort();
    }
    fill_particles(count, x, v, alive, charge, id);
    survivors(&p);
    size_t kept = 0;
    for (size_t i = 0; i < count; ++i) {
        if ((i * 5 + count) % 3 == 0) continue;
        const int16_t expected_charge = (int16_t)(i % 2 ? -(int)(i * 1000) : (int)(i * 1000));
        if (bits(x[kept]) != bits((float)i) || bits(v[kept]) != bits((float)((int)(i % 7) - 3))
            || alive[kept] != 1 || charge[kept] != expected_charge || id[kept] != 0x80000000u + (uint32_t)i) abort();
        ++kept;
    }
    if (p.count != (int64_t)kept) abort();
    fill_particles(count, x, v, alive, charge, id);
    p.count = (int64_t)count;
    fast_survivors(&p, -1.0f);
    kept = 0;
    for (size_t i = 0; i < count; ++i) {
        const float velocity = (float)((int)(i % 7) - 3);
        if ((i * 5 + count) % 3 == 0 || !(velocity > -1.0f)) continue;
        if (bits(x[kept]) != bits((float)i + velocity) || id[kept] != 0x80000000u + (uint32_t)i) abort();
        ++kept;
    }
    if (p.count != (int64_t)kept) abort();
}

int main(void)
{
    if (rake_stream_program_main() != 160) abort();
    page = (size_t)sysconf(_SC_PAGESIZE);
    for (int slot = 0; slot < SLOTS; ++slot) {
        storage[slot] = mmap(NULL, page * 2, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (storage[slot] == MAP_FAILED || mprotect(storage[slot] + page, page, PROT_NONE)) abort();
    }
    for (size_t count = 0; count <= 65; ++count) {
        check_roots(count);
        check_pairs(count);
        check_compact_columns(count);
        check_words(count);
        check_particles(count);
    }
    /* Empty stacks touch no column. */
    Samples empty_input = { 0, NULL, NULL };
    Roots empty_output = { 0, NULL, NULL };
    roots(&empty_input, &empty_output, NAN, NAN);
    Particle none = { -1, NULL, NULL, NULL, NULL, NULL };
    survivors(&none);
    for (int slot = 0; slot < SLOTS; ++slot)
        if (munmap(storage[slot], page * 2)) abort();
    puts("native stack runs passed guard-page and scalar-oracle checks");
    return 0;
}
