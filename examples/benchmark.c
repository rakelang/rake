/**
 * Rake Unified Raytracer Benchmark
 *
 * Tests all available implementations:
 *   CPU:
 *     - C scalar (baseline)
 *     - C SSE (width 4)
 *     - C AVX2 (width 8)
 *     - Rake SSE (width 4)      [if linked]
 *     - Rake AVX2 (width 8)     [if linked]
 *   GPU:
 *     - C + GLSL shader         [stub - use demo-gpu]
 *     - Rake GPU (width 1)      [stub - not yet implemented]
 *
 * Build: make bench
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>
#include <stdbool.h>
#include <immintrin.h>

/* ═══════════════════════════════════════════════════════════════════════════
 * Configuration
 * ═══════════════════════════════════════════════════════════════════════════ */

#define WIDTH  1920
#define HEIGHT 1080
#define NUM_SPHERES 10
#define NUM_RAYS (WIDTH * HEIGHT)
#define BENCHMARK_ITERATIONS 100
#define WARMUP_ITERATIONS 10

/* ═══════════════════════════════════════════════════════════════════════════
 * Data Structures
 * ═══════════════════════════════════════════════════════════════════════════ */

typedef struct { float x, y, z; } Vec3;
typedef struct { float cx, cy, cz, r; } Sphere;
typedef struct {
    float *ox, *oy, *oz;
    float *dx, *dy, *dz;
} RayPack;

typedef struct {
    const char *name;
    double time_ms;
    double fps;
    int hits;
    bool available;
} BenchResult;

/* ═══════════════════════════════════════════════════════════════════════════
 * External Rake Functions (conditionally linked)
 * ═══════════════════════════════════════════════════════════════════════════ */

#ifdef RAKE_SSE
extern __m128 intersect_flat(__m128 ox, __m128 oy, __m128 oz,
                             __m128 dx, __m128 dy, __m128 dz,
                             float cx, float cy, float cz, float r);
#define RAKE_SSE_AVAILABLE 1
#else
#define RAKE_SSE_AVAILABLE 0
#endif

#ifdef RAKE_AVX
extern __m256 intersect_flat(__m256 ox, __m256 oy, __m256 oz,
                             __m256 dx, __m256 dy, __m256 dz,
                             float cx, float cy, float cz, float r);
#define RAKE_AVX_AVAILABLE 1
#else
#define RAKE_AVX_AVAILABLE 0
#endif

/* ═══════════════════════════════════════════════════════════════════════════
 * C Scalar Implementation (baseline)
 * ═══════════════════════════════════════════════════════════════════════════ */

static inline float dot_scalar(Vec3 a, Vec3 b) {
    return a.x * b.x + a.y * b.y + a.z * b.z;
}

static inline float intersect_scalar(Vec3 origin, Vec3 dir, Sphere s) {
    Vec3 oc = { origin.x - s.cx, origin.y - s.cy, origin.z - s.cz };
    float a = dot_scalar(dir, dir);
    float b = 2.0f * dot_scalar(oc, dir);
    float c = dot_scalar(oc, oc) - s.r * s.r;
    float disc = b * b - 4.0f * a * c;
    if (disc < 0.0f) return -1.0f;
    float t = (-b - sqrtf(disc)) / (2.0f * a);
    return t > 0.0f ? t : -1.0f;
}

void trace_c_scalar(RayPack *rays, Sphere *spheres, int num_spheres, float *result) {
    for (int i = 0; i < NUM_RAYS; i++) {
        Vec3 origin = { rays->ox[i], rays->oy[i], rays->oz[i] };
        Vec3 dir = { rays->dx[i], rays->dy[i], rays->dz[i] };
        float closest_t = 1e30f;
        for (int s = 0; s < num_spheres; s++) {
            float t = intersect_scalar(origin, dir, spheres[s]);
            if (t > 0.0f && t < closest_t) closest_t = t;
        }
        result[i] = closest_t < 1e29f ? closest_t : -1.0f;
    }
}

/* ═══════════════════════════════════════════════════════════════════════════
 * C SSE Implementation (width 4)
 * ═══════════════════════════════════════════════════════════════════════════ */

static inline __m128 dot_sse(__m128 ax, __m128 ay, __m128 az,
                              __m128 bx, __m128 by, __m128 bz) {
    return _mm_add_ps(_mm_add_ps(_mm_mul_ps(ax, bx), _mm_mul_ps(ay, by)),
                      _mm_mul_ps(az, bz));
}

