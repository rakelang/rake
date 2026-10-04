#include <fenv.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef float rack __attribute__((vector_size(LANES * 4)));
typedef int32_t signed_rack __attribute__((vector_size(LANES * 4)));
typedef uint32_t unsigned_rack __attribute__((vector_size(LANES * 4)));

extern float float_uniform_arithmetic(float, float);
extern float float_reduced_spread(rack);
extern float float_reduced_half_sum(rack);
extern rack float_spread_keep(rack, float);
extern int32_t signed_uniform_arithmetic(int32_t, int32_t);
extern uint32_t unsigned_uniform_arithmetic(uint32_t, uint32_t);
extern int32_t signed_reduced_span(signed_rack);
extern uint32_t unsigned_reduced_span(unsigned_rack);
extern uint32_t unsigned_mask_offset(rack);
extern unsigned_rack unsigned_extracted_keep(unsigned_rack);
extern float float_uniform_negation(float);
extern float float_negative_sum(rack);
extern float float_negated_extraction(rack);
extern rack float_negated_keep(rack);
extern int32_t signed_uniform_negation(int32_t);
extern int32_t signed_negative_sum(signed_rack);
extern signed_rack signed_negated_keep(signed_rack);
extern signed_rack float_signed_bits(rack);
extern unsigned_rack float_unsigned_bits(rack);
extern rack signed_float_bits(signed_rack);
extern rack unsigned_float_bits(unsigned_rack);
extern rack float_bitcast_round_trip(rack);
extern unsigned_rack bitcast_keep_input(rack);

extern bool mask_all(rack);
extern bool mask_any(rack);
extern uint32_t mask_bits(rack);
extern uint32_t mask_gap_bits(rack);
extern uint32_t mask_composed(rack);
extern uint32_t mixed_and(rack, bool);
extern uint32_t mixed_or(rack, bool);

extern rack uniform_lt(rack, rack, float, float);
extern rack uniform_le(rack, rack, float, float);
extern rack uniform_gt(rack, rack, float, float);
extern rack uniform_ge(rack, rack, float, float);
extern rack uniform_eq(rack, rack, float, float);
extern rack uniform_ne(rack, rack, float, float);
extern rack uniform_fused(rack, rack, float);
extern rack uniform_literal_right(rack, rack, float);
extern rack uniform_literal_left(rack, rack, float);
extern rack uniform_extracted(rack, rack);
extern rack uniform_guarded_roots(rack, float);
extern rack uniform_nested(rack, float, float);
extern rack boolean_choice(rack, bool, rack);
extern rack boolean_fused(rack, rack, bool);
extern rack boolean_any(rack, rack);
extern rack boolean_all(rack, rack);
extern bool boolean_identity(bool);
extern bool boolean_and(bool, bool);
extern bool boolean_or(bool, bool);
extern bool boolean_not(bool);
extern rack boolean_guarded_roots(rack, bool);
extern rack boolean_nested(rack, bool);
extern rack boolean_six_slots(bool, bool, bool, bool, bool, bool);
extern rack boolean_eight_vectors(rack, rack, rack, rack, rack, rack, rack, rack, bool);
extern rack compound_choice(rack, rack, bool, float, float);
extern rack compound_and(rack, rack, bool, float);
extern rack compound_or(rack, rack, bool, float);
extern rack compound_nested(rack, bool, float);
extern uint32_t poison_boolean_0(void);
extern uint32_t poison_boolean_1(void);

extern rack shuffle_reverse(rack);
extern rack shuffle_rotate(rack);
extern rack shuffle_repeat(rack);
extern rack shuffle_identity(rack);
extern rack shuffle_weave(rack, rack);
extern rack shuffle_mixed(rack, rack);
extern rack shuffle_right(rack, rack);
extern rack shuffle_keep_inputs(rack, rack);
extern rack shuffle_same_input(rack);

#define DECLARE_LANE(index) \
    extern float extract_lane_##index(rack); \
    extern rack broadcast_lane_##index(rack); \
    extern rack keep_source_lane_##index(rack); \
    extern rack insert_lane_##index(rack, float); \
    extern rack insert_constant_lane_##index(rack); \
    extern rack insert_keep_source_lane_##index(rack, float); \
    extern rack insert_keep_scalar_lane_##index(rack, float); \
    extern rack relocate_lane_##index(rack); \
    DECLARE_INTEGER_LANE(signed, int32_t, signed_rack, index) \
    DECLARE_INTEGER_LANE(unsigned, uint32_t, unsigned_rack, index)
#define DECLARE_INTEGER_LANE(kind, scalar, vector, index) \
    extern scalar extract_##kind##_lane_##index(vector); \
    extern vector broadcast_##kind##_lane_##index(vector); \
    extern vector keep_##kind##_lane_##index(vector); \
    extern vector insert_##kind##_lane_##index(vector, scalar); \
    extern vector insert_keep_##kind##_lane_##index(vector, scalar); \
    extern vector relocate_##kind##_lane_##index(vector); \
    extern vector insert_constant_##kind##_lane_##index(vector);
DECLARE_LANE(0) DECLARE_LANE(1) DECLARE_LANE(2) DECLARE_LANE(3)
#if LANES > 4
DECLARE_LANE(4) DECLARE_LANE(5) DECLARE_LANE(6) DECLARE_LANE(7)
#endif
#if LANES > 8
DECLARE_LANE(8) DECLARE_LANE(9) DECLARE_LANE(10) DECLARE_LANE(11)
DECLARE_LANE(12) DECLARE_LANE(13) DECLARE_LANE(14) DECLARE_LANE(15)
#endif

