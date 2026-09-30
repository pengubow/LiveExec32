#pragma once

#include <stddef.h>
#include <stdint.h>
#include <string.h>

typedef enum {
    LC32SpatialMixerPCMFloat32,
    LC32SpatialMixerPCMSigned16,
} LC32SpatialMixerPCMKind;

/* The mixer validates the ASBD before calling this routine. Read samples by
 * value: a callback may supply unaligned storage instead of the offered buffer.
 * Both supported encodings use the guest's little-endian byte order. */
static inline void LC32SpatialMixerAccumulatePCM(const void *input,
        LC32SpatialMixerPCMKind kind, size_t frameCount, float gain,
        float *left, float *right) {
    const uint8_t *bytes = input;
    for(size_t frame = 0; frame < frameCount; ++frame) {
        float sample;
        if(kind == LC32SpatialMixerPCMSigned16) {
            const uint16_t bits = (uint16_t)bytes[frame * 2] |
                ((uint16_t)bytes[frame * 2 + 1] << 8);
            const int32_t value = bits >= 0x8000u
                ? (int32_t)bits - 0x10000 : (int32_t)bits;
            sample = (float)value / 32768.0f;
        } else {
            memcpy(&sample, bytes + frame * sizeof(sample), sizeof(sample));
        }
        sample *= gain;
        left[frame] += sample;
        right[frame] += sample;
    }
}