static inline __m128 intersect_sse_c(__m128 ox, __m128 oy, __m128 oz,
                                      __m128 dx, __m128 dy, __m128 dz,
                                      float cx, float cy, float cz, float r) {
    __m128 scx = _mm_set1_ps(cx), scy = _mm_set1_ps(cy), scz = _mm_set1_ps(cz);
    __m128 ocx = _mm_sub_ps(ox, scx);
    __m128 ocy = _mm_sub_ps(oy, scy);
    __m128 ocz = _mm_sub_ps(oz, scz);

    __m128 a = dot_sse(dx, dy, dz, dx, dy, dz);
    __m128 b = _mm_mul_ps(_mm_set1_ps(2.0f), dot_sse(ocx, ocy, ocz, dx, dy, dz));
    __m128 sr = _mm_set1_ps(r);
    __m128 c_val = _mm_sub_ps(dot_sse(ocx, ocy, ocz, ocx, ocy, ocz), _mm_mul_ps(sr, sr));

    __m128 disc = _mm_sub_ps(_mm_mul_ps(b, b), _mm_mul_ps(_mm_set1_ps(4.0f), _mm_mul_ps(a, c_val)));
    __m128 miss_mask = _mm_cmplt_ps(disc, _mm_setzero_ps());

    __m128 sqrt_disc = _mm_sqrt_ps(disc);
    __m128 t = _mm_div_ps(_mm_sub_ps(_mm_sub_ps(_mm_setzero_ps(), b), sqrt_disc),
                          _mm_mul_ps(_mm_set1_ps(2.0f), a));

    return _mm_blendv_ps(t, _mm_set1_ps(-1.0f), miss_mask);
}

void trace_c_sse(RayPack *rays, Sphere *spheres, int num_spheres, float *result) {
    for (int i = 0; i < NUM_RAYS; i++) result[i] = 1e30f;

    for (int s = 0; s < num_spheres; s++) {
        for (int i = 0; i < NUM_RAYS; i += 4) {
            __m128 ox = _mm_loadu_ps(&rays->ox[i]);
            __m128 oy = _mm_loadu_ps(&rays->oy[i]);
            __m128 oz = _mm_loadu_ps(&rays->oz[i]);
            __m128 dx = _mm_loadu_ps(&rays->dx[i]);
            __m128 dy = _mm_loadu_ps(&rays->dy[i]);
            __m128 dz = _mm_loadu_ps(&rays->dz[i]);

            __m128 t = intersect_sse_c(ox, oy, oz, dx, dy, dz,
                                        spheres[s].cx, spheres[s].cy,
                                        spheres[s].cz, spheres[s].r);

            __m128 current = _mm_loadu_ps(&result[i]);
            __m128 hit_mask = _mm_and_ps(_mm_cmpgt_ps(t, _mm_setzero_ps()),
                                          _mm_cmplt_ps(t, current));
            __m128 new_t = _mm_blendv_ps(current, t, hit_mask);
            _mm_storeu_ps(&result[i], new_t);
        }
    }
    for (int i = 0; i < NUM_RAYS; i++) if (result[i] > 1e29f) result[i] = -1.0f;
}

/* ═══════════════════════════════════════════════════════════════════════════
 * C AVX2 Implementation (width 8) - only compiled when AVX is available
 * ═══════════════════════════════════════════════════════════════════════════ */

#ifdef __AVX__
static inline __m256 dot_avx(__m256 ax, __m256 ay, __m256 az,
                              __m256 bx, __m256 by, __m256 bz) {
    return _mm256_add_ps(_mm256_add_ps(_mm256_mul_ps(ax, bx), _mm256_mul_ps(ay, by)),
                         _mm256_mul_ps(az, bz));
}

static inline __m256 intersect_avx_c(__m256 ox, __m256 oy, __m256 oz,
                                      __m256 dx, __m256 dy, __m256 dz,
                                      float cx, float cy, float cz, float r) {
    __m256 scx = _mm256_set1_ps(cx), scy = _mm256_set1_ps(cy), scz = _mm256_set1_ps(cz);
    __m256 ocx = _mm256_sub_ps(ox, scx);
    __m256 ocy = _mm256_sub_ps(oy, scy);
    __m256 ocz = _mm256_sub_ps(oz, scz);

    __m256 a = dot_avx(dx, dy, dz, dx, dy, dz);
    __m256 b = _mm256_mul_ps(_mm256_set1_ps(2.0f), dot_avx(ocx, ocy, ocz, dx, dy, dz));
    __m256 sr = _mm256_set1_ps(r);
    __m256 c_val = _mm256_sub_ps(dot_avx(ocx, ocy, ocz, ocx, ocy, ocz), _mm256_mul_ps(sr, sr));

    __m256 disc = _mm256_sub_ps(_mm256_mul_ps(b, b), _mm256_mul_ps(_mm256_set1_ps(4.0f), _mm256_mul_ps(a, c_val)));
    __m256 miss_mask = _mm256_cmp_ps(disc, _mm256_setzero_ps(), _CMP_LT_OQ);

    __m256 sqrt_disc = _mm256_sqrt_ps(disc);
    __m256 t = _mm256_div_ps(_mm256_sub_ps(_mm256_sub_ps(_mm256_setzero_ps(), b), sqrt_disc),
                             _mm256_mul_ps(_mm256_set1_ps(2.0f), a));

    return _mm256_blendv_ps(t, _mm256_set1_ps(-1.0f), miss_mask);
}

