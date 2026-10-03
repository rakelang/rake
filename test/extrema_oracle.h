/* Independent binary32 ordering, including NaNs and signed zero. Integer
   comparisons keep the oracle from raising the exceptions it measures. */
extern rack smaller(rack, rack);
extern rack larger(rack, rack);
extern rack smaller_same(rack);
extern rack larger_same(rack);
extern rack smaller_keep_left(rack, rack);
extern rack larger_keep_right(rack, rack);
extern rack masked_smaller(rack, rack, rack);
extern rack masked_larger(rack, rack, rack);

static int extrema_nan(uint32_t value)
{
    return (value & 0x7fffffffu) > 0x7f800000u;
}

static int extrema_signaling(uint32_t value)
{
    return extrema_nan(value) && !(value & 0x00400000u);
}

static uint32_t extrema_order(uint32_t value)
{
    return value & 0x80000000u ? ~value : value | 0x80000000u;
}

static uint32_t extrema_expected(uint32_t left, uint32_t right, int maximum)
{
    if (extrema_nan(left) || extrema_nan(right)) return 0x7fc00000u;
    const int lower = extrema_order(left) < extrema_order(right);
    return maximum ? (lower ? right : left) : (lower ? left : right);
}

static int extrema_matches(uint32_t actual, uint32_t expected)
{
    return extrema_nan(expected)
        ? extrema_nan(actual) && (actual & 0x00400000u)
        : actual == expected;
}

static int check_extrema(void)
{
    const uint32_t inputs[] = {
        0x00000000u, 0x80000000u, 0x00000001u, 0x80000001u,
        0x3f800000u, 0xbf800000u, 0x7f7fffffu, 0xff7fffffu,
        0x7f800000u, 0xff800000u, 0x7fc12345u, 0xffc12345u,
        0x7f812345u, 0xff812345u
    };
    const size_t count = sizeof(inputs) / sizeof(inputs[0]);
    float left[LANES], right[LANES], selector[LANES], actual[LANES];
    uint32_t expected[LANES];
    for (int maximum = 0; maximum < 2; ++maximum) {
        for (size_t pair = 0; pair < count * count; ++pair) {
            for (int phase = -1; phase < 2; ++phase) {
                int invalid = 0;
                for (int lane = 0; lane < LANES; ++lane) {
                    const size_t offset = (pair + lane) % (count * count);
                    const uint32_t a = inputs[offset / count], b = inputs[offset % count];
                    memcpy(&left[lane], &a, sizeof(float));
                    memcpy(&right[lane], &b, sizeof(float));
                    const int active = phase < 0 || (lane + phase) % 2 == 0;
                    selector[lane] = active ? 1.0f : -1.0f;
                    expected[lane] = active ? extrema_expected(a, b, maximum) : 0xc0000000u;
                    invalid |= active && (extrema_signaling(a) || extrema_signaling(b));
                }
                feclearexcept(FE_ALL_EXCEPT);
                rack result = phase < 0
                    ? (maximum ? larger(load(left), load(right)) : smaller(load(left), load(right)))
                    : (maximum ? masked_larger(load(selector), load(left), load(right))
                               : masked_smaller(load(selector), load(left), load(right)));
                store(actual, result);
                if (!!fetestexcept(FE_INVALID) != invalid
                    || fetestexcept(FE_DIVBYZERO | FE_OVERFLOW | FE_UNDERFLOW | FE_INEXACT)) return 76;
                for (int lane = 0; lane < LANES; ++lane)
                    if (!extrema_matches(bits(actual[lane]), expected[lane])) return 77;
            }
        }
        for (size_t first = 0; first < count; ++first) {
            int invalid = 0;
            for (int lane = 0; lane < LANES; ++lane) {
                uint32_t input = inputs[(first + lane) % count];
                memcpy(&left[lane], &input, sizeof(float));
                expected[lane] = extrema_expected(input, input, maximum);
                invalid |= extrema_signaling(input);
            }
            feclearexcept(FE_ALL_EXCEPT);
            store(actual, maximum ? larger_same(load(left)) : smaller_same(load(left)));
            if (!!fetestexcept(FE_INVALID) != invalid) return 78;
            for (int lane = 0; lane < LANES; ++lane)
                if (!extrema_matches(bits(actual[lane]), expected[lane])) return 79;
        }
    }
    /* A mask suppresses even signaling NaNs in every inactive lane. */
    for (int lane = 0; lane < LANES; ++lane) {
        uint32_t signaling = 0x7f812345u;
        memcpy(&left[lane], &signaling, sizeof(float));
        memcpy(&right[lane], &signaling, sizeof(float));
        selector[lane] = -1.0f;
    }
    for (int maximum = 0; maximum < 2; ++maximum) {
        feclearexcept(FE_ALL_EXCEPT);
        store(actual, maximum ? masked_larger(load(selector), load(left), load(right))
                              : masked_smaller(load(selector), load(left), load(right)));
        if (fetestexcept(FE_ALL_EXCEPT)) return 80;
        for (int lane = 0; lane < LANES; ++lane)
            if (bits(actual[lane]) != 0xc0000000u) return 81;
    }
    for (int lane = 0; lane < LANES; ++lane) {
        left[lane] = lane % 2 ? -3.0f : 4.0f;
        right[lane] = lane % 2 ? 7.0f : -2.0f;
    }
    store(actual, smaller_keep_left(load(left), load(right)));
    for (int lane = 0; lane < LANES; ++lane)
        if (bits(actual[lane]) != bits(lane % 2 ? -6.0f : 2.0f)) return 82;
    store(actual, larger_keep_right(load(left), load(right)));
    for (int lane = 0; lane < LANES; ++lane)
        if (bits(actual[lane]) != bits(lane % 2 ? 14.0f : 2.0f)) return 83;
    return 0;
}
