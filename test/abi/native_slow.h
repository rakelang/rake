#ifndef RAKE_TEST_NATIVE_SLOW_H
#define RAKE_TEST_NATIVE_SLOW_H

#include <stdint.h>

/* Deliberate padding, a pointer, a double and an inline array exercise the
   platform C layout rather than the old wasm32 field-size assumptions. */
typedef struct NativePacket {
    uint8_t tag;
    double weight;
    int32_t *values;
    uint16_t samples[3];
} NativePacket;

/* This layout exceeds a host worker's stack once several calls are live.
   Its stronger alignment cannot be inferred from the Rake field types. */
typedef struct NativeFrameBlock {
    _Alignas(64) int32_t values[16384];
} NativeFrameBlock;

NativePacket native_packet_make(int32_t *values);
int64_t native_packet_check(const NativePacket *packet);
void native_frame_wait(void);
void native_frame_storage_check(const NativeFrameBlock *block, int32_t expected);

/* These are implemented in the separately compiled Rake object. */
int64_t rake_packet_score(const NativePacket *packet);
int64_t rake_packet_update(NativePacket *packet);
NativePacket rake_packet_make(int32_t *values);
int32_t rake_frame_sum(int32_t seed, int32_t depth);
NativePacket rake_frame_packet(int32_t seed);

#endif
