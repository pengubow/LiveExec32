#import "LC32LegacyKeyboard.h"
#import "LC32NativeUIKitMethod.h"
#import "LC32NativeWindowPolicy.h"
#include <dlfcn.h>
#include <mach-o/loader.h>
#include <stdint.h>

struct LC32KeyboardBuildVersion { uint32_t platform, version; };
extern "C" bool dyld_program_sdk_at_least(LC32KeyboardBuildVersion version);

using namespace LC32NativeUIKit;

namespace {
NativeMethod keyboardSceneBounds;
bool keyboardScenePolicyInstalled;

CGRect KeyboardSceneBounds(UIWindow *self, SEL selector) {
    LC32NativeWindowSceneScope scenePolicy(self);
    // The old-SDK branch returns UIScreen.bounds after the window has turned.
    // The current branch derives bounds from the window's orientation. Keep
    // UIKit's hosted-input and windowing-mode calculation in that policy.
    CGRect bounds = ((CGRect (*)(id, SEL))keyboardSceneBounds.original)(self, selector);
    return bounds;
}
}

extern "C" bool LC32NativeKeyboardWindowUsesScenePolicy(UIWindow *window) {
    return keyboardScenePolicyInstalled && LC32NativeWindowScenePolicyInstalled() &&
        !dyld_program_sdk_at_least({PLATFORM_IOS, 0x00080000}) &&
        WindowHasClass(window, "UITextEffectsWindow") && window.windowScene;
}

@interface LC32LegacyKeyboard : NSObject
@end

@implementation LC32LegacyKeyboard
+ (void)load {
    if(dyld_program_sdk_at_least({PLATFORM_IOS, 0x00080000})) return;
    Dl_info image = {};
    if(!dladdr((__bridge const void *)UIViewController.class, &image) ||
            !Prepare(keyboardSceneBounds, NSClassFromString(@"UITextEffectsWindow"),
                "_sceneBounds", @encode(CGRect), {}, image.dli_fbase) ||
            !LC32InstallNativeWindowScenePolicy()) {
        return;
    }
    Replace(keyboardSceneBounds, (IMP)KeyboardSceneBounds);
    keyboardScenePolicyInstalled = true;
}
@end
