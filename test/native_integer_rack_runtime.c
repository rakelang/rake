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
    extern integer_rack kind##_mul(integer_rack, integer_rack); \
    extern integer_rack kind##_and(integer_rack, integer_rack); \
    extern integer_rack kind##_or(integer_rack, integer_rack); \
    extern integer_rack kind##_xor(integer_rack, integer_rack); \
    extern integer_rack kind##_andnot(integer_rack, integer_rack); \
    extern integer_rack kind##_andnot_keep_inputs(integer_rack, integer_rack); \
    extern integer_rack kind##_andnot_keep_left(integer_rack, integer_rack); \
    extern integer_rack kind##_andnot_same(integer_rack); \
    extern integer_rack kind##_andnot_literal(integer_rack); \
    extern integer_rack kind##_increment(integer_rack); \
    extern integer_rack kind##_keep_inputs(integer_rack, integer_rack); \
    extern integer_rack kind##_multiply_keep_inputs(integer_rack, integer_rack); \
    extern integer_rack kind##_multiply_keep_left(integer_rack, integer_rack); \
    extern integer_rack kind##_square(integer_rack);
DECLARE_ARITHMETIC(i32s)
DECLARE_ARITHMETIC(u32s)

#define DECLARE_SHUFFLE(kind) \
    extern integer_rack kind##_shuffle_reverse(integer_rack); \
    extern integer_rack kind##_shuffle_rotate(integer_rack); \
    extern integer_rack kind##_shuffle_repeat(integer_rack); \
    extern integer_rack kind##_shuffle_identity(integer_rack); \
    extern integer_rack kind##_shuffle_weave(integer_rack, integer_rack); \
    extern integer_rack kind##_shuffle_mixed(integer_rack, integer_rack); \
    extern integer_rack kind##_shuffle_right(integer_rack, integer_rack); \
    extern integer_rack kind##_shuffle_keep_inputs(integer_rack, integer_rack); \
    extern integer_rack kind##_shuffle_same_input(integer_rack);
DECLARE_SHUFFLE(i32s)
DECLARE_SHUFFLE(u32s)

#define FOR_EACH_SHIFT_COUNT(apply, kind) \
    apply(kind, 0)  apply(kind, 1)  apply(kind, 2)  apply(kind, 3) \
    apply(kind, 4)  apply(kind, 5)  apply(kind, 6)  apply(kind, 7) \
    apply(kind, 8)  apply(kind, 9)  apply(kind, 10) apply(kind, 11) \
    apply(kind, 12) apply(kind, 13) apply(kind, 14) apply(kind, 15) \
    apply(kind, 16) apply(kind, 17) apply(kind, 18) apply(kind, 19) \
    apply(kind, 20) apply(kind, 21) apply(kind, 22) apply(kind, 23) \
    apply(kind, 24) apply(kind, 25) apply(kind, 26) apply(kind, 27) \
    apply(kind, 28) apply(kind, 29) apply(kind, 30) apply(kind, 31)
#define DECLARE_SHIFT(kind, count) \
    extern integer_rack kind##_shift_left_##count(integer_rack); \
    extern integer_rack kind##_shift_right_##count(integer_rack); \
    extern integer_rack kind##_shift_right_signed_##count(integer_rack);
FOR_EACH_SHIFT_COUNT(DECLARE_SHIFT, i32s)
FOR_EACH_SHIFT_COUNT(DECLARE_SHIFT, u32s)
extern integer_rack i32s_shift_keep_input(integer_rack);
extern integer_rack u32s_shift_keep_input(integer_rack);
extern integer_rack signed_shift_selected(integer_rack, integer_rack);
extern integer_rack signed_andnot_selected(integer_rack, integer_rack);
extern integer_rack unsigned_andnot_all(integer_rack);

#define DECLARE_COMPARISON(comparison) \
    extern integer_rack signed_##comparison(integer_rack, integer_rack); \
    extern uint32_t signed_##comparison##_bits(integer_rack, integer_rack); \
    extern integer_rack signed_##comparison##_keep_inputs(integer_rack, integer_rack); \
    extern integer_rack unsigned_##comparison(integer_rack, integer_rack); \
    extern uint32_t unsigned_##comparison##_bits(integer_rack, integer_rack); \
    extern integer_rack unsigned_##comparison##_keep_inputs(integer_rack, integer_rack); \
    extern uint32_t unsigned_##comparison##_literal(integer_rack); \
    extern uint32_t unsigned_##comparison##_literal_first(integer_rack);
