#include <fenv.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef float rack __attribute__((vector_size(LANES * 4)));

extern bool mask_all(rack);
extern bool mask_any(rack);
extern uint32_t mask_bits(rack);
extern uint32_t mask_gap_bits(rack);
extern uint32_t mask_composed(rack);

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
    extern rack relocate_lane_##index(rack);
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

int main(void)
{
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