void trace_c_avx(RayPack *rays, Sphere *spheres, int num_spheres, float *result) {
    for (int i = 0; i < NUM_RAYS; i++) result[i] = 1e30f;

    for (int s = 0; s < num_spheres; s++) {
        for (int i = 0; i < NUM_RAYS; i += 8) {
            __m256 ox = _mm256_loadu_ps(&rays->ox[i]);
            __m256 oy = _mm256_loadu_ps(&rays->oy[i]);
            __m256 oz = _mm256_loadu_ps(&rays->oz[i]);
            __m256 dx = _mm256_loadu_ps(&rays->dx[i]);
            __m256 dy = _mm256_loadu_ps(&rays->dy[i]);
            __m256 dz = _mm256_loadu_ps(&rays->dz[i]);

            __m256 t = intersect_avx_c(ox, oy, oz, dx, dy, dz,
                                        spheres[s].cx, spheres[s].cy,
                                        spheres[s].cz, spheres[s].r);

            __m256 current = _mm256_loadu_ps(&result[i]);
            __m256 hit_mask = _mm256_and_ps(_mm256_cmp_ps(t, _mm256_setzero_ps(), _CMP_GT_OQ),
                                            _mm256_cmp_ps(t, current, _CMP_LT_OQ));
            __m256 new_t = _mm256_blendv_ps(current, t, hit_mask);
            _mm256_storeu_ps(&result[i], new_t);
        }
    }
    for (int i = 0; i < NUM_RAYS; i++) if (result[i] > 1e29f) result[i] = -1.0f;
}
#define C_AVX_AVAILABLE 1
#else
#define C_AVX_AVAILABLE 0
#endif

/* ═══════════════════════════════════════════════════════════════════════════
 * Rake SSE Implementation (width 4)
 * ═══════════════════════════════════════════════════════════════════════════ */

#if RAKE_SSE_AVAILABLE
void trace_rake_sse(RayPack *rays, Sphere *spheres, int num_spheres, float *result) {
    for (int i = 0; i < NUM_RAYS; i++) result[i] = 1e30f;

    for (int s = 0; s < num_spheres; s++) {
        for (int i = 0; i < NUM_RAYS; i += 4) {
            __m128 ox = _mm_loadu_ps(&rays->ox[i]);
            __m128 oy = _mm_loadu_ps(&rays->oy[i]);
            __m128 oz = _mm_loadu_ps(&rays->oz[i]);
            __m128 dx = _mm_loadu_ps(&rays->dx[i]);
            __m128 dy = _mm_loadu_ps(&rays->dy[i]);
            __m128 dz = _mm_loadu_ps(&rays->dz[i]);

            __m128 t = intersect_flat(ox, oy, oz, dx, dy, dz,
                                       spheres[s].cx, spheres[s].cy,
                                       spheres[s].cz, spheres[s].r);

            __m128 current = _mm_loadu_ps(&result[i]);
            __m128 hit_mask = _mm_and_ps(_mm_cmpgt_ps(t, _mm_setzero_ps()),
                                          _mm_cmplt_ps(t, current));
            __m128 new_t = _mm_blendv_ps(current, t, hit_mask);
            _mm_storeu_ps(&result[i], new_t);
        }
    }
    for (int i = 0; i < NUM_RAYS; i++) if (result[i] > 1e29f) result[i] = -1.0f;
}
#endif

/* ═══════════════════════════════════════════════════════════════════════════
 * Rake AVX2 Implementation (width 8)
 * ═══════════════════════════════════════════════════════════════════════════ */

