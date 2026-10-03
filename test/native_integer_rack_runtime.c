#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

/* Signed and unsigned 32-bit racks have the same vector-register ABI. C uses
   unsigned lane bits here so expected wrapping arithmetic never overflows a
   signed scalar. Signed predicates reinterpret those bits with memcpy. */
typedef uint32_t integer_rack __attribute__((vector_size(LANES * 4)));
typedef float float_rack __attribute__((vector_size(LANES * 4)));

#define DECLARE_ARITHMETIC(kind) \
    extern integer_rack kind##_add(integer_rack, integer_rack); \
    extern integer_rack kind##_sub(integer_rack, integer_rack); \
    extern integer_rack kind##_and(integer_rack, integer_rack); \
    extern integer_rack kind##_or(integer_rack, integer_rack); \
    extern integer_rack kind##_xor(integer_rack, integer_rack); \
    extern integer_rack kind##_increment(integer_rack); \
    extern integer_rack kind##_keep_inputs(integer_rack, integer_rack);
DECLARE_ARITHMETIC(i32s)
DECLARE_ARITHMETIC(u32s)

#define DECLARE_COMPARISON(comparison) \
    extern integer_rack signed_##comparison(integer_rack, integer_rack); \
    extern uint32_t signed_##comparison##_bits(integer_rack, integer_rack); \
    extern integer_rack signed_##comparison##_keep_inputs(integer_rack, integer_rack);
DECLARE_COMPARISON(lt) DECLARE_COMPARISON(le) DECLARE_COMPARISON(gt)
DECLARE_COMPARISON(ge) DECLARE_COMPARISON(eq) DECLARE_COMPARISON(ne)
extern float_rack select_float(integer_rack, integer_rack, float_rack, float_rack);
extern integer_rack select_integer(float_rack, float_rack, integer_rack, integer_rack);
extern integer_rack integer_gaps(integer_rack);

static int32_t signed_bits(uint32_t bits)
{
    int32_t result;
    memcpy(&result, &bits, sizeof result);
    return result;
}

static bool compare_signed(int comparison, uint32_t left, uint32_t right)
{
    const int32_t a = signed_bits(left), b = signed_bits(right);
    switch (comparison) {
        case 0: return a < b;
        case 1: return a <= b;
        case 2: return a > b;
        case 3: return a >= b;
        case 4: return a == b;
        default: return a != b;
    }
}

static int check_bits(const char *operation, integer_rack result, const uint32_t expected[LANES])
{
    uint32_t actual[LANES];
    memcpy(actual, &result, sizeof actual);
    for (int lane = 0; lane < LANES; ++lane) {
        if (actual[lane] != expected[lane]) {
            fprintf(stderr, "%s lane %d: %08x != %08x\n", operation, lane, actual[lane], expected[lane]);
            return 1;
        }
    }
    return 0;
}