#define FIRST_FOUR(function) function##0, function##1, function##2, function##3
#if LANES == 4
#define ALL_LANES(function) FIRST_FOUR(function)
#elif LANES == 8
#define ALL_LANES(function) FIRST_FOUR(function), function##4, function##5, function##6, function##7
#else
#define ALL_LANES(function) FIRST_FOUR(function), function##4, function##5, function##6, function##7, \
    function##8, function##9, function##10, function##11, function##12, function##13, function##14, function##15
#endif

static uint32_t bits(float value)
{
    uint32_t result;
    memcpy(&result, &value, sizeof result);
    return result;
}

static int check_bitcasts(void)
{
    const uint32_t patterns[] = {
        0u, 0x80000000u, 1u, 0x80000001u, 0x007fffffu, 0x00800000u,
        0x3f800000u, 0xbf800000u, 0x7f7fffffu, 0xff7fffffu,
        0x7f800000u, 0xff800000u, 0x7fc12345u, 0xffc54321u,
        0x7f812345u, 0xff854321u, 0xffffffffu, 0x12345678u
    };
    uint32_t random = 0x31415926u;
    for (unsigned sample = 0; sample < 256; ++sample) {
        uint32_t input[LANES], output[LANES];
        for (int lane = 0; lane < LANES; ++lane) {
            random = random * 1664525u + 1013904223u;
            input[lane] = sample < sizeof patterns / sizeof patterns[0]
                ? patterns[(sample + (unsigned)lane) % (sizeof patterns / sizeof patterns[0])]
                : random;
        }
        rack floating;
        signed_rack signed_bits;
        unsigned_rack unsigned_bits;
        memcpy(&floating, input, sizeof floating);
        memcpy(&signed_bits, input, sizeof signed_bits);
        memcpy(&unsigned_bits, input, sizeof unsigned_bits);
        /* The independent oracle is byte preservation, with no FP operation. */
        feclearexcept(FE_ALL_EXCEPT);
        const signed_rack as_signed = float_signed_bits(floating);
        const unsigned_rack as_unsigned = float_unsigned_bits(floating);
        const rack from_signed = signed_float_bits(signed_bits);
        const rack from_unsigned = unsigned_float_bits(unsigned_bits);
        const rack round_trip = float_bitcast_round_trip(floating);
        if (memcmp(&as_signed, input, sizeof input)
            || memcmp(&as_unsigned, input, sizeof input)
            || memcmp(&from_signed, input, sizeof input)
            || memcmp(&from_unsigned, input, sizeof input)
            || memcmp(&round_trip, input, sizeof input)) return 87;
        const unsigned_rack kept = bitcast_keep_input(floating);
        memcpy(output, &kept, sizeof output);
        for (int lane = 0; lane < LANES; ++lane)
            if (output[lane] != 0x80000000u) return 88;
        if (fetestexcept(FE_ALL_EXCEPT)) return 89;
    }
    return 0;
}