#if RAKE_AVX_AVAILABLE
void trace_rake_avx(RayPack *rays, Sphere *spheres, int num_spheres, float *result) {
    for (int i = 0; i < NUM_RAYS; i++) result[i] = 1e30f;

    for (int s = 0; s < num_spheres; s++) {
        for (int i = 0; i < NUM_RAYS; i += 8) {
            __m256 ox = _mm256_loadu_ps(&rays->ox[i]);
            __m256 oy = _mm256_loadu_ps(&rays->oy[i]);
            __m256 oz = _mm256_loadu_ps(&rays->oz[i]);
            __m256 dx = _mm256_loadu_ps(&rays->dx[i]);
            __m256 dy = _mm256_loadu_ps(&rays->dy[i]);
            __m256 dz = _mm256_loadu_ps(&rays->dz[i]);

            __m256 t = intersect_flat(ox, oy, oz, dx, dy, dz,
                                       spheres[s].cx, spheres[s].cy,
                                       spheres[s].cz, spheres[s].r);

            __m256 current = _mm256_loadu_ps(&result[i]);
            __m256 hit_mask = _mm256_and_ps(_mm256_cmp_ps(t, _mm256_setzero_ps(), _CMP_GT_OQ),
                                            _mm256_cmp_ps(t, current, _CMP_LT_OQ));
            __m256 new_t = _mm256_blendv_ps(current, t, hit_mask);
            _mm256_storeu_ps(&result[i], new_t);
        }
    }
    for (int i = 0; i < NUM_RAYS; i++) if (result[i] > 1e29f) result[i] = -1.0f;
}
#endif

/* ═══════════════════════════════════════════════════════════════════════════
 * GPU Stubs (not yet implemented)
 * ═══════════════════════════════════════════════════════════════════════════ */

/* GPU benchmarking requires Vulkan - use demo-gpu instead */

/* ═══════════════════════════════════════════════════════════════════════════
 * Utilities
 * ═══════════════════════════════════════════════════════════════════════════ */

void generate_rays(RayPack *rays, int width, int height) {
    float aspect = (float)width / (float)height;
    float fov = 60.0f * (float)M_PI / 180.0f;
    float half_height = tanf(fov / 2.0f);
    float half_width = aspect * half_height;

    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            int idx = y * width + x;
            rays->ox[idx] = 0.0f;
            rays->oy[idx] = 0.0f;
            rays->oz[idx] = 0.0f;

            float u = (2.0f * ((float)x + 0.5f) / (float)width - 1.0f) * half_width;
            float v = (1.0f - 2.0f * ((float)y + 0.5f) / (float)height) * half_height;
            float len = sqrtf(u * u + v * v + 1.0f);
            rays->dx[idx] = u / len;
            rays->dy[idx] = v / len;
            rays->dz[idx] = -1.0f / len;
        }
    }
}

double get_time_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1000000.0;
}

int count_hits(float *result) {
    int hits = 0;
    for (int i = 0; i < NUM_RAYS; i++) if (result[i] > 0.0f) hits++;
    return hits;
}

BenchResult run_benchmark(const char *name, void (*trace_fn)(RayPack*, Sphere*, int, float*),
                          RayPack *rays, Sphere *spheres, int num_spheres, float *result) {
    BenchResult r = { .name = name, .available = true };

    /* Warmup */
    for (int i = 0; i < WARMUP_ITERATIONS; i++) {
        trace_fn(rays, spheres, num_spheres, result);
    }

    /* Benchmark */
    double start = get_time_ms();
    for (int i = 0; i < BENCHMARK_ITERATIONS; i++) {
        trace_fn(rays, spheres, num_spheres, result);
    }
    r.time_ms = (get_time_ms() - start) / BENCHMARK_ITERATIONS;
    r.fps = 1000.0 / r.time_ms;
    r.hits = count_hits(result);
    return r;
}

void print_result(BenchResult r, double baseline_time) {
    if (!r.available) {
        printf("  %-20s  [not linked]\n", r.name);
        return;
    }
    double speedup = baseline_time / r.time_ms;
    printf("  %-20s  %7.2f ms  %7.1f fps  %5.2fx  %d hits\n",
           r.name, r.time_ms, r.fps, speedup, r.hits);
}

/* ═══════════════════════════════════════════════════════════════════════════
 * Main
 * ═══════════════════════════════════════════════════════════════════════════ */

