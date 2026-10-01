#import "LC32NativeUIKitMethod.h"
#include <dlfcn.h>
#include <ptrauth.h>
#include <string.h>

namespace LC32NativeUIKit {
void *CodeAddress(void *address) {
#if __has_feature(ptrauth_calls)
    return ptrauth_strip(address, ptrauth_key_function_pointer);
#else
    return address;
#endif
}

bool WindowHasClass(UIWindow *window, const char *name) {
    for(Class cls = object_getClass(window); cls;
            cls = class_getSuperclass(cls)) {
        if(strcmp(class_getName(cls), name) == 0) {
            return true;
        }
    }
    return false;
}

bool Prepare(NativeMethod &entry, Class owner, const char *name,
             const char *result, std::initializer_list<const char *> arguments,
             void *nativeImage) {
    if(!owner) {
        return false;
    }
    entry.owner = owner;
    entry.selector = sel_registerName(name);
    entry.method = class_getInstanceMethod(owner, entry.selector);
    if(!entry.method ||
            method_getNumberOfArguments(entry.method) != arguments.size() + 2) {
        return false;
    }
    char type[128];
    method_getReturnType(entry.method, type, sizeof(type));
    if(strcmp(type, result)) {
        return false;
    }
    unsigned index = 2;
    for(const char *argument : arguments) {
        method_getArgumentType(entry.method, index++, type, sizeof(type));
        if(strcmp(type, argument)) {
            return false;
        }
    }
    entry.original = method_getImplementation(entry.method);
    void *address = CodeAddress((void *)entry.original);
    Dl_info info = {};
    // Native methods in the shared image can lack exported symbols. Match
    // the image rather than dli_saddr, which rejects those genuine methods.
    if(!dladdr(address, &info) || info.dli_fbase != nativeImage) {
        return false;
    }
    return true;
}

void Replace(const NativeMethod &entry, IMP replacement) {
    class_replaceMethod(entry.owner, entry.selector, replacement,
        method_getTypeEncoding(entry.method));
}
}