static int check_uniform_arithmetic(void)
{
    /* Each volatile store independently fixes a binary32 rounding boundary.
       Unsigned C arithmetic supplies the 32-bit wrapping oracle. */
    const float floating[] = { -16777216.0f, -3.5f, -0.0f, 0.25f, 1.0f, 16777216.0f };
    const uint32_t integers[] = { 0u, 1u, 2u, 0x7fffffffu, 0x80000000u, UINT32_MAX };
    /* Negation flips the float sign bit or subtracts integer bits from zero.
       Neither oracle performs signed C arithmetic that could overflow. */
    const uint32_t sign_patterns[] = {
        0u, 0x80000000u, 1u, 0x80000001u, 0x3f800000u, 0xbf800000u,
        0x7f800000u, 0xff800000u, 0x7fc12345u, 0xffc54321u,
        0x7f812345u, 0xff854321u
    };
    for (unsigned i = 0; i < sizeof sign_patterns / sizeof sign_patterns[0]; ++i) {
        float value;
        rack vector;
        uint32_t lanes[LANES];
        memcpy(&value, &sign_patterns[i], sizeof value);
        for (int lane = 0; lane < LANES; ++lane) lanes[lane] = sign_patterns[i];
        memcpy(&vector, lanes, sizeof vector);
        feclearexcept(FE_ALL_EXCEPT);
        const uint32_t expected = sign_patterns[i] ^ 0x80000000u;
        if (bits(float_uniform_negation(value)) != expected
            || bits(float_negated_extraction(vector)) != expected
            || fetestexcept(FE_ALL_EXCEPT)) return 85;
    }
    for (unsigned i = 0; i < sizeof integers / sizeof integers[0]; ++i) {
        int32_t value;
        memcpy(&value, &integers[i], sizeof value);
        const int32_t negated = signed_uniform_negation(value);
        uint32_t actual;
        memcpy(&actual, &negated, sizeof actual);
        if (actual != 0u - integers[i]) return 86;
    }
    for (unsigned l = 0; l < sizeof floating / sizeof floating[0]; ++l)
        for (unsigned r = 1; r < sizeof floating / sizeof floating[0]; ++r) {
            if (floating[r] == 0.0f) continue;
            volatile float added = floating[l] + floating[r];
            volatile float multiplied = added * floating[r];
            volatile float subtracted = multiplied - floating[l];
            volatile float expected = subtracted / floating[r];
            if (bits(float_uniform_arithmetic(floating[l], floating[r])) != bits(expected)) return 80;
        }
    for (unsigned l = 0; l < sizeof integers / sizeof integers[0]; ++l)
        for (unsigned r = 0; r < sizeof integers / sizeof integers[0]; ++r) {
            const uint32_t expected = (integers[l] + integers[r]) * integers[r] - integers[l];
            int32_t left, right, signed_result;
            memcpy(&left, &integers[l], sizeof left);
            memcpy(&right, &integers[r], sizeof right);
            signed_result = signed_uniform_arithmetic(left, right);
            uint32_t actual;
            memcpy(&actual, &signed_result, sizeof actual);
            if (actual != expected || unsigned_uniform_arithmetic(integers[l], integers[r]) != expected) return 81;
        }
    float values[LANES], kept[LANES];
    uint32_t integer_values[LANES], integer_kept[LANES], mask = 0u, integer_total = 0u;
    float minimum = 0.0f, maximum = 0.0f;
    volatile float total = 0.0f;
    int32_t signed_minimum = INT32_MAX, signed_maximum = INT32_MIN;
    uint32_t unsigned_minimum = UINT32_MAX, unsigned_maximum = 0u;
    for (int lane = 0; lane < LANES; ++lane) {
        values[lane] = lane % 2 ? -(float)(lane + 1) : (float)(lane + 1);
        if (!lane || values[lane] < minimum) minimum = values[lane];
        if (!lane || values[lane] > maximum) maximum = values[lane];
        if (values[lane] > 0.0f) mask |= 1u << lane;
        total = total + values[lane];
        integer_values[lane] = integers[(lane + 5) % 6];
        integer_total += integer_values[lane];
        int32_t signed_value;
        memcpy(&signed_value, &integer_values[lane], sizeof signed_value);
        if (signed_value < signed_minimum) signed_minimum = signed_value;
        if (signed_value > signed_maximum) signed_maximum = signed_value;
        if (integer_values[lane] < unsigned_minimum) unsigned_minimum = integer_values[lane];
        if (integer_values[lane] > unsigned_maximum) unsigned_maximum = integer_values[lane];
    }
    rack vector;
    signed_rack signed_vector;
    unsigned_rack unsigned_vector;
    memcpy(&vector, values, sizeof vector);
    memcpy(&signed_vector, integer_values, sizeof signed_vector);
    memcpy(&unsigned_vector, integer_values, sizeof unsigned_vector);
    volatile float spread = maximum - minimum;
    volatile float half_sum = total / 2.0f;
    if (bits(float_reduced_spread(vector)) != bits(spread)
        || bits(float_reduced_half_sum(vector)) != bits(half_sum)) return 82;
    const int32_t negative_total = signed_negative_sum(signed_vector);
    uint32_t negative_total_bits;
    memcpy(&negative_total_bits, &negative_total, sizeof negative_total_bits);
    if (bits(float_negative_sum(vector)) != (bits(total) ^ 0x80000000u)
        || negative_total_bits != 0u - integer_total) return 87;
    rack float_negative = float_negated_keep(vector);
    signed_rack signed_negative = signed_negated_keep(signed_vector);
    float float_negative_values[LANES];
    uint32_t signed_negative_values[LANES];
    memcpy(float_negative_values, &float_negative, sizeof float_negative);
    memcpy(signed_negative_values, &signed_negative, sizeof signed_negative);
    for (int lane = 0; lane < LANES; ++lane) {
        volatile float expected = values[lane] - values[0];
        if (bits(float_negative_values[lane]) != bits(expected)
            || signed_negative_values[lane] != integer_values[lane] - integer_values[0]) return 88;
    }
    const int32_t signed_span = signed_reduced_span(signed_vector);
    uint32_t signed_span_bits;
    memcpy(&signed_span_bits, &signed_span, sizeof signed_span_bits);
    if (signed_span_bits != (uint32_t)signed_maximum - (uint32_t)signed_minimum
        || unsigned_reduced_span(unsigned_vector) != unsigned_maximum - unsigned_minimum
        || unsigned_mask_offset(vector) != mask - 1u) return 83;
    vector = float_spread_keep(vector, 0.5f);
    memcpy(kept, &vector, sizeof vector);
    volatile float scaled = spread * 0.5f;
    scaled = scaled + 1.0f;
    unsigned_vector = unsigned_extracted_keep(unsigned_vector);
    memcpy(integer_kept, &unsigned_vector, sizeof unsigned_vector);
    const uint32_t offset = integer_values[0] * UINT32_MAX + 1u;
    for (int lane = 0; lane < LANES; ++lane) {
        volatile float expected = values[lane] + scaled;
        if (bits(kept[lane]) != bits(expected)
            || integer_kept[lane] != integer_values[lane] + offset) return 84;
    }
    return 0;
}

