/* A volatile scalar left fold checks the packed fold's rounding order.
   Extrema use the independent integer binary32 ordering oracle above. */
extern float strict_reduce_add(rack);
extern float strict_reduce_mul(rack);
extern float strict_reduce_min(rack);
extern float strict_reduce_max(rack);
extern rack strict_scan_add(rack);
extern rack strict_scan_mul(rack);
extern rack strict_scan_min(rack);
extern rack strict_scan_max(rack);
extern rack scan_keep_source(rack);

static int check_reductions_and_scans(void)
{
    float (*const reductions[])(rack) = {
        strict_reduce_add, strict_reduce_mul, strict_reduce_min, strict_reduce_max
    };
    rack (*const scans[])(rack) = {
        strict_scan_add, strict_scan_mul, strict_scan_min, strict_scan_max
    };
    const float addition[] = {16777216, 1, -16777216, 1, 2, 3, 4, 5};
    const float multiplication[] = {2, -1, 0, 3, -2, 0.5f, 1, -4};
    const uint32_t extrema[] = {
        0x00000000u, 0x80000000u, 0x00000001u, 0x80000001u,
        0x3f800000u, 0xbf800000u, 0x7f800000u, 0xff800000u
    };
    float input[LANES], output[LANES];
    uint32_t expected[LANES];
    for (int operation = 0; operation < 4; ++operation) {
        /* Include every position for both quiet and signalling NaNs. */
        for (int scenario = 0; scenario < 3 + 2 * LANES; ++scenario) {
            for (int lane = 0; lane < LANES; ++lane) {
                input[lane] = operation == 0 ? addition[lane % 8] : multiplication[lane % 8];
                if (operation >= 2) {
                    const uint32_t value = scenario == 1 ? (lane % 2 ? 0x80000000u : 0)
                        : scenario == 2 ? (lane % 2 ? 0 : 0x80000000u) : extrema[lane % 8];
                    memcpy(&input[lane], &value, sizeof(float));
                }
            }
            if (scenario >= 3) {
                const uint32_t nan = (scenario - 3) / LANES ? 0xff812345u : 0x7fc12345u;
                memcpy(&input[(scenario - 3) % LANES], &nan, sizeof(float));
            }
            expected[0] = bits(input[0]);
            volatile float prefix = input[0];
            for (int lane = 1; lane < LANES; ++lane) {
                if (operation < 2) {
                    prefix = operation == 0 ? prefix + input[lane] : prefix * input[lane];
                    expected[lane] = bits(prefix);
                } else {
                    expected[lane] = extrema_expected(expected[lane - 1], bits(input[lane]), operation == 3);
                }
            }
            feclearexcept(FE_ALL_EXCEPT);
            const float reduced = reductions[operation](load(input));
            store(output, scans[operation](load(input)));
            if (operation >= 2 && (!!fetestexcept(FE_INVALID) != (scenario >= 3 + LANES)
                || fetestexcept(FE_DIVBYZERO | FE_OVERFLOW | FE_UNDERFLOW | FE_INEXACT))) return 87;
            for (int lane = 0; lane <= LANES; ++lane) {
                const uint32_t actual = bits(lane == LANES ? reduced : output[lane]);
                const uint32_t wanted = expected[lane == LANES ? LANES - 1 : lane];
                if (operation >= 2 ? actual != wanted
                    : extrema_nan(wanted) ? !extrema_nan(actual) : actual != wanted) return 88;
            }
        }
    }
    for (int lane = 0; lane < LANES; ++lane) input[lane] = (float)(lane + 1);
    store(output, scan_keep_source(load(input)));
    float sum = 0;
    for (int lane = 0; lane < LANES; ++lane) {
        sum += input[lane];
        if (bits(output[lane]) != bits(sum + input[lane])) return 89;
    }
    return 0;
}
