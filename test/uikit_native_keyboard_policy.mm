#import "LC32LegacyKeyboard.h"
#import "LC32LegacyRotation.h"
#import "LC32NativeWindowPolicy.h"
#import <objc/message.h>
#include <math.h>
#include <stdio.h>

namespace {
BOOL CompositorPolicy(void) {
    return ((BOOL (*)(id, SEL))objc_msgSend)(UIWindow.class,
        sel_registerName("_transformLayerRotationsAreEnabled"));
}
}

/* Called by the native rotation fixture. Exercise the real UIKit input window
 * and production scope, including nested guest work and exception cleanup. */
extern "C" void LC32TestNativeKeyboardPolicy(UIWindow *guest,
        void (*check)(const char *, BOOL)) {
    UIWindowScene *scene = guest.windowScene;
    if(!scene) {
        puts("native-keyboard-policy: SKIP (fixture has no window scene)");
        return;
    }
    Class effectsClass = NSClassFromString(@"UITextEffectsWindow");
    SEL factory = sel_registerName(
        "sharedTextEffectsWindowForWindowScene:forViewService:");
    check("native-input-factory-present", [effectsClass respondsToSelector:factory]);
    if(![effectsClass respondsToSelector:factory]) return;

    UIWindow *effects = ((UIWindow *(*)(id, SEL, UIWindowScene *, BOOL))objc_msgSend)(
        effectsClass, factory, scene, NO);
    check("native-input-window-created", effects != nil);
    if(!effects) return;
    const BOOL baseline = CompositorPolicy();
    check("native-input-policy-sdk-gate",
        LC32NativeKeyboardWindowUsesScenePolicy(effects) == LC32NativeLegacyRotationEnabled());
    check("native-input-policy-excludes-guest",
        !LC32NativeKeyboardWindowUsesScenePolicy(guest));
    CGRect initialBounds = effects.bounds;
    {
        LC32NativeWindowSceneScope inputPolicy(effects);
        check("native-input-scoped-compositor", CompositorPolicy());
        {
            LC32NativeWindowSceneScope guestPolicy(guest);
            check("native-input-nested-guest-retains-sdk", CompositorPolicy() == baseline);
        }
        check("native-input-scope-restored-after-guest", CompositorPolicy());
        {
            LC32NativeWindowSceneScope emptyPolicy(nil);
            check("native-input-empty-scope-retains-sdk", CompositorPolicy() == baseline);
        }
        check("native-input-scope-restored-after-empty", CompositorPolicy());
    }
    check("native-input-global-policy-restored", CompositorPolicy() == baseline);
    check("native-input-scope-does-not-resize-window",
        CGRectEqualToRect(initialBounds, effects.bounds));
    BOOL caught = NO;
    @try {
        LC32NativeWindowSceneScope inputPolicy(effects);
        @throw [NSException exceptionWithName:@"LC32InputScopeProbe"
            reason:@"Verify native input scope cleanup" userInfo:nil];
    } @catch(NSException *exception) {
        caught = [exception.name isEqualToString:@"LC32InputScopeProbe"];
        if(!caught) @throw;
    }
    check("native-input-scope-exception-preserved", caught);
    check("native-input-global-policy-restored-after-exception", CompositorPolicy() == baseline);
    CGRect bounds = ((CGRect (*)(id, SEL))objc_msgSend)(effects,
        sel_registerName("_sceneBounds"));
    check("native-input-bounds-finite", isfinite(bounds.size.width) &&
        isfinite(bounds.size.height) && bounds.size.width > 0 && bounds.size.height > 0);
}
