#ifndef RAKE_TEST_CALLBACKS_H
#define RAKE_TEST_CALLBACKS_H

#include <stdint.h>

typedef struct CallbackContext {
    int32_t  bias;
    double   factor;
    uint64_t calls;
} CallbackContext;

typedef int64_t (*Accumulator)(void *, int64_t, double);
typedef void (*Observer)(void *, int32_t);

typedef struct CallbackPacket {
    uint8_t     tag;
    Accumulator accumulate;
    Observer    observe;
    void       *context;
} CallbackPacket;

CallbackPacket callback_packet_make(void *, Accumulator, Observer);
Accumulator callback_select(int32_t);
int64_t callback_from_c(void *, int64_t, double);

int64_t rake_callback(void *, int64_t, double);
void rake_observe(void *, int32_t);
int64_t rake_callback_use(CallbackPacket *);
CallbackPacket rake_callback_packet(CallbackContext *);
int64_t rake_callback_round_trip(CallbackContext *);
int32_t callback_abi_test(void);

#endif
