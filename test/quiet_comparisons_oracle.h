/* Independent IEEE ordered predicates check values and floating exceptions
   across every physical rack width. The including harness supplies its ABI's
   rack type, LANES, load/store and bits. */
extern rack quiet_less(rack, rack);
extern rack quiet_less_equal(rack, rack);
extern rack quiet_greater(rack, rack);
extern rack quiet_greater_equal(rack, rack);
extern rack quiet_equal(rack, rack);
extern rack quiet_different(rack, rack);

static int check_quiet_comparisons(void)
{
    const float inputs[] = {-INFINITY, -1, -0.0f, 0.0f, 1, INFINITY, NAN};
    rack (*comparisons[])(rack, rack) = {quiet_less, quiet_less_equal,
        quiet_greater, quiet_greater_equal, quiet_equal, quiet_different};
    float left[LANES], right[LANES], actual[LANES], expected[LANES];
    for (int operation = 0; operation < 6; ++operation) {
        for (int pair = 0; pair < 49; ++pair) {
            for (int lane = 0; lane < LANES; ++lane) {
                const int offset = (pair + lane) % 49;
                const float a = left[lane] = inputs[offset / 7];
                const float b = right[lane] = inputs[offset % 7];
                expected[lane] = !isnan(a) && !isnan(b)
                    && (operation == 0 ? a < b : operation == 1 ? a <= b
                        : operation == 2 ? a > b : operation == 3 ? a >= b
                        : operation == 4 ? a == b : a != b) ? 1 : 0;
            }
            feclearexcept(FE_ALL_EXCEPT);
            store(actual, comparisons[operation](load(left), load(right)));
            if (fetestexcept(FE_INVALID)) return 60 + operation;
            for (int lane = 0; lane < LANES; ++lane)
                if (bits(actual[lane]) != bits(expected[lane])) return 66 + operation;
        }
    }
    return 0;
}