int main(void)
{
    integer_rack (*const arithmetic[2][5])(integer_rack, integer_rack) = {
        {i32s_add, i32s_sub, i32s_and, i32s_or, i32s_xor},
        {u32s_add, u32s_sub, u32s_and, u32s_or, u32s_xor}
    };
    integer_rack (*const increments[])(integer_rack) = {i32s_increment, u32s_increment};
    integer_rack (*const compositions[])(integer_rack, integer_rack) = {i32s_keep_inputs, u32s_keep_inputs};
    integer_rack (*const comparisons[])(integer_rack, integer_rack) = {
        signed_lt, signed_le, signed_gt, signed_ge, signed_eq, signed_ne
    };
    integer_rack (*const compare_compositions[])(integer_rack, integer_rack) = {
        signed_lt_keep_inputs, signed_le_keep_inputs, signed_gt_keep_inputs,
        signed_ge_keep_inputs, signed_eq_keep_inputs, signed_ne_keep_inputs
    };
    uint32_t (*const masks[])(integer_rack, integer_rack) = {
        signed_lt_bits, signed_le_bits, signed_gt_bits, signed_ge_bits, signed_eq_bits, signed_ne_bits
    };
    const uint32_t patterns[] = {
        0u, 1u, 0xffffffffu, 0x7fffffffu, 0x80000000u, 0x80000001u,
        0x7ffffffeu, 0x55555555u, 0xaaaaaaaau, 0x12345678u, 0xfedcba98u
    };
    for (int l = 0; l < 11; ++l) for (int r = 0; r < 11; ++r) {
        uint32_t left[LANES], right[LANES], expected[LANES];
        for (int lane = 0; lane < LANES; ++lane) {
            left[lane] = patterns[(l + lane) % 11];
            right[lane] = patterns[(r + 3 * lane) % 11];
        }
        integer_rack a, b;
        memcpy(&a, left, sizeof a);
        memcpy(&b, right, sizeof b);
        for (int kind = 0; kind < 2; ++kind) {
            for (int operation = 0; operation < 5; ++operation) {
                for (int lane = 0; lane < LANES; ++lane) {
                    const uint32_t x = left[lane], y = right[lane];
                    switch (operation) {
                        case 0: expected[lane] = x + y; break;
                        case 1: expected[lane] = x - y; break;
                        case 2: expected[lane] = x & y; break;
                        case 3: expected[lane] = x | y; break;
                        default: expected[lane] = x ^ y; break;
                    }
                }
                if (check_bits("integer arithmetic", arithmetic[kind][operation](a, b), expected)) return 1;
            }
            for (int lane = 0; lane < LANES; ++lane) expected[lane] = left[lane] + 1u;
            if (check_bits("integer literal", increments[kind](a), expected)) return 1;
            for (int lane = 0; lane < LANES; ++lane) expected[lane] = ((left[lane] - right[lane]) ^ left[lane]) + right[lane];
            if (check_bits("live integer inputs", compositions[kind](a, b), expected)) return 1;
        }
        for (int comparison = 0; comparison < 6; ++comparison) {
            uint32_t expected_mask = 0;
            for (int lane = 0; lane < LANES; ++lane) {
                const bool chosen = compare_signed(comparison, left[lane], right[lane]);
                expected[lane] = chosen ? left[lane] : right[lane];
                if (chosen) expected_mask |= 1u << lane;
            }
            if (check_bits("signed comparison", comparisons[comparison](a, b), expected)) return 1;
            if (masks[comparison](a, b) != expected_mask) {
                fprintf(stderr, "signed mask %d disagrees with scalar lane bits\n", comparison);
                return 1;
            }
            for (int lane = 0; lane < LANES; ++lane) expected[lane] += left[lane] - right[lane];
            if (check_bits("live comparison inputs", compare_compositions[comparison](a, b), expected)) return 1;
        }
        for (int lane = 0; lane < LANES; ++lane)
            expected[lane] = signed_bits(left[lane]) < 0 ? left[lane] - 1u : left[lane] + 1u;
        if (check_bits("integer tines and gaps", integer_gaps(a), expected)) return 1;

        float first[LANES], second[LANES];
        for (int lane = 0; lane < LANES; ++lane) {
            first[lane] = (float)(lane - 3);
            second[lane] = (float)(3 - lane);
        }
        float_rack f, g;
        memcpy(&f, first, sizeof f);
        memcpy(&g, second, sizeof g);
        for (int lane = 0; lane < LANES; ++lane)
            memcpy(&expected[lane], compare_signed(0, left[lane], right[lane]) ? &first[lane] : &second[lane], sizeof(uint32_t));
        const float_rack selected_float = select_float(a, b, f, g);
        integer_rack selected_float_bits;
        memcpy(&selected_float_bits, &selected_float, sizeof selected_float_bits);
        if (check_bits("integer mask selects floats", selected_float_bits, expected)) return 1;
        for (int lane = 0; lane < LANES; ++lane) expected[lane] = first[lane] > second[lane] ? left[lane] : right[lane];
        if (check_bits("float mask selects integers", select_integer(f, g, a, b), expected)) return 1;
    }
    printf("native %d-lane integer arithmetic, comparisons and C ABI agree\n", LANES);
    return 0;
}
