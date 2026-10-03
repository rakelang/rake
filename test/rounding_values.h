/* Binary32 rounding oracle using only integer significand/exponent arithmetic.
   It neither calls libm nor duplicates the selected vector-conversion path. */
enum rounding_mode { ROUND_FLOOR, ROUND_CEIL, ROUND_TRUNC, ROUND_NEAREST };

static const uint32_t rounding_inputs[] = {
    0x00000000u, 0x80000000u, 0x00000001u, 0x80000001u,
    0x007fffffu, 0x807fffffu, 0x00800000u, 0x80800000u,
    0x3effffffu, 0xbeffffffu, 0x3f000000u, 0xbf000000u,
    0x3f000001u, 0xbf000001u, 0x3f7fffffu, 0xbf7fffffu,
    0x3f800000u, 0xbf800000u, 0x3fbfffffu, 0xbfbfffffu,
    0x3fc00000u, 0xbfc00000u, 0x3fc00001u, 0xbfc00001u,
    0x40200000u, 0xc0200000u, 0x40600000u, 0xc0600000u,
    0x4affffffu, 0xcaffffffu, 0x4b000000u, 0xcb000000u,
    0x7f7fffffu, 0xff7fffffu, 0x7f800000u, 0xff800000u,
    0x7fc12345u, 0xffc12345u, 0x7f812345u, 0xff812345u
};

static int rounding_signaling(uint32_t input)
{
    return (input & 0x7fffffffu) > 0x7f800000u && !(input & 0x00400000u);
}

static uint32_t rounding_expected(uint32_t input, enum rounding_mode mode)
{
    const uint32_t sign = input & 0x80000000u, magnitude = input & 0x7fffffffu;
    if (magnitude > 0x7f800000u) return input | 0x00400000u;
    const int exponent = (int)(magnitude >> 23) - 127;
    if (exponent >= 23 || magnitude == 0) return input;
    if (exponent < 0) {
        const int one = (mode == ROUND_FLOOR && sign)
            || (mode == ROUND_CEIL && !sign)
            || (mode == ROUND_NEAREST && magnitude > 0x3f000000u);
        return sign | (one ? 0x3f800000u : 0);
    }
    const uint32_t unit = 1u << (23 - exponent), mask = unit - 1;
    const uint32_t fraction = magnitude & mask, integral = magnitude & ~mask;
    const int increment = fraction && ((mode == ROUND_FLOOR && sign)
        || (mode == ROUND_CEIL && !sign)
        || (mode == ROUND_NEAREST && (fraction > unit / 2
            || (fraction == unit / 2 && (integral & unit)))));
    return sign | (integral + (increment ? unit : 0));
}

static int rounding_matches(uint32_t actual, uint32_t expected)
{
    return (expected & 0x7fffffffu) > 0x7f800000u
        ? (actual & 0x7fffffffu) > 0x7f800000u && (actual & 0x00400000u)
        : actual == expected;
}
