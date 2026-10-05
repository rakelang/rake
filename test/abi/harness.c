/* The wasm32 C boundary of runs.rk: descriptors with counts, tails, aliasing,
   masked and compacted selections, guard pages and rack parameters. test()
   returns 0, or the failing check. */
#include <stdint.h>
#include <wasm_simd128.h>

struct rake_stack_Samples_v2 { int64_t count; float *value; uint8_t *quality; };
struct rake_stack_Scaled_v2 { int64_t count; float *result; };
struct rake_stack_Pair_v2 { int64_t count; float *a; float *b; };
struct rake_stack_Quotients_v2 { int64_t count; float *quotient; };
struct rake_stack_Both_v2 { int64_t count; float *sum; float *difference; };
struct rake_stack_Bytes_v2 { int64_t count; uint8_t *v; };
struct rake_stack_Particle_v2 { int64_t count; float *x; float *v; uint8_t *alive; };

void scale_values(const struct rake_stack_Samples_v2 *input, struct rake_stack_Scaled_v2 *output, float scale);
void divide(const struct rake_stack_Pair_v2 *input, struct rake_stack_Quotients_v2 *output);
void both(const struct rake_stack_Pair_v2 *input, struct rake_stack_Both_v2 *out);
void offset(const float *x, int32_t x_count, float *out, int32_t out_count, v128_t shift, int32_t n);
void floor_bytes(struct rake_stack_Bytes_v2 *input);
void advance(struct rake_stack_Particle_v2 *particles, float dt);
void survivors(struct rake_stack_Particle_v2 *particles);

static float values[64], outputs[64 + 8], others[64];
static uint8_t qualities[64 + 1], bytes[64 + 8];

static uint32_t bits(float f) { return __builtin_bit_cast(uint32_t, f); }
#define SENTINEL 0x7fc0beefu

/* The highest pages of linear memory, so storage can end exactly at its end. */
static uint8_t *memory_end(void)
{
    if (__builtin_wasm_memory_grow(0, 1) < 0) return 0;
    return (uint8_t *)(__builtin_wasm_memory_size(0) * 65536);
}

