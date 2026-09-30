#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <mach-o/loader.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* This dyld SPI is not declared by the public SDK headers. Use UIKit's
 * platform/version predicate rather than interpreting a missing SDK as 0. */
struct LC32DyldBuildVersion {
    uint32_t platform;
    uint32_t version;
};
extern "C" bool dyld_program_sdk_at_least(LC32DyldBuildVersion version);

extern "C" uint32_t LC32UIKitLegacyCompatibilityEnabled(void) {
    /* Read once before host/guest compatibility methods or observers are
     * installed: changing modes with a live hierarchy is unsafe. UIKit's
     * native pre-iOS-8 window compositor already handles legacy rotation.
     * Applying our modern-host adapters as well can turn the content twice.
     * Use dyld's effective process SDK, not the on-disk host/guest headers.
     * LiveContainer installs its dyld SDK override before loading us: an
     * unclamped pre-iOS-8 override must use native geometry, while existing
     * SDK-11-clamped hosts/shims still need our modern-host adapters. */
    static const bool enabled = [] {
        const char *value = getenv("LC32_DISABLE_UIKIT_COMPATIBILITY");
        if(value && strcmp(value, "1") == 0) return false;
        return dyld_program_sdk_at_least({PLATFORM_IOS, 0x00080000});
    }();
    return enabled;
}

static BOOL LC32EnableLegacyLayoutPolicy(id, SEL) {
    return YES;
}

using LC32NativeLayoutHostPolicy = BOOL (*)(id, SEL);
static LC32NativeLayoutHostPolicy LC32OriginalLayoutHostPolicy;
static const char *const LC32NativeLayoutHostClasses[] = {
    "UITrackingWindowView",
    "UIInputSetContainerView",
    "_UIAlertControllerPhoneTVMacView",
};

static BOOL LC32LegacyNativeLayoutHostPolicy(id view, SEL selector) {
    // TextInputUI can load its tracking view after our +load. Testing the
    // receiver's class here also covers that late load without modifying
    // an image while the Objective-C runtime holds its loading lock.
    for(Class cls = object_getClass(view); cls;
            cls = class_getSuperclass(cls)) {
        const char *name = class_getName(cls);
        for(const char *hostName : LC32NativeLayoutHostClasses) {
            if(strcmp(name, hostName) != 0) continue;
            return YES;
        }
    }
    const BOOL allowed = LC32OriginalLayoutHostPolicy(view, selector);
    return allowed;
}

@interface LC32LegacyAutoLayout : NSObject
@end

@implementation LC32LegacyAutoLayout
+ (void)load {
    if(dyld_program_sdk_at_least({PLATFORM_IOS, 0x00080000})) return;

    /* Modern UIKit creates layout guides even for pre-iOS-8 executables.
     * Its old center/bounds layout cannot represent those guides and raises
     * "Error in compatibility flow". This delegate opt-in selects rational
     * edges consistently in both engine setup and result extraction, unlike
     * skipping the assertion or replacing only the exported helper (which
     * UIKit also inlines). Keep every other linked-SDK behavior unchanged.
     *
     * Replace only UIView's base implementation: subclasses with their own
     * policy must retain it. Install before the first guest layout engine. */
    Class viewClass = UIView.class;
    SEL selector = sel_registerName("_forceLayoutEngineSolutionInRationalEdges");
    Method method = class_getInstanceMethod(viewClass, selector);
    if(method) {
        class_replaceMethod(viewClass, selector,
            (IMP)LC32EnableLegacyLayoutPolicy, method_getTypeEncoding(method));
    }

    /* Legacy UIWindow rotation explicitly makes its root an engine host.
     * UIKit's modern alert, text-effects and remote-keyboard roots have
     * translatesAutoresizingMaskIntoConstraints == NO, which the old host
     * invariant rejects when an overlay/keyboard opens in landscape. Opt
     * just those native classes into hosting without autoresizing constraints.
     * The inherited base policy handles views loaded later too; unrelated
     * views and subclass overrides retain their native answer. */
    selector = sel_registerName("_hostsLayoutEngineAllowsTAMIC_NO");
    method = class_getInstanceMethod(viewClass, selector);
    if(!method) return;
    LC32OriginalLayoutHostPolicy = (LC32NativeLayoutHostPolicy)
        method_getImplementation(method);
    method_setImplementation(method, (IMP)LC32LegacyNativeLayoutHostPolicy);
    for(const char *className : LC32NativeLayoutHostClasses) {
        Class hostClass = objc_getClass(className);
        method = hostClass ? class_getInstanceMethod(hostClass, selector) : NULL;
        if(method) {
            class_replaceMethod(hostClass, selector,
                (IMP)LC32LegacyNativeLayoutHostPolicy, method_getTypeEncoding(method));
        }
    }
}
@end
