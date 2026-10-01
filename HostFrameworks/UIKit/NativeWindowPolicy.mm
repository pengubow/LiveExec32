#import "LC32NativeWindowPolicy.h"
#import "LC32NativeUIKitMethod.h"
#import "LC32LegacyAlerts.h"
#import "LC32LegacyKeyboard.h"
#include <dlfcn.h>
#include <stdint.h>

using namespace LC32NativeUIKit;

namespace {
NativeMethod windowPolicy;
thread_local __unsafe_unretained UIWindow *nativeSceneWindow;
thread_local void *policyCaller;
bool scenePolicyInstalled;

__attribute__((noinline)) BOOL TransformPolicy(id self, SEL selector) {
    if(nativeSceneWindow) return YES;
    if(policyCaller) {
        void *returnPC = CodeAddress(__builtin_extract_return_addr(__builtin_return_address(0)));
        Dl_info info = {};
        // Inspect the calling instruction, not the next function boundary.
        if(dladdr((void *)((uintptr_t)returnPC - 1), &info) && info.dli_saddr == policyCaller) {
            return YES;
        }
    }
    return ((BOOL (*)(id, SEL))windowPolicy.original)(self, selector);
}
}

bool LC32InstallNativeWindowScenePolicy(void) {
    static const bool installed = [] {
        Dl_info image = {};
        if(!dladdr((__bridge const void *)UIViewController.class, &image) ||
                !Prepare(windowPolicy, object_getClass(UIWindow.class),
                    "_transformLayerRotationsAreEnabled", "B", {}, image.dli_fbase)) {
            return false;
        }
        Replace(windowPolicy, (IMP)TransformPolicy);
        scenePolicyInstalled = true;
        return true;
    }();
    return installed;
}

bool LC32NativeWindowScenePolicyInstalled(void) {
    return scenePolicyInstalled;
}

LC32NativeWindowSceneScope::LC32NativeWindowSceneScope(UIWindow *window)
    : previous_(nativeSceneWindow) {
    const bool sceneOwned = LC32NativeAlertWindowUsesScenePolicy(window) ||
        LC32NativeKeyboardWindowUsesScenePolicy(window);
    nativeSceneWindow = sceneOwned ? window : nil;
}

LC32NativeWindowSceneScope::~LC32NativeWindowSceneScope() {
    nativeSceneWindow = previous_;
}

LC32NativeWindowCallerScope::LC32NativeWindowCallerScope(bool enabled, IMP caller)
    : previous_(policyCaller) {
    policyCaller = enabled ? CodeAddress((void *)caller) : nullptr;
}

LC32NativeWindowCallerScope::~LC32NativeWindowCallerScope() {
    policyCaller = previous_;
}
