/* The C side of interop.rk. */
#include "interop.h"

int32_t interop_sum(const int32_t *p, int32_t n)
{
    int32_t total = 0;
    for (int32_t i = 0; i < n; i++) total += p[i];
    return total;
}

int32_t interop_length(const uint8_t *text)
{
    int32_t n = 0;
    while (text[n] != 0) n++;
    return n;
}

void interop_point(Point *p, int32_t x, int32_t y)
{
    p->x = x;
    p->y = y;
}

int32_t interop_bytes(const uint8_t *p, int32_t n)
{
    int32_t total = 0;
    for (int32_t i = 0; i < n; i++) total += p[i] * (i + 1);
    return total;
}

static int32_t buffer[8] = { 5, 6, 7, 8, 9, 10, 11, 12 };
int32_t *interop_buffer(void) { return buffer; }
