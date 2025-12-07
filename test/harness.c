/**
 * Rake Test Harness
 *
 * C test harness for linking with compiled Rake functions.
 * Tests the compute_distances function which calculates Euclidean distance
 * from each point to a center point.
 */

#include <stdio.h>
#include <math.h>
#include <stdlib.h>

// Declare Rake functions (will be linked from compiled .o)
extern void compute_distances(float* ox, float* oy, float* oz,
                              float cx, float cy, float cz,
                              long count, float* out);

// Simple tolerance check for floating point comparison
#define TOLERANCE 0.001f

int test_basic_distances(void) {
    printf("Test: basic_distances\n");

    float ox[] = {1, 2, 3, 4, 5, 6, 7, 8};
    float oy[] = {0, 0, 0, 0, 0, 0, 0, 0};
    float oz[] = {0, 0, 0, 0, 0, 0, 0, 0};
    float out[8];

    compute_distances(ox, oy, oz, 0, 0, 0, 8, out);

    for (int i = 0; i < 8; i++) {
        float expected = sqrtf(ox[i]*ox[i]);
        if (fabsf(out[i] - expected) > TOLERANCE) {
            printf("  FAIL: out[%d] = %f, expected %f\n", i, out[i], expected);
            return 1;
        }
    }
    printf("  PASS\n");
    return 0;
}

int test_3d_distances(void) {
    printf("Test: 3d_distances\n");

    // Points at various 3D positions
    float ox[] = {1, 0, 0, 1, 1, 0, 1, 2};
    float oy[] = {0, 1, 0, 1, 0, 1, 1, 2};
    float oz[] = {0, 0, 1, 0, 1, 1, 1, 2};
    float out[8];

    compute_distances(ox, oy, oz, 0, 0, 0, 8, out);

    float expected[] = {
        1.0f,                    // (1,0,0) -> 1
        1.0f,                    // (0,1,0) -> 1
        1.0f,                    // (0,0,1) -> 1
        sqrtf(2.0f),             // (1,1,0) -> sqrt(2)
        sqrtf(2.0f),             // (1,0,1) -> sqrt(2)
        sqrtf(2.0f),             // (0,1,1) -> sqrt(2)
        sqrtf(3.0f),             // (1,1,1) -> sqrt(3)
        sqrtf(12.0f)             // (2,2,2) -> sqrt(12)
    };

    for (int i = 0; i < 8; i++) {
        if (fabsf(out[i] - expected[i]) > TOLERANCE) {
            printf("  FAIL: out[%d] = %f, expected %f\n", i, out[i], expected[i]);
            return 1;
        }
    }
    printf("  PASS\n");
    return 0;
}

int test_offset_center(void) {
    printf("Test: offset_center\n");

    // Test with non-zero center point
    float ox[] = {5, 6, 7, 8, 9, 10, 11, 12};
    float oy[] = {5, 5, 5, 5, 5, 5, 5, 5};
    float oz[] = {5, 5, 5, 5, 5, 5, 5, 5};
    float out[8];

    // Center at (5, 5, 5)
    compute_distances(ox, oy, oz, 5, 5, 5, 8, out);

    for (int i = 0; i < 8; i++) {
        // Distance is just the x offset since y and z match center
        float expected = (float)i;
        if (fabsf(out[i] - expected) > TOLERANCE) {
            printf("  FAIL: out[%d] = %f, expected %f\n", i, out[i], expected);
            return 1;
        }
    }
    printf("  PASS\n");
    return 0;
}

int main(int argc, char** argv) {
    int failures = 0;

    printf("=== Rake Test Harness ===\n\n");

    failures += test_basic_distances();
    failures += test_3d_distances();
    failures += test_offset_center();

    printf("\n=== Results ===\n");
    if (failures == 0) {
        printf("All tests PASSED\n");
        return 0;
    } else {
        printf("%d test(s) FAILED\n", failures);
        return 1;
    }
}
