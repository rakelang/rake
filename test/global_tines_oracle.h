/* An independent C calculation, shared by the physical-profile ABI harnesses.
   Mask gaps include NaNs; overlapping sweep arms keep first-match priority. */
extern rack absolute_root(rack);
extern rack visible_fallback(rack);
extern rack overlapping_partial(rack);
extern rack partitioned_partial(rack);

static int check_global_tines(void) {
    const float cases[8] = {-4.0f, 0.0f, 9.0f, NAN, -0.0f, 16.0f, -9.0f, 1.0f};
    float input[LANES], output[LANES];
    for (int offset = 0; offset < 8; offset += LANES) {
        for (int lane = 0; lane < LANES; ++lane) input[lane] = cases[(offset + lane) % 8];
        store(output, absolute_root(load(input)));
        for (int lane = 0; lane < LANES; ++lane) {
            float x = input[lane];
            float expected = x >= 0.0f ? sqrtf(x) : x < 0.0f ? sqrtf(-x) : 7.0f;
            if (bits(output[lane]) != bits(expected)) return 80;
        }
        store(output, visible_fallback(load(input)));
        for (int lane = 0; lane < LANES; ++lane)
            if (bits(output[lane]) != bits(input[lane] >= 0.0f ? sqrtf(input[lane]) : 9.0f)) return 81;
        store(output, partitioned_partial(load(input)));
        for (int lane = 0; lane < LANES; ++lane)
            if (bits(output[lane]) != bits(input[lane] >= 0.0f ? sqrtf(input[lane]) : 0.0f)) return 83;
        store(output, overlapping_partial(load(input)));
        for (int lane = 0; lane < LANES; ++lane) {
            float x = input[lane];
            float expected = x >= 0.0f ? sqrtf(x) : x <= 4.0f ? 3.0f : 7.0f;
            if (bits(output[lane]) != bits(expected)) return 82;
        }
    }
    return 0;
}
