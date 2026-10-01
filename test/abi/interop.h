/* C functions and a C struct for interop.rk; interop.c defines the functions. */
#include <stdint.h>

typedef struct Point { int32_t x; int32_t y; } Point;

int32_t interop_sum(const int32_t *p, int32_t n);
int32_t interop_length(const uint8_t *text);
void interop_point(Point *p, int32_t x, int32_t y);
int32_t interop_bytes(const uint8_t *p, int32_t n);
int32_t *interop_buffer(void);
