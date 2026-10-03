#include <fenv.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef float rack __attribute__((vector_size(LANES * 4)));

#define DECLARE_LANE(index) \
    extern float extract_lane_##index(rack); \
    extern rack broadcast_lane_##index(rack); \
    extern rack keep_source_lane_##index(rack);
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

int main(void)
{
    float (*const extractions[])(rack) = { ALL_LANES(extract_lane_) };
    rack (*const broadcasts[])(rack) = { ALL_LANES(broadcast_lane_) };
    rack (*const keep_sources[])(rack) = { ALL_LANES(keep_source_lane_) };
    const uint32_t patterns[] = {
        0x00000000u, 0x80000000u, 0x00000001u, 0x80000001u,
        0x007fffffu, 0x807fffffu, 0x3f800000u, 0xbf800000u,
        0x7f7fffffu, 0xff7fffffu, 0x7f800000u, 0xff800000u,
        0x7fc12345u, 0xffc54321u, 0x7f812345u, 0xff812346u
    };
    for (int scenario = 0; scenario < 16; ++scenario) {
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
        }
    }
    /* Exact finite sums expose destructive allocation of a still-live source. */
    float input[LANES], output[LANES];
    for (int lane = 0; lane < LANES; ++lane) input[lane] = (float)(2 * lane - 9);
    rack values;
    memcpy(&values, input, sizeof values);
    for (int lane = 0; lane < LANES; ++lane) {
        const rack composed = keep_sources[lane](values);
        memcpy(output, &composed, sizeof output);
        for (int target = 0; target < LANES; ++target)
            if (bits(output[target]) != bits(input[target] + input[lane])) return 4;
    }
    printf("native extraction bit agreement: %d lanes\n", LANES);
    return 0;
}
