#ifndef LC32_INVOCATION_ABI_H
#define LC32_INVOCATION_ABI_H

#include <stddef.h>
#include <string.h>

enum {
    LC32InvocationMaxFloatingFields = 4,
    LC32InvocationMaxValueBytes = LC32InvocationMaxFloatingFields * 8,
};

typedef struct LC32InvocationFloatingLayout {
    char fieldType;
    unsigned fieldCount;
    size_t byteSize;
} LC32InvocationFloatingLayout;

/* NSInvocation retains the actual declared field types. A guest CGPoint
 * encoded as {CGPoint=ff} therefore stores two floats even on the host.
 * Homogeneous floating records have identical field offsets on both ABIs;
 * mixed records, pointers, unions, and bitfields need separate conversion. */
static inline int LC32InvocationScanFloatingRecord(const char **cursor,
        unsigned depth, LC32InvocationFloatingLayout *layout) {
    const char *type = *cursor;
    while(*type && strchr("rnNoORVA", *type)) type++;
    if(*type != '{' || depth >= 16) return 0;
    type++;
    const char *name = type;
    while(*type && *type != '=') {
        if(strchr("{}()[]\"", *type)) return 0;
        type++;
    }
    if(type == name || *type != '=') return 0;
    type++;
    const unsigned previousFields = layout->fieldCount;
    while(*type && *type != '}') {
        if(*type == '"') {
            type++;
            while(*type && *type != '"') {
                if(*type == '\\') {
                    type++;
                    if(!*type) return 0;
                }
                type++;
            }
            if(*type != '"') return 0;
            type++;
        }
        while(*type && strchr("rnNoORVA", *type)) type++;
        if(*type == '{') {
            if(!LC32InvocationScanFloatingRecord(&type, depth + 1, layout))
                return 0;
        } else {
            if(*type != 'f' && *type != 'd') return 0;
            if(layout->fieldCount && layout->fieldType != *type) return 0;
            if(layout->fieldCount == LC32InvocationMaxFloatingFields) return 0;
            layout->fieldType = *type++;
            layout->fieldCount++;
        }
    }
    if(*type != '}' || layout->fieldCount == previousFields) return 0;
    *cursor = type + 1;
    return 1;
}

static inline int LC32InvocationGetFloatingLayout(const char *type,
        LC32InvocationFloatingLayout *result) {
    if(!type || !result) return 0;
    LC32InvocationFloatingLayout layout = {0, 0, 0};
    if(!LC32InvocationScanFloatingRecord(&type, 0, &layout) || *type)
        return 0;
    layout.byteSize = layout.fieldCount * (layout.fieldType == 'f' ? 4u : 8u);
    *result = layout;
    return 1;
}

#endif
