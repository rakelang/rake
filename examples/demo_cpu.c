/**
 * Rake Raytracer SDL Demo
 *
 * Visual comparison of C Scalar, C SIMD (AVX2), and Rake SIMD
 * with interactive real-time rendering.
 *
 * Build:
 *   clang -O3 -flto -mavx2 sdl_demo.c raytracer_rake_lto.o -o sdl_demo -lSDL2 -lm
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>
#include <stdbool.h>
#include <immintrin.h>

#include <SDL2/SDL.h>

/* Configuration */
#define WIDTH  800
#define HEIGHT 600
#define NUM_RAYS (WIDTH * HEIGHT)
#define NUM_SPHERES 5

/* Ray pack (SoA layout) */
typedef struct {
    float *ox, *oy, *oz;
    float *dx, *dy, *dz;
} RayPack;

typedef struct {
    float cx, cy, cz, r;
    uint8_t color_r, color_g, color_b;
} Sphere;

/* External Rake functions */
extern __m256 intersect_flat(__m256 ray_ox, __m256 ray_oy, __m256 ray_oz,
                             __m256 ray_dx, __m256 ray_dy, __m256 ray_dz,
                             float sphere_cx, float sphere_cy, float sphere_cz,
                             float sphere_r);

/* C Scalar implementation */
static inline float dot_scalar(float ax, float ay, float az,
                               float bx, float by, float bz) {
    return ax * bx + ay * by + az * bz;
}

float intersect_scalar(float ox, float oy, float oz,
                       float dx, float dy, float dz,
                       float cx, float cy, float cz, float r) {
    float ocx = ox - cx, ocy = oy - cy, ocz = oz - cz;
    float a = dot_scalar(dx, dy, dz, dx, dy, dz);
    float b = 2.0f * dot_scalar(ocx, ocy, ocz, dx, dy, dz);
    float c = dot_scalar(ocx, ocy, ocz, ocx, ocy, ocz) - r * r;
    float disc = b * b - 4.0f * a * c;
    if (disc < 0.0f) return -1.0f;
    float t = (-b - sqrtf(disc)) / (2.0f * a);
    return t > 0.0f ? t : -1.0f;
}

void trace_scalar(RayPack *rays, Sphere *spheres, int num_spheres,
                  float *result, int *sphere_ids) {
    for (int i = 0; i < NUM_RAYS; i++) {
        float closest = 1e30f;
        int closest_id = -1;
        for (int s = 0; s < num_spheres; s++) {
            float t = intersect_scalar(rays->ox[i], rays->oy[i], rays->oz[i],
                                       rays->dx[i], rays->dy[i], rays->dz[i],
                                       spheres[s].cx, spheres[s].cy,
                                       spheres[s].cz, spheres[s].r);
            if (t > 0.0f && t < closest) {
                closest = t;
                closest_id = s;
            }
        }
        result[i] = closest < 1e29f ? closest : -1.0f;
        sphere_ids[i] = closest_id;
    }
}

/* C SIMD implementation */
static inline __m256 dot_simd(__m256 ax, __m256 ay, __m256 az,
                              __m256 bx, __m256 by, __m256 bz) {
    return _mm256_add_ps(_mm256_add_ps(_mm256_mul_ps(ax, bx),
                                        _mm256_mul_ps(ay, by)),
                         _mm256_mul_ps(az, bz));
}

__m256 intersect_simd(__m256 ox, __m256 oy, __m256 oz,
                      __m256 dx, __m256 dy, __m256 dz,
                      float cx, float cy, float cz, float r) {
    __m256 ocx = _mm256_sub_ps(ox, _mm256_set1_ps(cx));
    __m256 ocy = _mm256_sub_ps(oy, _mm256_set1_ps(cy));
    __m256 ocz = _mm256_sub_ps(oz, _mm256_set1_ps(cz));

    __m256 a = dot_simd(dx, dy, dz, dx, dy, dz);
    __m256 b = _mm256_mul_ps(_mm256_set1_ps(2.0f), dot_simd(ocx, ocy, ocz, dx, dy, dz));
    __m256 c = _mm256_sub_ps(dot_simd(ocx, ocy, ocz, ocx, ocy, ocz),
                             _mm256_set1_ps(r * r));

    __m256 disc = _mm256_sub_ps(_mm256_mul_ps(b, b),
                                 _mm256_mul_ps(_mm256_set1_ps(4.0f),
                                               _mm256_mul_ps(a, c)));

    __m256 miss = _mm256_cmp_ps(disc, _mm256_setzero_ps(), _CMP_LT_OQ);
    __m256 sqrt_disc = _mm256_sqrt_ps(disc);
    __m256 t = _mm256_div_ps(_mm256_sub_ps(_mm256_sub_ps(_mm256_setzero_ps(), b),
                                           sqrt_disc),
                             _mm256_mul_ps(_mm256_set1_ps(2.0f), a));

    return _mm256_blendv_ps(t, _mm256_set1_ps(-1.0f), miss);
}

