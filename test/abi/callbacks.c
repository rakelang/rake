#include "callbacks.h"

CallbackPacket callback_packet_make(void *context, Accumulator accumulate, Observer observe)
{
    return (CallbackPacket){ 7, accumulate, observe, context };
}

int64_t callback_from_c(void *opaque, int64_t value, double weight)
{
    CallbackContext *context = opaque;
    ++context->calls;
    return value + context->bias + (int64_t)(weight * context->factor);
}

Accumulator callback_select(int32_t enabled)
{
    return enabled ? callback_from_c : 0;
}

/* Independently authored C prototypes, layouts and arithmetic check both
   directions of calls, retained pointers, mixed argument classes and void. */
int32_t callback_abi_test(void)
{
    CallbackContext context = { 5, 2.0, 0 };
    CallbackPacket packet = rake_callback_packet(&context);
    if (packet.tag != 7 || packet.context != &context ||
        packet.accumulate != rake_callback || packet.observe != rake_observe) return 1;
    if (packet.accumulate(packet.context, INT64_C(4294967301), 3.5) != INT64_C(4294967313)) return 2;
    packet.observe(packet.context, 11);
    if (context.bias != 16 || context.calls != 2) return 3;
    if (rake_callback_use(&packet) != 64) return 4;
    if (context.bias != 19 || context.calls != 4) return 5;
    if (rake_callback_round_trip(&context) != 35 || context.calls != 5) return 6;
    Accumulator saved = callback_select(1);
    if (!saved || callback_select(0) || saved(&context, 1, 2.0) != 24) return 7;
    return 0;
}