static int check_uniform_conditions(void)
{
    rack (*const comparisons[])(rack, rack, float, float) = {
        uniform_lt, uniform_le, uniform_gt, uniform_ge, uniform_eq, uniform_ne
    };
    const uint32_t selectors[] = {
        0u, 0x80000000u, 0x3f800000u, 0xbf800000u, 1u, 0x80000001u,
        0x7f800000u, 0xff800000u, 0x7fc12345u, 0xffc54321u
    };
    uint32_t first[LANES], second[LANES], output[LANES];
    for (int lane = 0; lane < LANES; ++lane) {
        first[lane] = selectors[lane % 10];
        second[lane] = selectors[(lane + 3) % 10];
    }
    rack a, b;
    memcpy(&a, first, sizeof a);
    memcpy(&b, second, sizeof b);
    for (int l = 0; l < 10; ++l) for (int r = 0; r < 10; ++r) {
        float left, right;
        memcpy(&left, &selectors[l], sizeof left);
        memcpy(&right, &selectors[r], sizeof right);
        const bool ordered = !isnan(left) && !isnan(right);
        const bool expected[] = {
            ordered && left < right, ordered && left <= right,
            ordered && left > right, ordered && left >= right,
            ordered && left == right, ordered && left != right
        };
        for (int comparison = 0; comparison < 6; ++comparison) {
            feclearexcept(FE_ALL_EXCEPT);
            const rack result = comparisons[comparison](a, b, left, right);
            memcpy(output, &result, sizeof output);
            if (fetestexcept(FE_ALL_EXCEPT)) return 18;
            for (int lane = 0; lane < LANES; ++lane)
                if (output[lane] != (expected[comparison] ? first[lane] : second[lane])) return 19;
        }
        const rack literal_results[] = {
            uniform_literal_right(a, b, left), uniform_literal_left(a, b, left)
        };
        for (int comparison = 0; comparison < 2; ++comparison) {
            memcpy(output, &literal_results[comparison], sizeof output);
            for (int lane = 0; lane < LANES; ++lane)
                if (output[lane] != (left > 0.0f ? first[lane] : second[lane])) return 20;
        }
    }
    for (int positive = 0; positive < 2; ++positive) {
        float values[LANES], result[LANES];
        for (int lane = 0; lane < LANES; ++lane)
            values[lane] = (positive ? 1.0f : -1.0f) * (float)((lane + 1) * (lane + 1));
        memcpy(&a, values, sizeof a);
        const rack extracted = uniform_extracted(a, b);
        memcpy(output, &extracted, sizeof output);
        for (int lane = 0; lane < LANES; ++lane)
            if (output[lane] != (positive ? bits(values[lane]) : second[lane])) return 21;
        feclearexcept(FE_ALL_EXCEPT);
        const rack roots = uniform_guarded_roots(a, positive ? 1.0f : -1.0f);
        memcpy(result, &roots, sizeof result);
        if (fetestexcept(FE_ALL_EXCEPT)) return 22;
        for (int lane = 0; lane < LANES; ++lane)
            if (bits(result[lane]) != bits((positive ? 1.0f : -1.0f) * (float)(lane + 1))) return 23;
    }
    float values[LANES], result[LANES];
    for (int lane = 0; lane < LANES; ++lane)
        values[lane] = lane % 2 ? -(float)((lane + 1) * (lane + 1)) : (float)((lane + 1) * (lane + 1));
    memcpy(&a, values, sizeof a);
    for (int root = 0; root < 2; ++root) {
        feclearexcept(FE_ALL_EXCEPT);
        /* The untaken division has a zero denominator; outer gaps include negative roots. */
        const rack nested = uniform_nested(a, root ? 1.0f : -1.0f, root ? 0.0f : 2.0f);
        memcpy(result, &nested, sizeof result);
        if (fetestexcept(FE_ALL_EXCEPT)) return 24;
        for (int lane = 0; lane < LANES; ++lane) {
            const float expected = values[lane] > 0.0f
                ? (root ? sqrtf(values[lane]) : values[lane] / 2.0f) : 0.0f;
            if (bits(result[lane]) != bits(expected)) return 25;
        }
    }
    float other[LANES];
    for (int lane = 0; lane < LANES; ++lane) other[lane] = (float)(lane * 2 - 3);
    memcpy(&b, other, sizeof b);
    for (int first_arm = 0; first_arm < 2; ++first_arm) {
        const rack fused = uniform_fused(a, b, first_arm ? 1.0f : -1.0f);
        memcpy(result, &fused, sizeof result);
        for (int lane = 0; lane < LANES; ++lane) {
            const float shifted = values[lane] + 1.0f;
            const float expected = (first_arm ? shifted : other[lane]) + shifted;
            if (bits(result[lane]) != bits(expected)) return 26;
        }
    }
    return 0;
}

