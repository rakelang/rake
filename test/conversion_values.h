/* Binary32 and two's-complement oracles use integer arithmetic, independent
   of SIMD conversions and the host's floating-point conversion instructions. */
static uint32_t expected_unsigned_to_float(uint32_t magnitude)
{
    if (!magnitude) return 0;
    unsigned exponent = 0;
    for (uint32_t rest = magnitude; rest > 1; rest >>= 1) ++exponent;
    uint32_t significand;
    if (exponent <= 23) significand = magnitude << (23 - exponent);
    else {
        const unsigned shift = exponent - 23;
        significand = magnitude >> shift;
        const uint32_t discarded = magnitude & ((1u << shift) - 1);
        const uint32_t halfway = 1u << (shift - 1);
        significand += discarded > halfway || (discarded == halfway && (significand & 1));
        if (significand == 0x1000000u) { significand >>= 1; ++exponent; }
    }
    return ((exponent + 127) << 23) | (significand & 0x7fffffu);
}

static uint32_t expected_signed_to_float(uint32_t word)
{
    const uint32_t sign = word & 0x80000000u;
    return sign | expected_unsigned_to_float(sign ? 0u - word : word);
}

static uint32_t expected_float_magnitude(uint32_t magnitude)
{
    const int exponent = (int)(magnitude >> 23) - 127;
    if (exponent < -1) return 0;
    if (exponent == -1) return magnitude > 0x3f000000u;
    const uint32_t significand = (magnitude & 0x7fffffu) | 0x800000u;
    uint32_t value;
    if (exponent >= 23) value = significand << (exponent - 23);
    else {
        const unsigned shift = 23 - exponent;
        value = significand >> shift;
        const uint32_t discarded = significand & ((1u << shift) - 1);
        const uint32_t halfway = 1u << (shift - 1);
        value += discarded > halfway || (discarded == halfway && (value & 1));
    }
    return value;
}

static uint32_t expected_float_to_signed(uint32_t bits)
{
    const uint32_t sign = bits & 0x80000000u, magnitude = bits & 0x7fffffffu;
    if (magnitude > 0x7f800000u) return 0;
    if (magnitude >= 0x4f000000u) return sign ? 0x80000000u : 0x7fffffffu;
    const uint32_t value = expected_float_magnitude(magnitude);
    return sign ? 0u - value : value;
}

static uint32_t expected_float_to_unsigned(uint32_t bits)
{
    const uint32_t magnitude = bits & 0x7fffffffu;
    if (magnitude > 0x7f800000u || (bits & 0x80000000u)) return 0;
    if (magnitude >= 0x4f800000u) return 0xffffffffu;
    return expected_float_magnitude(magnitude);
}
