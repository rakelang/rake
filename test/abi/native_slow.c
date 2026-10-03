#define _GNU_SOURCE
#include "native_slow.h"
#include <stddef.h>
#include <pthread.h>
#include <stdio.h>
#include <stdatomic.h>

NativePacket native_packet_make(int32_t *values)
{
    return (NativePacket){ .tag = 7, .weight = 1.25, .values = values,
                           .samples = { 3, 11, 17 } };
}

int64_t native_packet_check(const NativePacket *packet)
{
    return packet->tag + (int64_t)(packet->weight * 8.0)
           + packet->values[2] + packet->samples[1];
}

static pthread_barrier_t frame_barrier;
static atomic_int callback_failures;

void native_frame_wait(void)
{
    NativePacket packet = rake_frame_packet(73);
    if (packet.tag != 9 || packet.weight != 200.0 || packet.values != NULL
        || packet.samples[0] != 73 || packet.samples[1] != 136
        || packet.samples[2] != 200) atomic_fetch_add(&callback_failures, 1);
    pthread_barrier_wait(&frame_barrier);
}

typedef struct FrameCall { int32_t seed, result; } FrameCall;

static void *frame_worker(void *context)
{
    FrameCall *call = context;
    for (int iteration = 0; iteration < 8; ++iteration)
        call->result += rake_frame_sum(call->seed, 3);
    return NULL;
}

int main(void)
{
    /* System V AMD64 and AAPCS64 agree on these independently defined C
       offsets. The Rake object must actually read and write those fields. */
    if (sizeof(NativePacket) != 32 || _Alignof(NativePacket) != 8
        || offsetof(NativePacket, weight) != 8
        || offsetof(NativePacket, values) != 16
        || offsetof(NativePacket, samples) != 24) return 1;
    int32_t values[] = { 5, 13, 19, 23 };
    NativePacket packet = rake_packet_make(values);
    if (packet.tag != 7 || packet.weight != 1.25 || packet.values != values
        || packet.samples[0] != 3 || packet.samples[2] != 17) return 2;
    if (rake_packet_score(&packet) != 47) return 3;
    if (rake_packet_update(&packet) != 63) return 4;
    if (packet.weight != 1.75 || values[2] != 29
        || packet.samples[1] != 13 || rake_packet_score(&packet) != 63) return 5;
    FrameCall calls[] = { { 10, 0 }, { 20, 0 } };
    pthread_t threads[2];
    pthread_attr_t attributes;
    if (pthread_barrier_init(&frame_barrier, NULL, 2) != 0) return 6;
    /* A host runtime may use small worker stacks. Rake's arena must not
       impose a multi-megabyte TLS reservation on every such thread. */
    if (pthread_attr_init(&attributes) != 0
        || pthread_attr_setstacksize(&attributes, 128 * 1024) != 0) return 7;
    for (int index = 0; index < 2; index++)
        if (pthread_create(&threads[index], &attributes, frame_worker, &calls[index]) != 0) return 7;
    pthread_attr_destroy(&attributes);
    for (int index = 0; index < 2; index++)
        if (pthread_join(threads[index], NULL) != 0) return 8;
    pthread_barrier_destroy(&frame_barrier);
    /* Sum_i i = 8128 per frame; each call keeps four 128-element frames. */
    if (calls[0].result != 8 * 628992 || calls[1].result != 8 * 1140992
        || atomic_load(&callback_failures) != 0) return 9;
    puts("native C imports, exports and struct layout passed");
    return 0;
}