DECLARE_COMPARISON(lt) DECLARE_COMPARISON(le) DECLARE_COMPARISON(gt)
DECLARE_COMPARISON(ge) DECLARE_COMPARISON(eq) DECLARE_COMPARISON(ne)
extern float_rack select_float(integer_rack, integer_rack, float_rack, float_rack);
extern integer_rack select_integer(float_rack, float_rack, integer_rack, integer_rack);
extern integer_rack integer_gaps(integer_rack);
extern float_rack unsigned_gap_flags(integer_rack);
extern bool unsigned_all(integer_rack, integer_rack);
extern bool unsigned_any(integer_rack, integer_rack);
extern uint32_t unsigned_equal_self(integer_rack);
extern uint32_t unsigned_less_self(integer_rack);
extern integer_rack signed_negate(integer_rack);
extern integer_rack signed_negate_keep_input(integer_rack);
extern integer_rack signed_negate_selected(integer_rack, integer_rack);
extern integer_rack signed_absolute(integer_rack);
extern integer_rack signed_absolute_keep_input(integer_rack);
extern integer_rack signed_absolute_incremented(integer_rack);
extern integer_rack signed_absolute_twice(integer_rack);
extern integer_rack signed_absolute_selected(integer_rack, integer_rack);
extern integer_rack signed_multiply_selected(integer_rack, integer_rack);
extern integer_rack signed_min(integer_rack, integer_rack);
extern integer_rack signed_max(integer_rack, integer_rack);
extern integer_rack signed_min_keep_inputs(integer_rack, integer_rack);
extern integer_rack signed_max_keep_inputs(integer_rack, integer_rack);
extern integer_rack signed_min_keep_left(integer_rack, integer_rack);
extern integer_rack signed_max_keep_left(integer_rack, integer_rack);
extern integer_rack signed_min_same(integer_rack);
extern integer_rack signed_max_same(integer_rack);
extern integer_rack signed_clamp(integer_rack);
extern integer_rack signed_extreme_selected(integer_rack, integer_rack);
extern integer_rack signed_extreme_literal_first(integer_rack);
extern integer_rack unsigned_min(integer_rack, integer_rack);
extern integer_rack unsigned_max(integer_rack, integer_rack);
extern integer_rack unsigned_min_keep_inputs(integer_rack, integer_rack);
extern integer_rack unsigned_max_keep_inputs(integer_rack, integer_rack);
extern integer_rack unsigned_min_keep_left(integer_rack, integer_rack);
extern integer_rack unsigned_max_keep_left(integer_rack, integer_rack);
extern integer_rack unsigned_min_same(integer_rack);
extern integer_rack unsigned_max_same(integer_rack);
extern integer_rack unsigned_clamp(integer_rack);
extern integer_rack unsigned_extreme_selected(integer_rack, integer_rack);
extern integer_rack unsigned_extreme_literal_first(integer_rack);
extern integer_rack signed_uniform_add(integer_rack, int32_t);
extern integer_rack unsigned_uniform_keep(uint32_t, integer_rack, uint32_t);
extern integer_rack unsigned_uniform_clamp(integer_rack, uint32_t, uint32_t);
extern integer_rack unsigned_uniform_reverse(uint32_t, integer_rack);
extern float_rack integer_float_boundary(int32_t, float_rack, float, uint32_t, integer_rack);
extern integer_rack six_integer_slots(uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t);
extern float_rack eight_vector_slots(float_rack, float_rack, float_rack, float_rack, float_rack, float_rack, float_rack, float_rack, int32_t);
#ifdef __aarch64__
extern integer_rack eight_integer_slots(uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t);
#endif

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

static bool compare_unsigned(int comparison, uint32_t left, uint32_t right)
{
    switch (comparison) {
        case 0: return left < right;
        case 1: return left <= right;
        case 2: return left > right;
        case 3: return left >= right;
        case 4: return left == right;
        default: return left != right;
    }
}

