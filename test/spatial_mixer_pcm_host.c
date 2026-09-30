#include "../GuestFrameworks/AudioToolbox/LC32SpatialMixerPCM.h"

#include <assert.h>
#include <stdio.h>

int main(void) {
    /* Negative, positive and minimum samples catch interpreting two signed
     * samples as one Float32. The sentinel also checks the requested length. */
    const uint8_t pcm[] = {0, 0, 0, 0x40, 0, 0xc0, 0, 0x80, 0xff, 0x7f};
    float left[] = {0, 0, 0, 0, 0, 99};
    float right[] = {0, 0, 0, 0, 0, 99};
    LC32SpatialMixerAccumulatePCM(pcm, LC32SpatialMixerPCMSigned16,
        5, 0.5f, left, right);
    assert(left[0] == 0 && left[1] == 0.25f && left[2] == -0.25f);
    assert(left[3] == -0.5f && left[4] == 32767.0f / 65536.0f);
    assert(memcmp(left, right, sizeof(left)) == 0);
    assert(left[5] == 99);

    const float values[] = {0.5f, -0.5f, 0.25f, -0.25f, 0};
    uint8_t unaligned[sizeof(values) + 1];
    memcpy(unaligned + 1, values, sizeof(values));
    LC32SpatialMixerAccumulatePCM(unaligned + 1, LC32SpatialMixerPCMFloat32,
        5, 0.5f, left, right);
    assert(left[0] == 0.25f && left[1] == 0 && left[2] == -0.125f);
    assert(left[3] == -0.625f && left[5] == 99);
    assert(memcmp(left, right, sizeof(left)) == 0);
    puts("spatial mixer signed16 and Float32 conversion: PASS");
    return 0;
}
