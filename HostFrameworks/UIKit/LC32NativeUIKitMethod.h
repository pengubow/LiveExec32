#pragma once

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <initializer_list>

namespace LC32NativeUIKit {
struct NativeMethod {
    Class owner;
    SEL selector;
    Method method;
    IMP original;
};

void *CodeAddress(void *address);
bool WindowHasClass(UIWindow *window, const char *name);
bool Prepare(NativeMethod &entry, Class owner, const char *name,
    const char *result, std::initializer_list<const char *> arguments,
    void *nativeImage);
void Replace(const NativeMethod &entry, IMP replacement);
}