static int check_mask_reductions(void)
{
    const uint32_t every = (1u << LANES) - 1u;
    /* Every lane pattern, independently assembled from scalar values. */
    for (uint32_t pattern = 0; pattern <= every; ++pattern) {
        float input[LANES];
        for (int lane = 0; lane < LANES; ++lane)
            input[lane] = pattern & (1u << lane) ? 1.0f : -1.0f;
        rack values;
        memcpy(&values, input, sizeof values);
        if (mask_all(values) != (pattern == every) || mask_any(values) != (pattern != 0)
            || mask_bits(values) != pattern || mask_gap_bits(values) != (pattern ^ every)
            || mask_composed(values) != pattern) return 15;
        for (int enabled = 0; enabled < 2; ++enabled)
            if (mixed_and(values, enabled) != (enabled ? pattern : 0)
                || mixed_or(values, enabled) != (enabled ? every : pattern)) return 44;
        const rack choices[] = { boolean_any(values, -values), boolean_all(values, -values) };
        for (int operation = 0; operation < 2; ++operation) {
            float output[LANES];
            memcpy(output, &choices[operation], sizeof output);
            const bool take = operation ? pattern == every : pattern != 0;
            for (int lane = 0; lane < LANES; ++lane)
                if (bits(output[lane]) != bits(take ? input[lane] : -input[lane])) return 27;
        }
    }
    /* Quiet NaNs and signed zeros are gaps in an ordered positive predicate. */
    const uint32_t patterns[] = { 0x7fc12345u, 0xffc12345u, 0u, 0x80000000u,
                                 0x7f800000u, 0xff800000u, 1u, 0x80000001u };
    for (int scenario = 0; scenario < 8; ++scenario) {
        float input[LANES];
        uint32_t expected = 0;
        for (int lane = 0; lane < LANES; ++lane) {
            uint32_t raw = patterns[(lane + scenario) % 8];
            memcpy(&input[lane], &raw, sizeof raw);
            if (input[lane] > 0.0f) expected |= 1u << lane;
        }
        rack values;
        memcpy(&values, input, sizeof values);
        feclearexcept(FE_ALL_EXCEPT);
        if (mask_all(values) != (expected == every) || mask_any(values) != (expected != 0)
            || mask_bits(values) != expected || mask_gap_bits(values) != (expected ^ every)
            || mask_composed(values) != expected) return 16;
        if (fetestexcept(FE_ALL_EXCEPT)) return 17;
    }
    return 0;
}

