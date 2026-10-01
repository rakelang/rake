/* The wasm32 C boundary of runs.rk: descriptors, counts, tails, aliasing,
   guard pages and rack parameters. test() returns 0, or the failing check. */
#include <stdint.h>
#include <wasm_simd128.h>

struct rake_pack_Samples_v1 { const float *value; const uint8_t *quality; };
struct rake_pack_Pair_v1 { const float *a; const float *b; };
struct rake_mut_pack_Both_v1 { float *sum; float *difference; };
struct rake_pack_Bytes_v1 { const uint8_t *v; };

void scale_values(const struct rake_pack_Samples_v1 *input, int64_t count, float scale, float *result);
void divide(const struct rake_pack_Pair_v1 *input, int64_t count, float *result);
void both(const struct rake_pack_Pair_v1 *input, const struct rake_mut_pack_Both_v1 *out, int64_t count);
void total(const struct rake_pack_Pair_v1 *input, float *totals, int32_t totals_count, int64_t count);
void offset(const float *x, int32_t x_count, float *out, int32_t out_count, v128_t shift, int32_t n);
void floor_bytes(const struct rake_pack_Bytes_v1 *input, int64_t count, uint8_t *result);

static float values[64], outputs[64 + 8], others[64];
static uint8_t qualities[64 + 1], bytes[64 + 1], byte_out[64 + 8];

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
        bytes[i] = (uint8_t)(i * 13);
    }
    /* Every count from 0 to 20, misaligned by one lane, sentinels after. */
    for (int count = 0; count <= 20; count++) {
        for (int k = 0; k < 64 + 8; k++) outputs[k] = __builtin_bit_cast(float, SENTINEL);
        struct rake_pack_Samples_v1 in = { values + 1, qualities + 1 };
        scale_values(&in, count, 0.5f, outputs + 1);
        for (int i = 0; i < count; i++)
            if (bits(outputs[1 + i]) != bits(values[1 + i] * 0.5f + (float)qualities[1 + i])) return 100 + count;
        if (bits(outputs[0]) != SENTINEL) return 200 + count;
        for (int k = count + 1; k < 64 + 8; k++)
            if (bits(outputs[k]) != SENTINEL) return 300 + count;
    }
    /* A count of zero or less reads nothing: null descriptor and output. */
    scale_values(0, 0, 1.0f, 0);
    scale_values(0, -5, 1.0f, 0);
    /* Exact in-place output over an input column. */
    {
        float column[13];
        uint8_t q[13];
        for (int i = 0; i < 13; i++) { column[i] = (float)i; q[i] = 1; }
        struct rake_pack_Samples_v1 in = { column, q };
        scale_values(&in, 13, 2.0f, column);
        for (int i = 0; i < 13; i++) if (column[i] != (float)i * 2.0f + 1.0f) return 400 + i;
    }
    /* Aliased read-only inputs, and division by zero in lanes the tail leaves out. */
    for (int count = 1; count <= 11; count++) {
        struct rake_pack_Pair_v1 in = { values, values };
        divide(&in, count, outputs);
        for (int i = 0; i < count; i++) {
            float expected = values[i] / values[i];
            if (bits(outputs[i]) != bits(expected) && !(expected != expected && outputs[i] != outputs[i])) return 500 + count;
        }
        struct rake_pack_Pair_v1 zeros = { values, others };
        divide(&zeros, count, outputs);
        for (int i = 0; i < count; i++) {
            float expected = values[i] / others[i];
            if (bits(outputs[i]) != bits(expected)) return 600 + count;
        }
    }
    /* Two outputs, and an accumulator updated only by a tail's active lanes. */
    for (int count = 0; count <= 13; count++) {
        float s[16], d[16], t[4];
        for (int k = 0; k < 16; k++) s[k] = d[k] = __builtin_bit_cast(float, SENTINEL);
        struct rake_pack_Pair_v1 in = { values, others };
        struct rake_mut_pack_Both_v1 out = { s, d };
        both(&in, &out, count);
        for (int i = 0; i < count; i++)
            if (s[i] != values[i] + others[i] || d[i] != values[i] - others[i]) return 700 + count;
        for (int k = count; k < 16; k++) if (bits(s[k]) != SENTINEL || bits(d[k]) != SENTINEL) return 800 + count;
        total(&in, t, 4, count);
        float lanes[4] = { 0, 0, 0, 0 };
        for (int i = 0; i < count; i++) lanes[i % 4] += values[i];
        for (int lane = 0; lane < 4; lane++) if (bits(t[lane]) != bits(lanes[lane])) return 900 + count;
    }
    /* A rack parameter passed from C. */
    {
        float out[8];
        offset(values, 8, out, 8, wasm_f32x4_make(1.0f, 2.0f, 3.0f, 4.0f), 8);
        for (int i = 0; i < 8; i++) if (out[i] != values[i] + (float)(1 + i % 4)) return 1000 + i;
    }
    /* Byte racks: sixteen lanes, tails of up to fifteen. */
    for (int count = 0; count <= 40; count++) {
        for (int k = 0; k < 64 + 8; k++) byte_out[k] = 0xa5;
        struct rake_pack_Bytes_v1 in = { bytes + 1 };
        floor_bytes(&in, count, byte_out);
        for (int i = 0; i < count; i++) {
            uint8_t e = bytes[1 + i] < 10 ? 10 : bytes[1 + i];
            if (byte_out[i] != e) return 1100 + count;
        }
        for (int k = count; k < 64 + 8; k++) if (byte_out[k] != 0xa5) return 1200 + count;
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
            struct rake_pack_Samples_v1 in = { value, quality };
            scale_values(&in, count, 1.0f, result);
            for (int i = 0; i < count; i++) if (result[i] != (float)i + 2.0f) return 1400 + count;
            uint8_t *byte_in = end - count;
            for (int i = 0; i < count; i++) byte_in[i] = (uint8_t)i;
            struct rake_pack_Bytes_v1 bin = { byte_in };
            floor_bytes(&bin, count, end - 1024 - count);
        }
        /* The output at the very end too. */
        for (int count = 1; count <= 7; count++) {
            float *result = (float *)(end - 4 * count);
            struct rake_pack_Samples_v1 in = { values, qualities };
            scale_values(&in, count, 1.0f, result);
            for (int i = 0; i < count; i++) if (result[i] != values[i] + (float)qualities[i]) return 1500 + count;
        }
    }
    return 0;
}