void trace_simd(RayPack *rays, Sphere *spheres, int num_spheres,
                float *result, int *sphere_ids) {
    for (int i = 0; i < NUM_RAYS; i++) {
        result[i] = 1e30f;
        sphere_ids[i] = -1;
    }

    for (int s = 0; s < num_spheres; s++) {
        for (int i = 0; i < NUM_RAYS; i += 8) {
            __m256 ox = _mm256_loadu_ps(&rays->ox[i]);
            __m256 oy = _mm256_loadu_ps(&rays->oy[i]);
            __m256 oz = _mm256_loadu_ps(&rays->oz[i]);
            __m256 dx = _mm256_loadu_ps(&rays->dx[i]);
            __m256 dy = _mm256_loadu_ps(&rays->dy[i]);
            __m256 dz = _mm256_loadu_ps(&rays->dz[i]);

            __m256 t = intersect_simd(ox, oy, oz, dx, dy, dz,
                                      spheres[s].cx, spheres[s].cy,
                                      spheres[s].cz, spheres[s].r);

            __m256 current = _mm256_loadu_ps(&result[i]);
            __m256 closer = _mm256_and_ps(_mm256_cmp_ps(t, _mm256_setzero_ps(), _CMP_GT_OQ),
                                          _mm256_cmp_ps(t, current, _CMP_LT_OQ));

            /* Update results and sphere IDs */
            float t_arr[8], curr_arr[8];
            int closer_mask;
            _mm256_storeu_ps(t_arr, t);
            _mm256_storeu_ps(curr_arr, current);
            closer_mask = _mm256_movemask_ps(closer);

            for (int j = 0; j < 8; j++) {
                if (closer_mask & (1 << j)) {
                    result[i + j] = t_arr[j];
                    sphere_ids[i + j] = s;
                }
            }
        }
    }

    for (int i = 0; i < NUM_RAYS; i++) {
        if (result[i] > 1e29f) {
            result[i] = -1.0f;
            sphere_ids[i] = -1;
        }
    }
}

/* Rake SIMD wrapper */
void trace_rake(RayPack *rays, Sphere *spheres, int num_spheres,
                float *result, int *sphere_ids) {
    for (int i = 0; i < NUM_RAYS; i++) {
        result[i] = 1e30f;
        sphere_ids[i] = -1;
    }

    for (int s = 0; s < num_spheres; s++) {
        for (int i = 0; i < NUM_RAYS; i += 8) {
            __m256 ox = _mm256_loadu_ps(&rays->ox[i]);
            __m256 oy = _mm256_loadu_ps(&rays->oy[i]);
            __m256 oz = _mm256_loadu_ps(&rays->oz[i]);
            __m256 dx = _mm256_loadu_ps(&rays->dx[i]);
            __m256 dy = _mm256_loadu_ps(&rays->dy[i]);
            __m256 dz = _mm256_loadu_ps(&rays->dz[i]);

            /* Use Rake-compiled intersection */
            __m256 t = intersect_flat(ox, oy, oz, dx, dy, dz,
                                      spheres[s].cx, spheres[s].cy,
                                      spheres[s].cz, spheres[s].r);

            __m256 current = _mm256_loadu_ps(&result[i]);
            __m256 closer = _mm256_and_ps(_mm256_cmp_ps(t, _mm256_setzero_ps(), _CMP_GT_OQ),
                                          _mm256_cmp_ps(t, current, _CMP_LT_OQ));

            float t_arr[8], curr_arr[8];
            int closer_mask;
            _mm256_storeu_ps(t_arr, t);
            _mm256_storeu_ps(curr_arr, current);
            closer_mask = _mm256_movemask_ps(closer);

            for (int j = 0; j < 8; j++) {
                if (closer_mask & (1 << j)) {
                    result[i + j] = t_arr[j];
                    sphere_ids[i + j] = s;
                }
            }
        }
    }

    for (int i = 0; i < NUM_RAYS; i++) {
        if (result[i] > 1e29f) {
            result[i] = -1.0f;
            sphere_ids[i] = -1;
        }
    }
}

/* Ray generation */
void generate_rays(RayPack *rays, int width, int height) {
    float aspect = (float)width / (float)height;
    float fov = 60.0f * M_PI / 180.0f;
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

/* Timing */
double get_time_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1000000.0;
}