static int check_boolean_conditions(void)
{
    if (poison_boolean_0() != 0 || poison_boolean_1() != 1) return 28;
    for (int left = 0; left < 2; ++left)
        for (int right = 0; right < 2; ++right)
            if (boolean_and(left, right) != (left && right)
                || boolean_or(left, right) != (left || right)
                || boolean_not(left) != !left) return 45;
    uint32_t signaling_bits[LANES];
    for (int lane = 0; lane < LANES; ++lane) signaling_bits[lane] = 0x7f812345u;
    rack signaling_values;
    memcpy(&signaling_values, signaling_bits, sizeof signaling_values);
    for (int enabled = 0; enabled < 2; ++enabled) {
        feclearexcept(FE_ALL_EXCEPT);
        if (mixed_or(signaling_values, enabled) != (enabled ? (1u << LANES) - 1u : 0)
            || !!fetestexcept(FE_INVALID) != !enabled) return 46;
    }
    const uint32_t patterns[] = {0u, 0x80000000u, 1u, 0x80000001u,
        0x7f800000u, 0xff800000u, 0x7fc12345u, 0xffc54321u};
    uint32_t first[LANES], second[LANES], output[LANES];
    for (int lane = 0; lane < LANES; ++lane) {
        first[lane] = patterns[lane % 8];
        second[lane] = patterns[(lane + 3) % 8];
    }
    rack a, b;
    memcpy(&a, first, sizeof a);
    memcpy(&b, second, sizeof b);
    for (int take = 0; take < 2; ++take) {
        feclearexcept(FE_ALL_EXCEPT);
        const rack chosen = boolean_choice(a, take, b);
        memcpy(output, &chosen, sizeof output);
        if (fetestexcept(FE_ALL_EXCEPT) || boolean_identity(take) != (bool)take) return 29;
        for (int lane = 0; lane < LANES; ++lane)
            if (output[lane] != (take ? first[lane] : second[lane])) return 30;
    }
    const float conditions[] = { -INFINITY, -1.0f, -0.0f, 0.0f, 1.0f, INFINITY, NAN };
    for (int enabled = 0; enabled < 2; ++enabled)
        for (size_t left = 0; left < sizeof conditions / sizeof conditions[0]; ++left)
            for (size_t right = 0; right < sizeof conditions / sizeof conditions[0]; ++right) {
                const bool chosen = enabled && (!(conditions[left] >= conditions[right])
                    || conditions[left] == conditions[right]);
                const rack combined = compound_choice(a, b, enabled, conditions[left], conditions[right]);
                memcpy(output, &combined, sizeof output);
                for (int lane = 0; lane < LANES; ++lane)
                    if (output[lane] != (chosen ? first[lane] : second[lane])) return 38;
            }
    /* Skipped scalar comparisons must not raise invalid for a signalling NaN.
       This oracle checks the CPU's flags, not just the selected lane bits. */
    const uint32_t uniform_signaling_bits = 0x7f812345u;
    float signaling;
    memcpy(&signaling, &uniform_signaling_bits, sizeof signaling);
    for (int disjunction = 0; disjunction < 2; ++disjunction)
        for (int enabled = 0; enabled < 2; ++enabled) {
            feclearexcept(FE_ALL_EXCEPT);
            const rack combined = disjunction ? compound_or(a, b, enabled, signaling)
                : compound_and(a, b, enabled, signaling);
            const bool skipped = disjunction ? enabled : !enabled;
            if (!!fetestexcept(FE_INVALID) != !skipped
                || fetestexcept(FE_DIVBYZERO | FE_OVERFLOW | FE_UNDERFLOW | FE_INEXACT)) return 39;
            memcpy(output, &combined, sizeof output);
            for (int lane = 0; lane < LANES; ++lane)
                if (output[lane] != ((disjunction && enabled) ? first[lane] : second[lane])) return 40;
        }
    float first_values[LANES], second_values[LANES], actual[LANES];
    for (int lane = 0; lane < LANES; ++lane) {
        first_values[lane] = (float)(lane + 1);
        second_values[lane] = (float)(3 - lane);
    }
    memcpy(&a, first_values, sizeof a);
    memcpy(&b, second_values, sizeof b);
    for (int take = 0; take < 2; ++take) {
        const rack fused = boolean_fused(a, b, take);
        memcpy(actual, &fused, sizeof actual);
        for (int lane = 0; lane < LANES; ++lane) {
            const float chosen = take ? first_values[lane] : second_values[lane];
            if (bits(actual[lane]) != bits((chosen + first_values[lane]) + second_values[lane])) return 31;
        }
        const rack full = boolean_eight_vectors(a, a, a, a, a, a, a, b, take);
        memcpy(actual, &full, sizeof actual);
        for (int lane = 0; lane < LANES; ++lane)
            if (bits(actual[lane]) != bits(take ? 7.0f * first_values[lane] + second_values[lane] : second_values[lane])) return 32;
    }
    for (unsigned pattern = 0; pattern < 64; ++pattern) {
        const rack combined = boolean_six_slots(pattern & 1, pattern & 2, pattern & 4,
            pattern & 8, pattern & 16, pattern & 32);
        memcpy(actual, &combined, sizeof actual);
        for (int lane = 0; lane < LANES; ++lane)
            if (bits(actual[lane]) != bits((float)pattern)) return 33;
    }
    for (int positive = 0; positive < 2; ++positive) {
        for (int lane = 0; lane < LANES; ++lane)
            first_values[lane] = (positive ? 1.0f : -1.0f) * (float)((lane + 1) * (lane + 1));
        memcpy(&a, first_values, sizeof a);
        feclearexcept(FE_ALL_EXCEPT);
        const rack rooted = boolean_guarded_roots(a, positive);
        memcpy(actual, &rooted, sizeof actual);
        if (fetestexcept(FE_ALL_EXCEPT)) return 34;
        for (int lane = 0; lane < LANES; ++lane)
            if (bits(actual[lane]) != bits((positive ? 1.0f : -1.0f) * (float)(lane + 1))) return 35;
    }
    for (int lane = 0; lane < LANES; ++lane)
        first_values[lane] = lane % 2 ? -1.0f : 4.0f;
    memcpy(&a, first_values, sizeof a);
    for (int take = 0; take < 2; ++take) {
        feclearexcept(FE_ALL_EXCEPT);
        const rack nested = boolean_nested(a, take);
        memcpy(actual, &nested, sizeof actual);
        if (fetestexcept(FE_ALL_EXCEPT)) return 36;
        for (int lane = 0; lane < LANES; ++lane)
            if (bits(actual[lane]) != bits(first_values[lane] > 0.0f ? 2.0f : 0.0f)) return 37;
    }
    for (int lane = 0; lane < LANES; ++lane)
        first_values[lane] = lane % 2 ? -1.0f : 9.0f;
    memcpy(&a, first_values, sizeof a);
    for (int enabled = 0; enabled < 2; ++enabled) {
        feclearexcept(FE_ALL_EXCEPT);
        const rack nested = compound_nested(a, enabled, signaling);
        memcpy(actual, &nested, sizeof actual);
        if (!!fetestexcept(FE_INVALID) != enabled
            || fetestexcept(FE_DIVBYZERO | FE_OVERFLOW | FE_UNDERFLOW | FE_INEXACT)) return 41;
        for (int lane = 0; lane < LANES; ++lane) {
            const float expected = first_values[lane] > 0.0f ? (enabled ? 4.5f : 3.0f) : 0.0f;
            if (bits(actual[lane]) != bits(expected)) return 42;
        }
    }
    return 0;
}

static int check_shuffles(const uint32_t patterns[16], int scenario)
{
    uint32_t first[LANES], second[LANES], output[LANES];
    for (int lane = 0; lane < LANES; ++lane) {
        first[lane] = patterns[(lane + scenario) % 16];
        second[lane] = patterns[(15 - lane + scenario) % 16] ^ 0x80000000u;
    }
    rack a, b;
    memcpy(&a, first, sizeof a);
    memcpy(&b, second, sizeof b);
    feclearexcept(FE_ALL_EXCEPT);
    const rack results[] = {
        shuffle_reverse(a), shuffle_rotate(a), shuffle_repeat(a), shuffle_identity(a),
        shuffle_weave(a, b), shuffle_mixed(a, b), shuffle_right(a, b), shuffle_same_input(a)
    };
    if (fetestexcept(FE_ALL_EXCEPT)) return 12;
    for (int pattern = 0; pattern < 8; ++pattern) {
        memcpy(output, &results[pattern], sizeof output);
        for (int lane = 0; lane < LANES; ++lane) {
            int selected;
            switch (pattern) {
            case 0: selected = LANES - 1 - lane; break;
            case 1: selected = (lane + 1) % LANES; break;
            case 2: selected = LANES - 1; break;
            case 3: selected = lane; break;
            case 4: selected = lane / 2 + (lane % 2) * LANES; break;
            case 6: selected = 2 * LANES - 1 - lane; break;
            default: selected = (7 * lane + 3) % (2 * LANES); break;
            }
            const uint32_t expected = selected < LANES || pattern == 7
                ? first[selected % LANES] : second[selected - LANES];
            if (output[lane] != expected) {
                fprintf(stderr, "shuffle %d lane %d: expected %08x, got %08x\n",
                        pattern, lane, expected, output[lane]);
                return 13;
            }
        }
    }
    return 0;
}

