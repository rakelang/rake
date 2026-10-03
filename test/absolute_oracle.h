/* Independently specified binary32 magnitudes. The including C harness owns
   rack's platform ABI, LANES, load/store, bits and the floating environment. */
extern rack absolute_value(rack);
extern rack masked_absolute(rack, rack);

static int check_absolute_values(void)
{
    const struct { uint32_t input, magnitude; } cases[] = {
        {0x00000000u, 0x00000000u}, {0x80000000u, 0x00000000u},
        {0x00000001u, 0x00000001u}, {0x80000001u, 0x00000001u},
        {0x3f800000u, 0x3f800000u}, {0xbf800000u, 0x3f800000u},
        {0x7f7fffffu, 0x7f7fffffu}, {0xff7fffffu, 0x7f7fffffu},
        {0x7f800000u, 0x7f800000u}, {0xff800000u, 0x7f800000u},
        {0x7fc12345u, 0x7fc12345u}, {0xffc12345u, 0x7fc12345u},
        {0x7f812345u, 0x7f812345u}, {0xff812345u, 0x7f812345u}
    };
    const size_t count = sizeof(cases) / sizeof(cases[0]);
    float values[LANES], selectors[LANES], actual[LANES];
    for (size_t first = 0; first < count; ++first) {
        for (int lane = 0; lane < LANES; ++lane)
            memcpy(&values[lane], &cases[(first + lane) % count].input, sizeof(float));
        feclearexcept(FE_ALL_EXCEPT);
        store(actual, absolute_value(load(values)));
        if (fetestexcept(FE_ALL_EXCEPT)) return 72;
        for (int lane = 0; lane < LANES; ++lane)
            if (bits(actual[lane]) != cases[(first + lane) % count].magnitude) return 73;
        for (int phase = 0; phase < 2; ++phase) {
            for (int lane = 0; lane < LANES; ++lane)
                selectors[lane] = (lane + phase) % 2 ? -1.0f : 1.0f;
            feclearexcept(FE_ALL_EXCEPT);
            store(actual, masked_absolute(load(selectors), load(values)));
            if (fetestexcept(FE_ALL_EXCEPT)) return 74;
            for (int lane = 0; lane < LANES; ++lane) {
                const uint32_t expected = (lane + phase) % 2
                    ? 0xc0000000u : cases[(first + lane) % count].magnitude;
                if (bits(actual[lane]) != expected) return 75;
            }
        }
    }
    return 0;
}