/* Render to SDL surface */
void render_to_surface(SDL_Surface *surface, float *result, int *sphere_ids,
                       Sphere *spheres, int width, int height) {
    uint32_t *pixels = surface->pixels;

    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            int idx = y * width + x;
            float t = result[idx];
            int sid = sphere_ids[idx];

            uint8_t r, g, b;
            if (t > 0.0f && sid >= 0) {
                /* Use sphere color with depth shading */
                float depth = 1.0f - (t - 3.0f) / 5.0f;
                depth = fmaxf(0.2f, fminf(1.0f, depth));
                r = (uint8_t)(spheres[sid].color_r * depth);
                g = (uint8_t)(spheres[sid].color_g * depth);
                b = (uint8_t)(spheres[sid].color_b * depth);
            } else {
                /* Background gradient */
                float grad = (float)y / height;
                r = (uint8_t)(20 + 30 * grad);
                g = (uint8_t)(25 + 35 * grad);
                b = (uint8_t)(50 + 50 * grad);
            }

            pixels[idx] = SDL_MapRGB(surface->format, r, g, b);
        }
    }
}

/* Draw text (simple bitmap approximation) */
void draw_mode_indicator(SDL_Surface *surface, int mode, double fps) {
    const char *mode_names[] = { "C Scalar", "C SIMD (AVX2)", "Rake SIMD" };
    uint32_t colors[] = { 0xA04040, 0x40A040, 0x4080C0 };

    /* Draw background bar */
    SDL_Rect bar = { 0, 0, WIDTH, 40 };
    SDL_FillRect(surface, &bar, 0x202030);

    /* Draw mode indicator */
    SDL_Rect indicator = { 10, 8, 24, 24 };
    SDL_FillRect(surface, &indicator, colors[mode]);

    (void)fps;
    (void)mode_names;
}