/* Widen before negating so INT32_MIN has a defined magnitude. Converting
   that magnitude to lane bits independently checks the wrapping result. */
static uint32_t signed_absolute_bits(uint32_t bits)
{
    const int64_t value = signed_bits(bits);
    return (uint32_t)(value < 0 ? -value : value);
}

/* Define sign extension with unsigned bits. The oracle neither relies on a
   C implementation's signed right shift nor shifts by 32 at count zero. */
static uint32_t shift_lane_bits(uint32_t bits, unsigned count, int operation)
{
    if (operation == 0) return bits << count;
    uint32_t result = bits >> count;
    if (operation == 2 && count != 0 && (bits & 0x80000000u) != 0)
        result |= UINT32_MAX << (32 - count);
    return result;
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
    integer_rack (*const arithmetic[2][7])(integer_rack, integer_rack) = {
        {i32s_add, i32s_sub, i32s_mul, i32s_and, i32s_or, i32s_xor, i32s_andnot},
        {u32s_add, u32s_sub, u32s_mul, u32s_and, u32s_or, u32s_xor, u32s_andnot}
    };
    integer_rack (*const andnot_keep_inputs[])(integer_rack, integer_rack) = {i32s_andnot_keep_inputs, u32s_andnot_keep_inputs};
    integer_rack (*const andnot_keep_left[])(integer_rack, integer_rack) = {i32s_andnot_keep_left, u32s_andnot_keep_left};
    integer_rack (*const andnot_same[])(integer_rack) = {i32s_andnot_same, u32s_andnot_same};
    integer_rack (*const andnot_literal[])(integer_rack) = {i32s_andnot_literal, u32s_andnot_literal};
    integer_rack (*const increments[])(integer_rack) = {i32s_increment, u32s_increment};
    integer_rack (*const compositions[])(integer_rack, integer_rack) = {i32s_keep_inputs, u32s_keep_inputs};
    integer_rack (*const multiply_compositions[])(integer_rack, integer_rack) = {i32s_multiply_keep_inputs, u32s_multiply_keep_inputs};
    integer_rack (*const multiply_keep_left[])(integer_rack, integer_rack) = {i32s_multiply_keep_left, u32s_multiply_keep_left};
    integer_rack (*const squares[])(integer_rack) = {i32s_square, u32s_square};
    integer_rack (*const single_shuffles[2][4])(integer_rack) = {
        {i32s_shuffle_reverse, i32s_shuffle_rotate, i32s_shuffle_repeat, i32s_shuffle_identity},
        {u32s_shuffle_reverse, u32s_shuffle_rotate, u32s_shuffle_repeat, u32s_shuffle_identity}
    };
    integer_rack (*const paired_shuffles[2][3])(integer_rack, integer_rack) = {
        {i32s_shuffle_weave, i32s_shuffle_mixed, i32s_shuffle_right},
        {u32s_shuffle_weave, u32s_shuffle_mixed, u32s_shuffle_right}
    };
    integer_rack (*const shuffle_compositions[])(integer_rack, integer_rack) = {i32s_shuffle_keep_inputs, u32s_shuffle_keep_inputs};
    integer_rack (*const same_shuffles[])(integer_rack) = {i32s_shuffle_same_input, u32s_shuffle_same_input};
#define SHIFT_FUNCTIONS(kind, count) \
    {kind##_shift_left_##count, kind##_shift_right_##count, kind##_shift_right_signed_##count},
    integer_rack (*const shifts[2][32][3])(integer_rack) = {
        {FOR_EACH_SHIFT_COUNT(SHIFT_FUNCTIONS, i32s)},
        {FOR_EACH_SHIFT_COUNT(SHIFT_FUNCTIONS, u32s)}
    };
    integer_rack (*const shift_keep_input[])(integer_rack) = {i32s_shift_keep_input, u32s_shift_keep_input};
    integer_rack (*const extrema[])(integer_rack, integer_rack) = {signed_min, signed_max};
    integer_rack (*const extrema_keep_inputs[])(integer_rack, integer_rack) = {signed_min_keep_inputs, signed_max_keep_inputs};
    integer_rack (*const extrema_keep_left[])(integer_rack, integer_rack) = {signed_min_keep_left, signed_max_keep_left};
    integer_rack (*const extrema_same[])(integer_rack) = {signed_min_same, signed_max_same};
    integer_rack (*const unsigned_extrema[])(integer_rack, integer_rack) = {unsigned_min, unsigned_max};
    integer_rack (*const unsigned_extrema_keep_inputs[])(integer_rack, integer_rack) = {unsigned_min_keep_inputs, unsigned_max_keep_inputs};
    integer_rack (*const unsigned_extrema_keep_left[])(integer_rack, integer_rack) = {unsigned_min_keep_left, unsigned_max_keep_left};
    integer_rack (*const unsigned_extrema_same[])(integer_rack) = {unsigned_min_same, unsigned_max_same};
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
    integer_rack (*const unsigned_comparisons[])(integer_rack, integer_rack) = {
        unsigned_lt, unsigned_le, unsigned_gt, unsigned_ge, unsigned_eq, unsigned_ne
    };
    integer_rack (*const unsigned_compositions[])(integer_rack, integer_rack) = {
        unsigned_lt_keep_inputs, unsigned_le_keep_inputs, unsigned_gt_keep_inputs,
        unsigned_ge_keep_inputs, unsigned_eq_keep_inputs, unsigned_ne_keep_inputs
    };
    uint32_t (*const unsigned_masks[])(integer_rack, integer_rack) = {
        unsigned_lt_bits, unsigned_le_bits, unsigned_gt_bits, unsigned_ge_bits, unsigned_eq_bits, unsigned_ne_bits
    };
    uint32_t (*const unsigned_literals[])(integer_rack) = {
        unsigned_lt_literal, unsigned_le_literal, unsigned_gt_literal,
        unsigned_ge_literal, unsigned_eq_literal, unsigned_ne_literal
    };
    uint32_t (*const unsigned_literal_first[])(integer_rack) = {
        unsigned_lt_literal_first, unsigned_le_literal_first, unsigned_gt_literal_first,
        unsigned_ge_literal_first, unsigned_eq_literal_first, unsigned_ne_literal_first
    };
    const uint32_t patterns[] = {
        0u, 1u, 0xffffffffu, 0x7fffffffu, 0x80000000u, 0x80000001u,
        0x7ffffffeu, 0x55555555u, 0xaaaaaaaau, 0x12345678u, 0xfedcba98u,
        65535u, 65536u, 65537u, 0xffff8001u
    };
    const int pattern_count = sizeof patterns / sizeof patterns[0];
    for (int l = 0; l < pattern_count; ++l) for (int r = 0; r < pattern_count; ++r) {
        uint32_t left[LANES], right[LANES], expected[LANES];
        for (int lane = 0; lane < LANES; ++lane) {
            left[lane] = patterns[(l + lane) % pattern_count];
            right[lane] = patterns[(r + 3 * lane) % pattern_count];
        }
        integer_rack a, b;
        memcpy(&a, left, sizeof a);
        memcpy(&b, right, sizeof b);
        for (int kind = 0; kind < 2; ++kind) {
            for (int pattern = 0; pattern < 4; ++pattern) {
                for (int lane = 0; lane < LANES; ++lane) {
                    const int selected = pattern == 0 ? LANES - 1 - lane
                        : pattern == 1 ? (lane + 1) % LANES
                        : pattern == 2 ? LANES - 1 : lane;
                    expected[lane] = left[selected];
                }
                if (check_bits("single integer shuffle", single_shuffles[kind][pattern](a), expected)) return 1;
            }
            for (int pattern = 0; pattern < 3; ++pattern) {
                for (int lane = 0; lane < LANES; ++lane) {
                    const int selected = pattern == 0 ? lane / 2 + (lane % 2) * LANES
                        : pattern == 1 ? (7 * lane + 3) % (2 * LANES)
                        : 2 * LANES - 1 - lane;
                    expected[lane] = selected < LANES ? left[selected] : right[selected - LANES];
                }
                if (check_bits("paired integer shuffle", paired_shuffles[kind][pattern](a, b), expected)) return 1;
            }
            for (int lane = 0; lane < LANES; ++lane) {
                const int selected = (7 * lane + 3) % (2 * LANES);
                const uint32_t picked = selected < LANES ? left[selected] : right[selected - LANES];
                expected[lane] = (picked ^ left[lane]) + right[lane];
            }
            if (check_bits("live integer shuffle inputs", shuffle_compositions[kind](a, b), expected)) return 1;
            for (int lane = 0; lane < LANES; ++lane)
                expected[lane] = left[(7 * lane + 3) % LANES];
            if (check_bits("aliased integer shuffle inputs", same_shuffles[kind](a), expected)) return 1;
            for (unsigned count = 0; count < 32; ++count) {
                for (int operation = 0; operation < 3; ++operation) {
                    for (int lane = 0; lane < LANES; ++lane)
                        expected[lane] = shift_lane_bits(left[lane], count, operation);
                    if (check_bits("literal integer bit shifts", shifts[kind][count][operation](a), expected)) return 1;
                }
            }
            for (int lane = 0; lane < LANES; ++lane)
                expected[lane] = shift_lane_bits(left[lane] + 1u, 7, 2) + left[lane];
            if (check_bits("live shift input", shift_keep_input[kind](a), expected)) return 1;
            for (int operation = 0; operation < 7; ++operation) {
                for (int lane = 0; lane < LANES; ++lane) {
                    const uint32_t x = left[lane], y = right[lane];
                    switch (operation) {
                        case 0: expected[lane] = x + y; break;
                        case 1: expected[lane] = x - y; break;
                        case 2: expected[lane] = x * y; break;
                        case 3: expected[lane] = x & y; break;
                        case 4: expected[lane] = x | y; break;
                        case 5: expected[lane] = x ^ y; break;
                        default: expected[lane] = x & ~y; break;
                    }
                }
                if (check_bits("integer arithmetic", arithmetic[kind][operation](a, b), expected)) return 1;
            }
            for (int lane = 0; lane < LANES; ++lane)
                expected[lane] = ((left[lane] & ~right[lane]) ^ left[lane]) + right[lane];
            if (check_bits("live and-not inputs", andnot_keep_inputs[kind](a, b), expected)) return 1;
            for (int lane = 0; lane < LANES; ++lane)
                expected[lane] = (left[lane] & ~right[lane]) + left[lane];
            if (check_bits("destructive and-not right input", andnot_keep_left[kind](a, b), expected)) return 1;
            for (int lane = 0; lane < LANES; ++lane) expected[lane] = 0u;
            if (check_bits("aliased and-not inputs", andnot_same[kind](a), expected)) return 1;
            for (int lane = 0; lane < LANES; ++lane) expected[lane] = 0x55555555u & ~left[lane];
            if (check_bits("literal-first and-not", andnot_literal[kind](a), expected)) return 1;
            for (int lane = 0; lane < LANES; ++lane) expected[lane] = left[lane] + 1u;
            if (check_bits("integer literal", increments[kind](a), expected)) return 1;
            for (int lane = 0; lane < LANES; ++lane) expected[lane] = ((left[lane] - right[lane]) ^ left[lane]) + right[lane];
            if (check_bits("live integer inputs", compositions[kind](a, b), expected)) return 1;
            for (int lane = 0; lane < LANES; ++lane) expected[lane] = ((left[lane] * right[lane]) ^ left[lane]) + right[lane];
            if (check_bits("live multiplication inputs", multiply_compositions[kind](a, b), expected)) return 1;
            for (int lane = 0; lane < LANES; ++lane) expected[lane] = left[lane] * right[lane] + left[lane];
            if (check_bits("destructive multiplication right input", multiply_keep_left[kind](a, b), expected)) return 1;
            for (int lane = 0; lane < LANES; ++lane) expected[lane] = left[lane] * left[lane];
            if (check_bits("aliased multiplication inputs", squares[kind](a), expected)) return 1;
        }
        for (int lane = 0; lane < LANES; ++lane)
            expected[lane] = compare_signed(0, left[lane], right[lane])
                ? left[lane] & ~right[lane] : right[lane] & ~left[lane];
        if (check_bits("masked and-not", signed_andnot_selected(a, b), expected)) return 1;
        for (int lane = 0; lane < LANES; ++lane) expected[lane] = ~left[lane];
        if (check_bits("maximum unsigned mask", unsigned_andnot_all(a), expected)) return 1;
        for (int lane = 0; lane < LANES; ++lane)
            expected[lane] = compare_signed(0, left[lane], right[lane])
                ? shift_lane_bits(left[lane], 31, 0) : shift_lane_bits(right[lane], 31, 2);
        if (check_bits("masked integer bit shifts", signed_shift_selected(a, b), expected)) return 1;
        for (int operation = 0; operation < 2; ++operation) {
            for (int lane = 0; lane < LANES; ++lane) {
                const bool choose_left = operation == 0
                    ? signed_bits(left[lane]) < signed_bits(right[lane])
                    : signed_bits(left[lane]) > signed_bits(right[lane]);
                expected[lane] = choose_left ? left[lane] : right[lane];
            }
            if (check_bits("signed integer extrema", extrema[operation](a, b), expected)) return 1;
            for (int lane = 0; lane < LANES; ++lane) expected[lane] = (expected[lane] ^ left[lane]) + right[lane];
            if (check_bits("live extrema inputs", extrema_keep_inputs[operation](a, b), expected)) return 1;
            for (int lane = 0; lane < LANES; ++lane) {
                const bool choose_left = operation == 0
                    ? signed_bits(left[lane]) < signed_bits(right[lane])
                    : signed_bits(left[lane]) > signed_bits(right[lane]);
                expected[lane] = (choose_left ? left[lane] : right[lane]) + left[lane];
            }
            if (check_bits("destructive extrema right input", extrema_keep_left[operation](a, b), expected)) return 1;
            if (check_bits("aliased extrema inputs", extrema_same[operation](a), left)) return 1;
            for (int lane = 0; lane < LANES; ++lane) {
                const bool choose_left = operation == 0
                    ? left[lane] < right[lane] : left[lane] > right[lane];
                expected[lane] = choose_left ? left[lane] : right[lane];
            }
            if (check_bits("unsigned integer extrema", unsigned_extrema[operation](a, b), expected)) return 1;
            for (int lane = 0; lane < LANES; ++lane) expected[lane] = (expected[lane] ^ left[lane]) + right[lane];
            if (check_bits("live unsigned extrema inputs", unsigned_extrema_keep_inputs[operation](a, b), expected)) return 1;
            for (int lane = 0; lane < LANES; ++lane) {
                const bool choose_left = operation == 0
                    ? left[lane] < right[lane] : left[lane] > right[lane];
                expected[lane] = (choose_left ? left[lane] : right[lane]) + left[lane];
            }
            if (check_bits("destructive unsigned extrema right input", unsigned_extrema_keep_left[operation](a, b), expected)) return 1;
            if (check_bits("aliased unsigned extrema inputs", unsigned_extrema_same[operation](a), left)) return 1;
        }
        for (int lane = 0; lane < LANES; ++lane) {
            const uint32_t value = left[lane];
            expected[lane] = value < 0x7fffffffu ? 0x7fffffffu : value > 0x80000001u ? 0x80000001u : value;
        }
        if (check_bits("nested unsigned extrema literals", unsigned_clamp(a), expected)) return 1;
        for (int lane = 0; lane < LANES; ++lane) {
            const uint32_t x = left[lane], y = right[lane];
            expected[lane] = x < y ? (x > 0x80000000u ? x : 0x80000000u) : (y < 0x80000000u ? y : 0x80000000u);
        }
        if (check_bits("masked unsigned extrema", unsigned_extreme_selected(a, b), expected)) return 1;
        for (int lane = 0; lane < LANES; ++lane)
            expected[lane] = left[lane] < 0x80000000u ? 0x80000000u : left[lane];
        if (check_bits("literal-first unsigned extrema", unsigned_extreme_literal_first(a), expected)) return 1;
        for (int lane = 0; lane < LANES; ++lane) {
            const int32_t value = signed_bits(left[lane]);
            expected[lane] = value < -17 ? (uint32_t)-17 : value > 29 ? 29u : left[lane];
        }
        if (check_bits("nested signed extrema literals", signed_clamp(a), expected)) return 1;
        for (int lane = 0; lane < LANES; ++lane) {
            const int32_t x = signed_bits(left[lane]), y = signed_bits(right[lane]);
            expected[lane] = x < y ? (x > 0 ? left[lane] : 0u) : (y < 0 ? right[lane] : 0u);
        }
        if (check_bits("masked signed extrema", signed_extreme_selected(a, b), expected)) return 1;
        for (int lane = 0; lane < LANES; ++lane) {
            const int32_t value = signed_bits(left[lane]);
            expected[lane] = value < 0 ? 0u : value > 29 ? 29u : left[lane];
        }
        if (check_bits("literal-first signed extrema", signed_extreme_literal_first(a), expected)) return 1;
        for (int lane = 0; lane < LANES; ++lane) {
            const uint32_t x = left[lane], y = right[lane];
            expected[lane] = compare_signed(0, x, y) ? x * y : (x + 1u) * (y - 1u);
        }
        if (check_bits("masked wrapping multiplication", signed_multiply_selected(a, b), expected)) return 1;
        for (int lane = 0; lane < LANES; ++lane) expected[lane] = 0u - left[lane];
        if (check_bits("signed wrapping negation", signed_negate(a), expected)) return 1;
        for (int lane = 0; lane < LANES; ++lane) expected[lane] ^= left[lane];
        if (check_bits("live negation input", signed_negate_keep_input(a), expected)) return 1;
        for (int lane = 0; lane < LANES; ++lane)
            expected[lane] = 0u - (compare_signed(0, left[lane], right[lane]) ? left[lane] : right[lane]);
        if (check_bits("masked signed negation", signed_negate_selected(a, b), expected)) return 1;
        for (int lane = 0; lane < LANES; ++lane) expected[lane] = signed_absolute_bits(left[lane]);
        if (check_bits("signed wrapping absolute value", signed_absolute(a), expected)) return 1;
        if (check_bits("idempotent absolute value", signed_absolute_twice(a), expected)) return 1;
        for (int lane = 0; lane < LANES; ++lane) expected[lane] ^= left[lane];
        if (check_bits("live absolute-value input", signed_absolute_keep_input(a), expected)) return 1;
        for (int lane = 0; lane < LANES; ++lane) expected[lane] = signed_absolute_bits(left[lane] + 1u);
        if (check_bits("absolute value of reused intermediate", signed_absolute_incremented(a), expected)) return 1;
        for (int lane = 0; lane < LANES; ++lane)
            expected[lane] = signed_absolute_bits(compare_signed(0, left[lane], right[lane]) ? left[lane] : right[lane]);
        if (check_bits("masked signed absolute value", signed_absolute_selected(a, b), expected)) return 1;
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
            uint32_t unsigned_mask = 0, literal_mask = 0, literal_first_mask = 0;
            for (int lane = 0; lane < LANES; ++lane) {
                const bool chosen = compare_unsigned(comparison, left[lane], right[lane]);
                expected[lane] = chosen ? left[lane] : right[lane];
                if (chosen) unsigned_mask |= 1u << lane;
                if (compare_unsigned(comparison, left[lane], 0x80000000u)) literal_mask |= 1u << lane;
                if (compare_unsigned(comparison, 0x80000000u, left[lane])) literal_first_mask |= 1u << lane;
            }
            if (check_bits("unsigned comparison", unsigned_comparisons[comparison](a, b), expected)) return 1;
            if (unsigned_masks[comparison](a, b) != unsigned_mask
                || unsigned_literals[comparison](a) != literal_mask
                || unsigned_literal_first[comparison](a) != literal_first_mask) {
                fprintf(stderr, "unsigned predicate %d disagrees with C ordering\n", comparison);
                return 1;
            }
            for (int lane = 0; lane < LANES; ++lane) expected[lane] += left[lane] - right[lane];
            if (check_bits("live unsigned comparison inputs", unsigned_compositions[comparison](a, b), expected)) return 1;
        }
        uint32_t less_mask = 0;
        for (int lane = 0; lane < LANES; ++lane)
            if (left[lane] < right[lane]) less_mask |= 1u << lane;
        if (unsigned_all(a, b) != (less_mask == ((1u << LANES) - 1u))
            || unsigned_any(a, b) != (less_mask != 0)
            || unsigned_equal_self(a) != ((1u << LANES) - 1u)
            || unsigned_less_self(a) != 0u) return 1;
        const float_rack unsigned_flags = unsigned_gap_flags(a);
        for (int lane = 0; lane < LANES; ++lane)
            if (unsigned_flags[lane] != (left[lane] >= 0x80000000u ? 1.0f : 2.0f)) return 1;
        for (int lane = 0; lane < LANES; ++lane)
            expected[lane] = signed_bits(left[lane]) < 0 ? left[lane] - 1u : left[lane] + 1u;
        if (check_bits("integer tines and gaps", integer_gaps(a), expected)) return 1;

        const uint32_t uniform_bits[] = {0u, 1u, 0x7fffffffu, 0x80000000u, 0xffffffffu};
        for (unsigned uniform = 0; uniform < sizeof uniform_bits / sizeof uniform_bits[0]; ++uniform) {
            const uint32_t amount = uniform_bits[uniform];
            for (int lane = 0; lane < LANES; ++lane) expected[lane] = left[lane] + amount;
            if (check_bits("signed uniform broadcast", signed_uniform_add(a, signed_bits(amount)), expected)) return 1;
            for (int lane = 0; lane < LANES; ++lane) expected[lane] = ((left[lane] ^ amount) + left[lane]) * (amount + 1u);
            if (check_bits("unsigned uniforms and retained input", unsigned_uniform_keep(amount, a, amount + 1u), expected)) return 1;
            for (int lane = 0; lane < LANES; ++lane) expected[lane] = amount & ~left[lane];
            if (check_bits("uniform-first complement", unsigned_uniform_reverse(amount, a), expected)) return 1;
            for (int lane = 0; lane < LANES; ++lane) {
                const uint32_t low = left[lane] < amount ? amount : left[lane];
                expected[lane] = low > 0x80000001u ? 0x80000001u : low;
            }
            if (check_bits("unsigned uniform extrema", unsigned_uniform_clamp(a, amount, 0x80000001u), expected)) return 1;
        }
        for (int lane = 0; lane < LANES; ++lane) expected[lane] = ((0xffffffffu + 3u) ^ (0x80000000u * 5u)) - 7u + 11u;
        if (check_bits("six integer argument registers", six_integer_slots(0xffffffffu, 3u, 0x80000000u, 5u, 7u, 11u), expected)) return 1;
#ifdef __aarch64__
        for (int lane = 0; lane < LANES; ++lane) expected[lane] += 13u * 17u;
        if (check_bits("eight AAPCS64 integer registers", eight_integer_slots(0xffffffffu, 3u, 0x80000000u, 5u, 7u, 11u, 13u, 17u), expected)) return 1;
#endif

        float first[LANES], second[LANES];
        for (int lane = 0; lane < LANES; ++lane) {
            first[lane] = (float)(lane - 3);
            second[lane] = (float)(3 - lane);
        }
        float_rack f, g;
        memcpy(&f, first, sizeof f);
        memcpy(&g, second, sizeof g);
        const float_rack boundary = integer_float_boundary(INT32_MIN, f, 2.0f, 0x80000000u, a);
        const float_rack full_vector_arguments = eight_vector_slots(f, f, f, f, f, f, f, f, INT32_MIN);
        const float_rack full_vector_arguments_other = eight_vector_slots(f, f, f, f, f, f, f, f, INT32_MAX);
        for (int lane = 0; lane < LANES; ++lane) {
            const float answer = left[lane] < 0x80000000u ? first[lane] * 2.0f : first[lane] + 1.0f;
            if (boundary[lane] != answer || full_vector_arguments[lane] != first[lane] * 8.0f
                || full_vector_arguments_other[lane] != first[lane]) {
                fprintf(stderr, "mixed integer/SIMD argument counters disagree\n");
                return 1;
            }
        }
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