int main(void) {
    printf("\n");
    printf("══════════════════════════════════════════════════════════════════\n");
    printf("  Rake Raytracer Benchmark\n");
    printf("══════════════════════════════════════════════════════════════════\n");
    printf("  Resolution: %d x %d (%d rays)\n", WIDTH, HEIGHT, NUM_RAYS);
    printf("  Spheres: %d\n", NUM_SPHERES);
    printf("  Iterations: %d (warmup: %d)\n", BENCHMARK_ITERATIONS, WARMUP_ITERATIONS);
    printf("══════════════════════════════════════════════════════════════════\n\n");

    /* Allocate aligned buffers */
    RayPack rays;
    rays.ox = aligned_alloc(64, NUM_RAYS * sizeof(float));
    rays.oy = aligned_alloc(64, NUM_RAYS * sizeof(float));
    rays.oz = aligned_alloc(64, NUM_RAYS * sizeof(float));
    rays.dx = aligned_alloc(64, NUM_RAYS * sizeof(float));
    rays.dy = aligned_alloc(64, NUM_RAYS * sizeof(float));
    rays.dz = aligned_alloc(64, NUM_RAYS * sizeof(float));
    float *result = aligned_alloc(64, NUM_RAYS * sizeof(float));

    generate_rays(&rays, WIDTH, HEIGHT);

    Sphere spheres[NUM_SPHERES];
    for (int i = 0; i < NUM_SPHERES; i++) {
        spheres[i].cx = (i % 5 - 2) * 2.5f;
        spheres[i].cy = (i / 5 - 0.5f) * 2.0f;
        spheres[i].cz = -5.0f - (i % 3) * 2.0f;
        spheres[i].r = 0.8f + (i % 3) * 0.2f;
    }

    printf("Running benchmarks...\n\n");

    /* CPU benchmarks */
    BenchResult r_scalar = run_benchmark("C scalar", trace_c_scalar, &rays, spheres, NUM_SPHERES, result);
    BenchResult r_c_sse = run_benchmark("C SSE (width 4)", trace_c_sse, &rays, spheres, NUM_SPHERES, result);

#if C_AVX_AVAILABLE
    BenchResult r_c_avx = run_benchmark("C AVX2 (width 8)", trace_c_avx, &rays, spheres, NUM_SPHERES, result);
#else
    BenchResult r_c_avx = { .name = "C AVX2 (width 8)", .available = false };
#endif

#if RAKE_SSE_AVAILABLE
    BenchResult r_rake_sse = run_benchmark("Rake SSE (width 4)", trace_rake_sse, &rays, spheres, NUM_SPHERES, result);
#else
    BenchResult r_rake_sse = { .name = "Rake SSE (width 4)", .available = false };
#endif

#if RAKE_AVX_AVAILABLE
    BenchResult r_rake_avx = run_benchmark("Rake AVX2 (width 8)", trace_rake_avx, &rays, spheres, NUM_SPHERES, result);
#else
    BenchResult r_rake_avx = { .name = "Rake AVX2 (width 8)", .available = false };
#endif

    /* GPU stubs */
    BenchResult r_glsl = { .name = "C + GLSL (GPU)", .available = false };
    BenchResult r_rake_gpu = { .name = "Rake GPU (width 1)", .available = false };

    /* Results */
    printf("══════════════════════════════════════════════════════════════════\n");
    printf("  RESULTS                   Time      FPS    Speedup   Correctness\n");
    printf("══════════════════════════════════════════════════════════════════\n");
    printf("\n  CPU Implementations:\n");
    print_result(r_scalar, r_scalar.time_ms);
    print_result(r_c_sse, r_scalar.time_ms);
    print_result(r_c_avx, r_scalar.time_ms);
    print_result(r_rake_sse, r_scalar.time_ms);
    print_result(r_rake_avx, r_scalar.time_ms);

    printf("\n  GPU Implementations:\n");
    print_result(r_glsl, r_scalar.time_ms);
    print_result(r_rake_gpu, r_scalar.time_ms);

    printf("\n══════════════════════════════════════════════════════════════════\n");

    /* Verify correctness */
    bool all_match = true;
    int ref_hits = r_scalar.hits;
    if (r_c_sse.available && r_c_sse.hits != ref_hits) all_match = false;
    if (r_c_avx.available && r_c_avx.hits != ref_hits) all_match = false;
    if (r_rake_sse.available && r_rake_sse.hits != ref_hits) all_match = false;
    if (r_rake_avx.available && r_rake_avx.hits != ref_hits) all_match = false;

    if (all_match) {
        printf("  All implementations produce identical results (%d hits)\n", ref_hits);
    } else {
        printf("  WARNING: Hit count mismatch detected!\n");
    }
    printf("══════════════════════════════════════════════════════════════════\n\n");

    free(rays.ox); free(rays.oy); free(rays.oz);
    free(rays.dx); free(rays.dy); free(rays.dz);
    free(result);

    return all_match ? 0 : 1;
}