int main(int argc, char *argv[]) {
    (void)argc; (void)argv;

    printf("\n");
    printf("================================================================\n");
    printf("        Rake Raytracer - Interactive SIMD Demo\n");
    printf("================================================================\n\n");

    /* Initialize SDL */
    if (SDL_Init(SDL_INIT_VIDEO) < 0) {
        fprintf(stderr, "SDL init failed: %s\n", SDL_GetError());
        return 1;
    }

    SDL_Window *window = SDL_CreateWindow("Rake Raytracer Demo",
        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
        WIDTH, HEIGHT, SDL_WINDOW_SHOWN);
    if (!window) {
        fprintf(stderr, "Window creation failed: %s\n", SDL_GetError());
        return 1;
    }

    SDL_Surface *surface = SDL_GetWindowSurface(window);

    /* Allocate ray data */
    RayPack rays;
    rays.ox = aligned_alloc(32, NUM_RAYS * sizeof(float));
    rays.oy = aligned_alloc(32, NUM_RAYS * sizeof(float));
    rays.oz = aligned_alloc(32, NUM_RAYS * sizeof(float));
    rays.dx = aligned_alloc(32, NUM_RAYS * sizeof(float));
    rays.dy = aligned_alloc(32, NUM_RAYS * sizeof(float));
    rays.dz = aligned_alloc(32, NUM_RAYS * sizeof(float));
    float *result = aligned_alloc(32, NUM_RAYS * sizeof(float));
    int *sphere_ids = aligned_alloc(32, NUM_RAYS * sizeof(int));

    generate_rays(&rays, WIDTH, HEIGHT);

    /* Setup spheres with colors */
    Sphere spheres[NUM_SPHERES] = {
        { 0.0f,  0.0f, -5.0f, 1.2f,  255, 100, 100 },  /* Red */
        {-2.0f,  1.0f, -6.0f, 0.8f,  100, 255, 100 },  /* Green */
        { 2.0f, -0.5f, -4.5f, 0.7f,  100, 100, 255 },  /* Blue */
        {-1.0f, -1.0f, -4.0f, 0.5f,  255, 255, 100 },  /* Yellow */
        { 1.5f,  1.2f, -7.0f, 1.0f,  255, 100, 255 }   /* Magenta */
    };

    /* Initial benchmark */
    printf("Running initial benchmark...\n");
    const int BENCH_ITERS = 20;

    /* Warmup */
    trace_scalar(&rays, spheres, NUM_SPHERES, result, sphere_ids);
    trace_simd(&rays, spheres, NUM_SPHERES, result, sphere_ids);
    trace_rake(&rays, spheres, NUM_SPHERES, result, sphere_ids);

    double scalar_time, simd_time, rake_time;

    double start = get_time_ms();
    for (int i = 0; i < BENCH_ITERS; i++) {
        trace_scalar(&rays, spheres, NUM_SPHERES, result, sphere_ids);
    }
    scalar_time = (get_time_ms() - start) / BENCH_ITERS;

    start = get_time_ms();
    for (int i = 0; i < BENCH_ITERS; i++) {
        trace_simd(&rays, spheres, NUM_SPHERES, result, sphere_ids);
    }
    simd_time = (get_time_ms() - start) / BENCH_ITERS;

    start = get_time_ms();
    for (int i = 0; i < BENCH_ITERS; i++) {
        trace_rake(&rays, spheres, NUM_SPHERES, result, sphere_ids);
    }
    rake_time = (get_time_ms() - start) / BENCH_ITERS;

    printf("\n");
    printf("================================================================\n");
    printf("  BENCHMARK RESULTS (%dx%d, %d spheres)\n", WIDTH, HEIGHT, NUM_SPHERES);
    printf("================================================================\n");
    printf("  C Scalar:    %6.2f ms  (%5.1f FPS)  baseline\n",
           scalar_time, 1000.0/scalar_time);
    printf("  C SIMD:      %6.2f ms  (%5.1f FPS)  %.2fx speedup\n",
           simd_time, 1000.0/simd_time, scalar_time/simd_time);
    printf("  Rake SIMD:   %6.2f ms  (%5.1f FPS)  %.2fx speedup\n",
           rake_time, 1000.0/rake_time, scalar_time/rake_time);
    printf("================================================================\n");
    printf("\n");
    printf("Controls:\n");
    printf("  1 = C Scalar    2 = C SIMD (AVX2)    3 = Rake SIMD\n");
    printf("  Q/Escape = Quit\n\n");

    int mode = 2;  /* Start with Rake */
    bool running = true;
    float time_offset = 0.0f;

    /* FPS tracking */
    double fps_update_time = get_time_ms();
    int frame_count = 0;
    double current_fps = 0.0;

    while (running) {
        SDL_Event event;
        while (SDL_PollEvent(&event)) {
            if (event.type == SDL_QUIT) running = false;
            if (event.type == SDL_KEYDOWN) {
                switch (event.key.keysym.sym) {
                    case SDLK_q: case SDLK_ESCAPE: running = false; break;
                    case SDLK_1: mode = 0; break;
                    case SDLK_2: mode = 1; break;
                    case SDLK_3: mode = 2; break;
                }
            }
        }

        /* Animate spheres */
        time_offset += 0.03f;
        Sphere animated[NUM_SPHERES];
        for (int i = 0; i < NUM_SPHERES; i++) {
            animated[i] = spheres[i];
            animated[i].cx += 0.8f * sinf(time_offset + i * 1.3f);
            animated[i].cy += 0.5f * cosf(time_offset * 0.8f + i * 0.9f);
            animated[i].cz += 0.3f * sinf(time_offset * 0.5f + i * 1.1f);
        }

        /* Trace */
        double frame_start = get_time_ms();
        switch (mode) {
            case 0: trace_scalar(&rays, animated, NUM_SPHERES, result, sphere_ids); break;
            case 1: trace_simd(&rays, animated, NUM_SPHERES, result, sphere_ids); break;
            case 2: trace_rake(&rays, animated, NUM_SPHERES, result, sphere_ids); break;
        }
        double frame_time = get_time_ms() - frame_start;

        /* Render */
        render_to_surface(surface, result, sphere_ids, animated, WIDTH, HEIGHT);
        draw_mode_indicator(surface, mode, current_fps);
        SDL_UpdateWindowSurface(window);

        /* Update FPS counter */
        frame_count++;
        double now = get_time_ms();
        if (now - fps_update_time >= 500.0) {
            current_fps = frame_count * 1000.0 / (now - fps_update_time);
            fps_update_time = now;
            frame_count = 0;
        }

        /* Update title with FPS */
        char title[128];
        const char *mode_names[] = { "C Scalar", "C SIMD (AVX2)", "Rake SIMD" };
        snprintf(title, sizeof(title), "Rake Raytracer - %s - %.1f FPS (%.2f ms)",
                 mode_names[mode], current_fps, frame_time);
        SDL_SetWindowTitle(window, title);
    }

    /* Cleanup */
    free(rays.ox); free(rays.oy); free(rays.oz);
    free(rays.dx); free(rays.dy); free(rays.dz);
    free(result);
    free(sphere_ids);

    SDL_DestroyWindow(window);
    SDL_Quit();

    printf("Demo finished.\n");
    return 0;
}