int test(void)
{
    for (int i = 0; i < 64; i++) {
        values[i] = (float)i * 0.75f - 3.0f;
        qualities[i] = (uint8_t)(i * 7);
        others[i] = (i % 3 == 0) ? 0.0f : (float)(i + 1);
    }
    /* Every count from 0 to 20, misaligned by one lane, sentinels after. */
    for (int count = 0; count <= 20; count++) {
        for (int k = 0; k < 64 + 8; k++) outputs[k] = __builtin_bit_cast(float, SENTINEL);
        struct rake_stack_Samples_v2 in = { count, values + 1, qualities + 1 };
        struct rake_stack_Scaled_v2 out = { count, outputs + 1 };
        scale_values(&in, &out, 0.5f);
        if (out.count != count) return 50 + count;
        for (int i = 0; i < count; i++)
            if (bits(outputs[1 + i]) != bits(values[1 + i] * 0.5f + (float)qualities[1 + i])) return 100 + count;
        if (bits(outputs[0]) != SENTINEL) return 200 + count;
        for (int k = count + 1; k < 64 + 8; k++)
            if (bits(outputs[k]) != SENTINEL) return 300 + count;
    }
    /* A count of zero or less reads nothing: null columns. */
    {
        struct rake_stack_Samples_v2 in = { 0, 0, 0 };
        struct rake_stack_Scaled_v2 out = { 0, 0 };
        scale_values(&in, &out, 1.0f);
        in.count = out.count = -5;
        scale_values(&in, &out, 1.0f);
    }
    /* Exact in-place output over an input column. */
    {
        float column[13];
        uint8_t q[13];
        for (int i = 0; i < 13; i++) { column[i] = (float)i; q[i] = 1; }
        struct rake_stack_Samples_v2 in = { 13, column, q };
        struct rake_stack_Scaled_v2 out = { 13, column };
        scale_values(&in, &out, 2.0f);
        for (int i = 0; i < 13; i++) if (column[i] != (float)i * 2.0f + 1.0f) return 400 + i;
    }
    /* Aliased read-only inputs, and division by zero in lanes the tail leaves out. */
    for (int count = 1; count <= 11; count++) {
        struct rake_stack_Pair_v2 in = { count, values, values };
        struct rake_stack_Quotients_v2 out = { count, outputs };
        divide(&in, &out);
        for (int i = 0; i < count; i++) {
            float expected = values[i] / values[i];
            if (bits(outputs[i]) != bits(expected) && !(expected != expected && outputs[i] != outputs[i])) return 500 + count;
        }
        struct rake_stack_Pair_v2 zeros = { count, values, others };
        divide(&zeros, &out);
        for (int i = 0; i < count; i++) {
            float expected = values[i] / others[i];
            if (bits(outputs[i]) != bits(expected)) return 600 + count;
        }
    }
    /* Two replaced columns. */
    for (int count = 0; count <= 13; count++) {
        float s[16], d[16];
        for (int k = 0; k < 16; k++) s[k] = d[k] = __builtin_bit_cast(float, SENTINEL);
        struct rake_stack_Pair_v2 in = { count, values, others };
        struct rake_stack_Both_v2 out = { count, s, d };
        both(&in, &out);
        for (int i = 0; i < count; i++)
            if (s[i] != values[i] + others[i] || d[i] != values[i] - others[i]) return 700 + count;
        for (int k = count; k < 16; k++) if (bits(s[k]) != SENTINEL || bits(d[k]) != SENTINEL) return 800 + count;
    }
    /* A rack parameter passed from C. */
    {
        float out[8];
        offset(values, 8, out, 8, wasm_f32x4_make(1.0f, 2.0f, 3.0f, 4.0f), 8);
        for (int i = 0; i < 8; i++) if (out[i] != values[i] + (float)(1 + i % 4)) return 1000 + i;
    }
    /* Byte racks: sixteen lanes, tails of up to fifteen, updated in place. */
    for (int count = 0; count <= 40; count++) {
        for (int k = 0; k < 64 + 8; k++) bytes[k] = (uint8_t)(k * 13);
        struct rake_stack_Bytes_v2 in = { count, bytes + 1 };
        floor_bytes(&in);
        for (int i = 0; i < count; i++) {
            uint8_t original = (uint8_t)((1 + i) * 13);
            if (bytes[1 + i] != (original < 10 ? 10 : original)) return 1100 + count;
        }
        for (int k = count + 1; k < 64 + 8; k++) if (bytes[k] != (uint8_t)(k * 13)) return 1200 + count;
    }
    /* Masked and compacted particles: every count, alive in a pattern. */
    for (int count = 0; count <= 19; count++) {
        float x[24], v[24];
        uint8_t alive[24];
        for (int k = 0; k < 24; k++) { x[k] = (float)k; v[k] = (float)(k % 5) - 2.0f; alive[k] = (uint8_t)(k % 3 != 1); }
        struct rake_stack_Particle_v2 p = { count, x, v, alive };
        advance(&p, 0.5f);
        if (p.count != count) return 1600 + count;
        for (int k = 0; k < 24; k++) {
            float expected = (k < count && k % 3 != 1) ? (float)k + ((float)(k % 5) - 2.0f) * 0.5f : (float)k;
            if (x[k] != expected) return 1700 + count;
        }
        for (int k = 0; k < 24; k++) { x[k] = (float)k; v[k] = (float)(k * 2); alive[k] = (uint8_t)(k % 3 != 1); }
        survivors(&p);
        int kept = 0;
        for (int k = 0; k < count; k++) {
            if (k % 3 == 1) continue;
            if (x[kept] != (float)k || v[kept] != (float)(k * 2) || alive[kept] != 1) return 1800 + count;
            kept++;
        }
        if (p.count != kept) return 1900 + count;
        for (int k = count; k < 24; k++) if (x[k] != (float)k || v[k] != (float)(k * 2)) return 2000 + count;
    }
    /* Storage ending at the end of linear memory: any access past the count traps. */
    {
        uint8_t *end = memory_end();
        if (!end) return 1300;
        for (int count = 1; count <= 9; count++) {
            float *value = (float *)(end - 4 * count);
            uint8_t *quality = end - 4 * 64 - count;
            float *result = (float *)(end - 4 * 64 - 64 - 4 * count);
            for (int i = 0; i < count; i++) { value[i] = (float)i; quality[i] = 2; }
            struct rake_stack_Samples_v2 in = { count, value, quality };
            struct rake_stack_Scaled_v2 out = { count, result };
            scale_values(&in, &out, 1.0f);
            for (int i = 0; i < count; i++) if (result[i] != (float)i + 2.0f) return 1400 + count;
            uint8_t *byte_in = end - count;
            for (int i = 0; i < count; i++) byte_in[i] = (uint8_t)i;
            struct rake_stack_Bytes_v2 bin = { count, byte_in };
            floor_bytes(&bin);
            float *px = (float *)(end - 4 * count);
            float *pv = (float *)(end - 1024 - 4 * count);
            uint8_t *pa = end - 2048 - count;
            for (int i = 0; i < count; i++) { px[i] = (float)i; pv[i] = 1.0f; pa[i] = (uint8_t)(i % 2); }
            struct rake_stack_Particle_v2 p = { count, px, pv, pa };
            survivors(&p);
            if (p.count != count / 2) return 1450 + count;
        }
        /* The output at the very end too. */
        for (int count = 1; count <= 7; count++) {
            float *result = (float *)(end - 4 * count);
            struct rake_stack_Samples_v2 in = { count, values, qualities };
            struct rake_stack_Scaled_v2 out = { count, result };
            scale_values(&in, &out, 1.0f);
            for (int i = 0; i < count; i++) if (result[i] != values[i] + (float)qualities[i]) return 1500 + count;
        }
    }
    return 0;
}
