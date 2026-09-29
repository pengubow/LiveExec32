#ifndef LC32_CORE_MEDIA_TIME_ABI_H
#define LC32_CORE_MEDIA_TIME_ABI_H

#include <string.h>

/* CMTime contains int64_t, int32_t, uint32_t, and int64_t fields. Its
 * anonymous encoding loses the typedef name, but the fixed-width layout
 * remains identical across the guest and host. Match the complete encoding
 * so other anonymous structures cannot acquire CMTime's call convention. */
static inline int LC32EncodingIsCMTime(const char *encoding) {
    while(encoding && *encoding && strchr("rnNoORVA", *encoding)) {
        ++encoding;
    }
    if(!encoding) return 0;
    return !strcmp(encoding, "{?=qiIq}") ||
        !strcmp(encoding, "{CMTime=qiIq}");
}

#endif
