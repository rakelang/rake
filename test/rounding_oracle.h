#include "rounding_values.h"

extern rack round_floor(rack);
extern rack round_ceil(rack);
extern rack round_trunc(rack);
extern rack round_nearest(rack);
extern rack masked_floor(rack, rack);
extern rack masked_ceil(rack, rack);
extern rack masked_trunc(rack, rack);
extern rack masked_nearest(rack, rack);
extern rack nearest_keep_source(rack);

static int check_rounding(void)
{
    rack (*const ordinary[])(rack) = { round_floor, round_ceil, round_trunc, round_nearest };
    rack (*const masked[])(rack, rack) = { masked_floor, masked_ceil, masked_trunc, masked_nearest };
    const size_t count = sizeof(rounding_inputs) / sizeof(rounding_inputs[0]);
    float input[LANES], selector[LANES], output[LANES];
    uint32_t expected[LANES], random = 0x2ab839d1u;
    for (int mode = ROUND_FLOOR; mode <= ROUND_NEAREST; ++mode) {
        for (size_t sample = 0; sample < count + 256; ++sample) {
            uint32_t raw[LANES];
            for (int lane = 0; lane < LANES; ++lane) {
                random = random * 1664525u + 1013904223u;
                raw[lane] = sample < count ? rounding_inputs[(sample + lane) % count] : random;
                memcpy(&input[lane], &raw[lane], sizeof(float));
            }
            for (int phase = -1; phase < 3; ++phase) {
                int invalid = 0;
                for (int lane = 0; lane < LANES; ++lane) {
                    const int active = phase < 0 || (phase < 2 && (lane + phase) % 2 == 0);
                    selector[lane] = active ? 1.0f : -1.0f;
                    expected[lane] = active ? rounding_expected(raw[lane], mode) : 0xc0000000u;
                    invalid |= active && rounding_signaling(raw[lane]);
                }
                feclearexcept(FE_ALL_EXCEPT);
                store(output, phase < 0 ? ordinary[mode](load(input))
                    : masked[mode](load(selector), load(input)));
                if (!!fetestexcept(FE_INVALID) != invalid
                    || fetestexcept(FE_DIVBYZERO | FE_OVERFLOW | FE_UNDERFLOW)
                    || (phase == 2 && fetestexcept(FE_ALL_EXCEPT))) return 84;
                for (int lane = 0; lane < LANES; ++lane)
                    if (!rounding_matches(bits(output[lane]), expected[lane])) return 85;
            }
        }
    }
    for (int lane = 0; lane < LANES; ++lane)
        input[lane] = lane % 2 ? -1.5f : 2.5f;
    store(output, nearest_keep_source(load(input)));
    for (int lane = 0; lane < LANES; ++lane)
        if (bits(output[lane]) != bits(lane % 2 ? -3.5f : 4.5f)) return 86;
    return 0;
}