/* This scalar bit oracle uses separately compiled C vector/scalar signatures.
   No floating interpretation or signed arithmetic enters its expectations. */
#define CHECK_INTEGER_LANE_TRANSFERS(kind, scalar, vector, constant) \
static int check_##kind##_lane_transfers(void) \
{ \
    scalar (*const extracts[])(vector) = { ALL_LANES(extract_##kind##_lane_) }; \
    vector (*const broadcasts[])(vector) = { ALL_LANES(broadcast_##kind##_lane_) }; \
    vector (*const keeps[])(vector) = { ALL_LANES(keep_##kind##_lane_) }; \
    vector (*const inserts[])(vector, scalar) = { ALL_LANES(insert_##kind##_lane_) }; \
    vector (*const insert_keeps[])(vector, scalar) = { ALL_LANES(insert_keep_##kind##_lane_) }; \
    vector (*const relocates[])(vector) = { ALL_LANES(relocate_##kind##_lane_) }; \
    vector (*const constants[])(vector) = { ALL_LANES(insert_constant_##kind##_lane_) }; \
    const uint32_t patterns[] = { 0u, 1u, UINT32_MAX, 0x80000000u, \
        0x7fffffffu, 0x80000001u, 0x01234567u, 0xfedcba98u, \
        0x7f812345u, 0xff812346u, 0xaaaaaaaau, 0x55555555u, \
        0x00010000u, 0xffff0000u, 0x01010101u, 0x80808080u }; \
    for (int scenario = 0; scenario < 16; ++scenario) { \
        uint32_t input[LANES], output[LANES]; \
        for (int lane = 0; lane < LANES; ++lane) input[lane] = patterns[(lane + scenario) % 16]; \
        vector values; \
        memcpy(&values, input, sizeof values); \
        for (int lane = 0; lane < LANES; ++lane) { \
            feclearexcept(FE_ALL_EXCEPT); \
            if ((uint32_t)extracts[lane](values) != input[lane]) return 38; \
            const vector selected[] = { broadcasts[lane](values), keeps[lane](values), \
                relocates[lane](values), constants[lane](values) }; \
            for (int operation = 0; operation < 4; ++operation) { \
                memcpy(output, &selected[operation], sizeof output); \
                for (int target = 0; target < LANES; ++target) { \
                    uint32_t expected; \
                    if (operation == 0) expected = input[lane]; \
                    else if (operation == 1) expected = input[target] ^ input[lane]; \
                    else if (operation == 2) expected = target == lane ? input[(lane + 1) % LANES] : input[target]; \
                    else expected = target == lane ? (constant) : input[target]; \
                    if (output[target] != expected) { \
                        fprintf(stderr, #kind " transfer %d lane %d target %d: expected %08x got %08x\n", \
                            operation, lane, target, expected, output[target]); \
                        return 39; \
                    } \
                } \
            } \
            for (int replacement_index = 0; replacement_index < 16; ++replacement_index) { \
                scalar replacement; \
                memcpy(&replacement, &patterns[replacement_index], sizeof replacement); \
                const vector replaced[] = { inserts[lane](values, replacement), insert_keeps[lane](values, replacement) }; \
                for (int operation = 0; operation < 2; ++operation) { \
                    memcpy(output, &replaced[operation], sizeof output); \
                    for (int target = 0; target < LANES; ++target) { \
                        uint32_t expected = target == lane ? patterns[replacement_index] : input[target]; \
                        if (operation == 1) expected ^= input[target] ^ patterns[replacement_index]; \
                        if (output[target] != expected) { \
                            fprintf(stderr, #kind " insert %d lane %d target %d: expected %08x got %08x\n", \
                                operation, lane, target, expected, output[target]); \
                            return 40; \
                        } \
                    } \
                } \
            } \
            if (fetestexcept(FE_ALL_EXCEPT)) return 41; \
        } \
    } \
    return 0; \
}
CHECK_INTEGER_LANE_TRANSFERS(signed, int32_t, signed_rack, 0x80000000u)
CHECK_INTEGER_LANE_TRANSFERS(unsigned, uint32_t, unsigned_rack, UINT32_MAX)

int main(void)
{
    const int bitcasts = check_bitcasts();
    if (bitcasts) return bitcasts;
    const int arithmetic = check_uniform_arithmetic();
    if (arithmetic) return arithmetic;
    const int signed_lanes = check_signed_lane_transfers();
    if (signed_lanes) return signed_lanes;
    const int unsigned_lanes = check_unsigned_lane_transfers();
    if (unsigned_lanes) return unsigned_lanes;
    const int boolean = check_boolean_conditions();
    if (boolean) return boolean;
    const int uniform = check_uniform_conditions();
    if (uniform) return uniform;
    const int reduced = check_mask_reductions();
    if (reduced) return reduced;
    float (*const extractions[])(rack) = { ALL_LANES(extract_lane_) };
    rack (*const broadcasts[])(rack) = { ALL_LANES(broadcast_lane_) };
    rack (*const keep_sources[])(rack) = { ALL_LANES(keep_source_lane_) };
    rack (*const insertions[])(rack, float) = { ALL_LANES(insert_lane_) };
    rack (*const constants[])(rack) = { ALL_LANES(insert_constant_lane_) };
    rack (*const insertion_sources[])(rack, float) = { ALL_LANES(insert_keep_source_lane_) };
    rack (*const insertion_scalars[])(rack, float) = { ALL_LANES(insert_keep_scalar_lane_) };
    rack (*const relocations[])(rack) = { ALL_LANES(relocate_lane_) };
    const uint32_t patterns[] = {
        0x00000000u, 0x80000000u, 0x00000001u, 0x80000001u,
        0x007fffffu, 0x807fffffu, 0x3f800000u, 0xbf800000u,
        0x7f7fffffu, 0xff7fffffu, 0x7f800000u, 0xff800000u,
        0x7fc12345u, 0xffc54321u, 0x7f812345u, 0xff812346u
    };
    for (int scenario = 0; scenario < 16; ++scenario) {
        const int shuffled = check_shuffles(patterns, scenario);
        if (shuffled) return shuffled;
        uint32_t input[LANES], output[LANES];
        for (int lane = 0; lane < LANES; ++lane) input[lane] = patterns[(lane + scenario) % 16];
        rack values;
        memcpy(&values, input, sizeof values);
        for (int lane = 0; lane < LANES; ++lane) {
            feclearexcept(FE_ALL_EXCEPT);
            const uint32_t extracted = bits(extractions[lane](values));
            const rack broadcast = broadcasts[lane](values);
            memcpy(output, &broadcast, sizeof output);
            if (fetestexcept(FE_ALL_EXCEPT)) return 1;
            if (extracted != input[lane]) {
                fprintf(stderr, "lane %d: expected %08x, extracted %08x\n", lane, input[lane], extracted);
                return 2;
            }
            for (int target = 0; target < LANES; ++target)
                if (output[target] != input[lane]) return 3;
            /* Every replacement pattern crosses the independent scalar C ABI. */
            for (int replacement_index = 0; replacement_index < 16; ++replacement_index) {
                float replacement;
                memcpy(&replacement, &patterns[replacement_index], sizeof replacement);
                feclearexcept(FE_ALL_EXCEPT);
                const rack replaced = insertions[lane](values, replacement);
                memcpy(output, &replaced, sizeof output);
                if (fetestexcept(FE_ALL_EXCEPT)) return 5;
                for (int target = 0; target < LANES; ++target) {
                    const uint32_t expected = target == lane ? patterns[replacement_index] : input[target];
                    if (output[target] != expected) {
                        fprintf(stderr, "insert lane %d, target %d: expected %08x, got %08x\n",
                                lane, target, expected, output[target]);
                        return 6;
                    }
                }
            }
            feclearexcept(FE_ALL_EXCEPT);
            const rack constant = constants[lane](values);
            memcpy(output, &constant, sizeof output);
            for (int target = 0; target < LANES; ++target)
                if (output[target] != (target == lane ? 0x80000000u : input[target])) return 7;
            const rack relocated = relocations[lane](values);
            memcpy(output, &relocated, sizeof output);
            for (int target = 0; target < LANES; ++target)
                if (output[target] != (target == lane ? input[(lane + 1) % LANES] : input[target])) return 8;
            if (fetestexcept(FE_ALL_EXCEPT)) return 9;
        }
    }
    /* Exact finite sums expose destructive allocation of a still-live source. */
    float input[LANES], output[LANES];
    for (int lane = 0; lane < LANES; ++lane) input[lane] = (float)(2 * lane - 9);
    rack values;
    memcpy(&values, input, sizeof values);
    float second[LANES];
    for (int lane = 0; lane < LANES; ++lane) second[lane] = (float)(lane + 17);
    rack other;
    memcpy(&other, second, sizeof other);
    const rack kept = shuffle_keep_inputs(values, other);
    memcpy(output, &kept, sizeof output);
    for (int lane = 0; lane < LANES; ++lane) {
        const int selected = (7 * lane + 3) % (2 * LANES);
        const float picked = selected < LANES ? input[selected] : second[selected - LANES];
        if (bits(output[lane]) != bits((picked + input[lane]) + second[lane])) return 14;
    }
    for (int lane = 0; lane < LANES; ++lane) {
        const rack composed = keep_sources[lane](values);
        memcpy(output, &composed, sizeof output);
        for (int target = 0; target < LANES; ++target)
            if (bits(output[target]) != bits(input[target] + input[lane])) return 4;
        const float replacement = 3.5f;
        const rack source_kept = insertion_sources[lane](values, replacement);
        memcpy(output, &source_kept, sizeof output);
        for (int target = 0; target < LANES; ++target) {
            const float changed = target == lane ? replacement : input[target];
            if (bits(output[target]) != bits(changed + input[target])) return 10;
        }
        const rack scalar_kept = insertion_scalars[lane](values, replacement);
        memcpy(output, &scalar_kept, sizeof output);
        for (int target = 0; target < LANES; ++target) {
            const float changed = target == lane ? replacement : input[target];
            if (bits(output[target]) != bits(changed + replacement)) return 11;
        }
    }
    printf("native cross-lane bit and ABI agreement: %d lanes\n", LANES);
    return 0;
}
