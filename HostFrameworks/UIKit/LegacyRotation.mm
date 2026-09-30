#import "LC32LegacyRotation.h"
#import "LC32LegacyAlerts.h"
#import "LC32LegacyCanvas.h"
#import "LC32LegacyScenes.h"
#import "LC32NativeViewGeometry.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <pthread.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// This unit deliberately restores UIKit's deprecated pre-iOS-8 contract.
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

@interface LC32LegacyRotationState : NSObject
@property(nonatomic, weak) UIViewController *initializedController;
@property(nonatomic, weak) UIViewController *canvasController;
@property(nonatomic, weak) UIViewController *startupCanvasController;
@property(nonatomic, weak) UIViewController *sceneContainer;
@property(nonatomic, weak) UIViewController *manualOrientationController;
@property(nonatomic, weak) UIViewController *alertOrientationController;
@property(nonatomic) UIInterfaceOrientation alertOrientation;
@property(nonatomic) BOOL synchronizingAlertOrientation;
@property(nonatomic) BOOL alertPlacementScheduled;
@property(nonatomic) unsigned alertSyncSkipState;
@property(nonatomic) CGRect canvasBounds;
@property(nonatomic) CGRect portraitInitialViewport;
@property(nonatomic) CGPoint portraitInitialCenter;
@property(nonatomic) CGAffineTransform portraitAppliedTransform;
@property(nonatomic) BOOL portraitCanvas;
@property(nonatomic) BOOL portraitCanvasYielded;
@property(nonatomic) BOOL fittingCanvas;
@end
@implementation LC32LegacyRotationState
@end

struct LC32RotationBuildVersion { uint32_t platform, version; };
extern "C" bool dyld_program_sdk_at_least(LC32RotationBuildVersion version);
extern "C" uint32_t LC32UIKitLegacyCompatibilityEnabled(void);

namespace {
const void *RegisteredClassKey = &RegisteredClassKey;
const void *WindowStateKey = &WindowStateKey;
const void *DirectRendererOrientationKey = &DirectRendererOrientationKey;
const void *SceneContainerKey = &SceneContainerKey;
bool startupFinished;
using NativeRotationQuery = BOOL (*)(id, SEL, UIInterfaceOrientation, BOOL, BOOL *);
NativeRotationQuery nativeRotationQuery;
thread_local __unsafe_unretained UIWindow *configuringLegacyWindow;

LC32LegacyRotationState *WindowState(UIWindow *window) {
    LC32LegacyRotationState *state = objc_getAssociatedObject(window, WindowStateKey);
    if(!state) {
        state = [LC32LegacyRotationState new];
        objc_setAssociatedObject(window, WindowStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return state;
}

UIInterfaceOrientationMask DeclaredOrientations();
UIInterfaceOrientation PreferredOrientation(UIInterfaceOrientationMask mask = 0);
UIInterfaceOrientationMask OrientationBit(UIInterfaceOrientation orientation);

UIInterfaceOrientationMask LegacySupportedOrientations(id controller, SEL) {
    // This is a policy query, not a rotation request. In particular, old Unity
    // writes its pending orientation even when shouldAutorotate returns NO.
    // Probing all four directions here would leave an arbitrary pending turn.
    NSNumber *derived = objc_getAssociatedObject(
        controller, DirectRendererOrientationKey);
    if(derived.unsignedIntegerValue) {
        return (UIInterfaceOrientationMask)derived.unsignedIntegerValue;
    }
    return DeclaredOrientations();
}

UIInterfaceOrientation LegacyPreferredOrientation(id controller, SEL) {
    const UIInterfaceOrientationMask mask =
        LegacySupportedOrientations(controller, @selector(supportedInterfaceOrientations));
    UIInterfaceOrientation preferred = PreferredOrientation();
    if(OrientationBit(preferred) & mask) return preferred;

    preferred = (UIInterfaceOrientation)UIDevice.currentDevice.orientation;
    if(OrientationBit(preferred) & mask) return preferred;
    const UIInterfaceOrientation order[] = {
        UIInterfaceOrientationLandscapeRight,
        UIInterfaceOrientationLandscapeLeft,
        UIInterfaceOrientationPortrait,
        UIInterfaceOrientationPortraitUpsideDown,
    };
    for(UIInterfaceOrientation orientation : order) {
        if(OrientationBit(orientation) & mask) return orientation;
    }
    return UIInterfaceOrientationPortrait;
}

bool RegisteredClass(Class cls) {
    for(Class current = cls; current && current != UIViewController.class;
            current = class_getSuperclass(current)) {
        if(objc_getAssociatedObject((id)current, RegisteredClassKey)) return true;
    }
    return false;
}

bool UsesLegacyRotationPolicy(Class cls) {
    if(!RegisteredClass(cls)) return false;
    if(class_getMethodImplementation(cls, @selector(shouldAutorotateToInterfaceOrientation:)) ==
            class_getMethodImplementation(UIViewController.class,
                @selector(shouldAutorotateToInterfaceOrientation:))) return false;
    // Recheck the actual subclass: a guest can inherit the old callback but
    // deliberately replace its policy with the modern orientation API.
    IMP supported = class_getMethodImplementation(
        cls, @selector(supportedInterfaceOrientations));
    IMP should = class_getMethodImplementation(cls, @selector(shouldAutorotate));
    return (supported == (IMP)LegacySupportedOrientations ||
            supported == class_getMethodImplementation(UIViewController.class,
                @selector(supportedInterfaceOrientations))) &&
        should == class_getMethodImplementation(UIViewController.class,
            @selector(shouldAutorotate));
}

NSHashTable<UIViewController *> *Controllers() {
    static NSHashTable<UIViewController *> *controllers;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ controllers = [NSHashTable weakObjectsHashTable]; });
    return controllers;
}

UIView *NativeView(UIViewController *controller) {
    using Getter = UIView *(*)(id, SEL);
    static Getter getter = (Getter)class_getMethodImplementation(
        UIViewController.class, @selector(viewIfLoaded));
    return getter(controller, @selector(viewIfLoaded));
}

UIView *NativeSuperview(UIView *view) {
    using Getter = UIView *(*)(id, SEL);
    static Getter getter = (Getter)class_getMethodImplementation(
        UIView.class, @selector(superview));
    return getter(view, @selector(superview));
}

UIWindow *NativeWindow(UIView *view) {
    using Getter = UIWindow *(*)(id, SEL);
    static Getter getter = (Getter)class_getMethodImplementation(
        UIView.class, @selector(window));
    return getter(view, @selector(window));
}

UIViewController *NativeRoot(UIWindow *window) {
    using Getter = UIViewController *(*)(id, SEL);
    static Getter getter = (Getter)class_getMethodImplementation(
        UIWindow.class, @selector(rootViewController));
    return getter(window, @selector(rootViewController));
}

UIViewController *NativeParent(UIViewController *controller) {
    using Getter = UIViewController *(*)(id, SEL);
    static Getter getter = (Getter)class_getMethodImplementation(
        UIViewController.class, @selector(parentViewController));
    return getter(controller, @selector(parentViewController));
}

UIViewController *NativePresenting(UIViewController *controller) {
    using Getter = UIViewController *(*)(id, SEL);
    static Getter getter = (Getter)class_getMethodImplementation(
        UIViewController.class, @selector(presentingViewController));
    return getter(controller, @selector(presentingViewController));
}

UIViewController *NativePresented(UIViewController *controller) {
    using Getter = UIViewController *(*)(id, SEL);
    static Getter getter = (Getter)class_getMethodImplementation(
        UIViewController.class, @selector(presentedViewController));
    return getter(controller, @selector(presentedViewController));
}

bool IsNativeQuarterTurn(CGAffineTransform transform) {
    constexpr CGFloat epsilon = 0.001;
    return fabs(transform.a) <= epsilon && fabs(transform.d) <= epsilon &&
        fabs(fabs(transform.b) - 1) <= epsilon &&
        fabs(transform.b + transform.c) <= epsilon &&
        fabs(transform.tx) <= epsilon && fabs(transform.ty) <= epsilon;
}

bool IsNativeOpenGLESView(UIView *view) {
    if(!view) return false;
    static Class eaglLayerClass = NSClassFromString(@"CAEAGLLayer");
    return [LC32NativeViewLayer(view) isKindOfClass:eaglLayerClass];
}

NSHashTable<UIWindow *> *NativeAlertWindows() {
    static NSHashTable<UIWindow *> *windows;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        windows = [NSHashTable weakObjectsHashTable];
    });
    return windows;
}

void TrackNativeAlertWindow(UIWindow *window) {
    if([NativeAlertWindows() containsObject:window]) return;
    [NativeAlertWindows() addObject:window];
    LC32ObserveClassicCanvasScene(window.windowScene);
}

void RememberNativeAlertOrientation(UIWindow *window,
        UIInterfaceOrientation orientation) {
    TrackNativeAlertWindow(window);
    LC32LegacyRotationState *state = WindowState(window);
    state.alertOrientationController = NativeRoot(window);
    state.alertOrientation = orientation;
}

UIViewController *ControllerForWindow(UIWindow *window, bool forBacking = false) {
    if(!window) return nil;
    if(forBacking && LC32NativeAlertWindowUsesScenePolicy(window)) return nil;
    UIViewController *root = NativeRoot(window);
    if(root) {
        // Low-SDK UIKit still rotates a modern-policy root's view in portrait
        // window coordinates. It needs the same inverse backing rotation, but
        // must retain its modern policy without deprecated policy queries.
        Class cls = object_getClass(root);
        return forBacking ? (RegisteredClass(cls) ||
                LC32IsNativeAlertPresenterWindow(window) ||
                objc_getAssociatedObject(root, SceneContainerKey) ? root : nil) :
            (!NativePresented(root) && UsesLegacyRotationPolicy(cls) ? root : nil);
    }
    UIViewController *candidate = nil;
    for(UIViewController *controller in Controllers().allObjects) {
        // A renderer-owned controller can omit every rotation-policy method.
        // It still needs portrait backing coordinates, without old queries.
        Class cls = object_getClass(controller);
        if(!(forBacking ? RegisteredClass(cls) : UsesLegacyRotationPolicy(cls))) continue;
        UIView *view = NativeView(controller);
        if(view && NativeSuperview(view) == window &&
                !NativeParent(controller) &&
                !NativePresenting(controller) &&
                (forBacking || !NativePresented(controller))) {
            // Two independent direct children do not establish one rotation
            // owner. Do not pick one based on weak-table enumeration order.
            if(candidate) return nil;
            candidate = controller;
        }
    }
    return candidate;
}

UIInterfaceOrientation OrientationNamed(id name) {
    if([name isEqual:@"UIInterfaceOrientationPortrait"]) return UIInterfaceOrientationPortrait;
    if([name isEqual:@"UIInterfaceOrientationPortraitUpsideDown"]) return UIInterfaceOrientationPortraitUpsideDown;
    if([name isEqual:@"UIInterfaceOrientationLandscapeLeft"]) return UIInterfaceOrientationLandscapeLeft;
    if([name isEqual:@"UIInterfaceOrientationLandscapeRight"]) return UIInterfaceOrientationLandscapeRight;
    return UIInterfaceOrientationUnknown;
}

UIInterfaceOrientationMask OrientationBit(UIInterfaceOrientation orientation) {
    return orientation >= UIInterfaceOrientationPortrait &&
        orientation <= UIInterfaceOrientationLandscapeLeft
        ? (UIInterfaceOrientationMask)(1UL << orientation) : 0;
}

NSArray *DeclaredOrientationNames() {
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    id names;
    if(UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad)
        names = info[@"UISupportedInterfaceOrientations~ipad"];
    if(![names isKindOfClass:NSArray.class]) names = info[@"UISupportedInterfaceOrientations"];
    return [names isKindOfClass:NSArray.class] ? names : nil;
}

UIInterfaceOrientationMask DeclaredOrientations() {
    UIInterfaceOrientationMask mask = 0;
    for(id name in DeclaredOrientationNames()) mask |= OrientationBit(OrientationNamed(name));
    return mask ?: UIInterfaceOrientationMaskAllButUpsideDown;
}

UIInterfaceOrientation PreferredOrientation(UIInterfaceOrientationMask mask) {
    if(!mask) mask = DeclaredOrientations();
    UIInterfaceOrientation current = UIApplication.sharedApplication.statusBarOrientation;
    if(OrientationBit(current) & mask) return current;
    current = OrientationNamed(NSBundle.mainBundle.infoDictionary[@"UIInterfaceOrientation"]);
    if(OrientationBit(current) & mask) return current;
    for(id name in DeclaredOrientationNames()) {
        current = OrientationNamed(name);
        if(OrientationBit(current) & mask) return current;
    }
    return UIInterfaceOrientationPortrait;
}

struct RotationRequest {
    __unsafe_unretained UIWindow *window;
    __unsafe_unretained UIViewController *controller;
    UIInterfaceOrientation orientation;
    BOOL accepted;
    RotationRequest *previous;
};
thread_local RotationRequest *activeRequest;

BOOL QueryRotation(UIWindow *window, UIViewController *controller,
        UIInterfaceOrientation orientation) {
    if(!(OrientationBit(orientation) & DeclaredOrientations())) return NO;
    if(activeRequest && activeRequest->window == window && activeRequest->controller == controller &&
            activeRequest->orientation == orientation) return activeRequest->accepted;
    if(!startupFinished || !LC32NativeLegacyRotationCanCallGuest()) return NO;
    const BOOL accepted = ((BOOL (*)(id, SEL, UIInterfaceOrientation))objc_msgSend)(controller,
        @selector(shouldAutorotateToInterfaceOrientation:), orientation);
    return accepted;
}

void UpdateWindow(UIWindow *window, UIInterfaceOrientation orientation,
        bool initialOnly) {
    if(!pthread_main_np() || !startupFinished) return;
    LC32LegacyRotationState *state = WindowState(window);
    if(state.sceneContainer == NativeRoot(window) &&
            state.manualOrientationController) {
        /* The shared canvas observer delivers this renderer's rotation event
         * on both SDK paths. This backend only restores the old portrait
         * window coordinates; querying here would deliver the event twice. */
        ((void (*)(id, SEL))objc_msgSend)(window,
            sel_registerName("_updateTransformLayer"));
        return;
    }
    UIViewController *controller = ControllerForWindow(window, true);
    if(!controller || !(OrientationBit(orientation) & DeclaredOrientations())) return;
    UIView *view = NativeView(controller);
    if(!view || NativeWindow(view) != window) return;
    const bool legacyPolicy = UsesLegacyRotationPolicy(object_getClass(controller));
    if(NativeRoot(window) && !legacyPolicy && !initialOnly) {
        // A modern-policy root is already a scene rotation client. A device
        // notification arrives during that scene transition, before its new
        // geometry has settled. Forcing a second window turn here races the
        // native client and can move it in the previous coordinate space.
        // Updating its backing here also competes with the inverse layer
        // rotation inside UIKit's animation transaction. Its own update/layout
        // callbacks synchronize that backing and fit the canvas. Retain the
        // one-time startup synchronization below for newly attached clients.
        state.initializedController = controller;
        return;
    }
    // Synchronize the portrait window extent before a guest rotation callback
    // sizes its renderer from UIScreen. A resume can also change its extent
    // without requesting a new turn. Modern physical turns returned above.
    ((void (*)(id, SEL))objc_msgSend)(window, sel_registerName("_updateTransformLayer"));
    if(!LC32NativeLegacyRotationCanCallGuest()) return;
    if(NativePresented(controller)) return;
    const bool initializing = state.initializedController != controller;
    if(initialOnly && !initializing) return;
    // Rootless legacy windows have no native rotation client yet. Once one is
    // registered, respect UIKit's presentation and rotation-lock decisions.
    if(NativeRoot(window) && nativeRotationQuery) {
        BOOL disabled = NO;
        if(!nativeRotationQuery(window,
                sel_registerName("_shouldAutorotateToInterfaceOrientation:checkForDismissal:isRotationDisabled:"),
                orientation, YES, &disabled) || disabled) return;
    }

    BOOL accepted = !legacyPolicy ||
        QueryRotation(window, controller, orientation);
    if(ControllerForWindow(window, true) != controller) return;
    state.initializedController = controller;
    if(!NativeRoot(window)) {
        // A direct-window renderer owns its view hierarchy and may perform the
        // requested turn on its next repaint. Autopromoting it with the modern
        // root setter resizes its view/backing store before that repaint.
        // Keep it rootless and restore only the window's backing coordinates.
        ((void (*)(id, SEL))objc_msgSend)(window, sel_registerName("_updateTransformLayer"));
        return;
    }
    // A NO may still have queued a renderer-owned turn. Do not rotate the
    // controller before giving the game that choice.
    if(!accepted) {
        ((void (*)(id, SEL))objc_msgSend)(window, sel_registerName("_updateTransformLayer"));
        return;
    }
    RotationRequest request{window, controller, orientation, accepted, activeRequest};
    activeRequest = &request;
    @try {
        // Synchronize the newly registered rotation client with the window.
        // Unlike the old force-rotation API this is also valid for a window
        // whose scene owns orientation. It leaves Classic Mode to UIKit.
        SEL rotate = sel_registerName("_updateToInterfaceOrientation:duration:force:");
        if([window respondsToSelector:rotate]) {
            // A window may already have the scene's orientation before the
            // game attaches its controller. UIKit then only lays out the new
            // client, without a will/did pair. Supply that initial lifecycle
            // before the next guest frame can perform a competing manual turn.
            SEL current = sel_registerName("interfaceOrientation");
            bool initialSync = initializing &&
                ((UIInterfaceOrientation (*)(id, SEL))objc_msgSend)(window, current) == orientation;
            if(initialSync) [controller willRotateToInterfaceOrientation:orientation duration:0];
            ((void (*)(id, SEL, UIInterfaceOrientation, NSTimeInterval, BOOL))objc_msgSend)(
                window, rotate, orientation, 0, YES);
            if(initialSync) [controller didRotateFromInterfaceOrientation:orientation];
        } else {
            [UIViewController attemptRotationToDeviceOrientation];
        }
    } @finally {
        activeRequest = request.previous;
    }
}

void UpdateWindows(UIInterfaceOrientation orientation, bool initialOnly) {
    NSMutableSet<UIWindow *> *windows = [NSMutableSet set];
    for(UIViewController *controller in Controllers().allObjects) {
        UIView *view = NativeView(controller);
        UIWindow *window = view ? NativeWindow(view) : nil;
        if(window) [windows addObject:window];
    }
    for(UIWindow *window in windows) UpdateWindow(window, orientation, initialOnly);
}

void Swizzle(Class cls, SEL original, SEL replacement) {
    Method method = class_getInstanceMethod(cls, original);
    if(!method) {
        NSLog(@"LC32: %s not found", sel_getName(original));
        return;
    }
    method_exchangeImplementations(method, class_getInstanceMethod(cls, replacement));
}
} // namespace

extern "C" bool LC32LegacyRendererUsesNativeInitialOrientation(Class cls) {
    if(!cls || UsesLegacyRotationPolicy(cls) ||
            class_getMethodImplementation(cls, @selector(supportedInterfaceOrientations)) ==
                class_getMethodImplementation(UIViewController.class,
                    @selector(supportedInterfaceOrientations))) return false;
    // A renderer with its own rotation lifecycle can queue a manual turn or
    // require initialized engine state. Keep that lifecycle deferred as before.
    const SEL callbacks[] = {
        @selector(willRotateToInterfaceOrientation:duration:),
        @selector(willAnimateRotationToInterfaceOrientation:duration:),
        @selector(didRotateFromInterfaceOrientation:),
        @selector(viewWillTransitionToSize:withTransitionCoordinator:),
        @selector(preferredInterfaceOrientationForPresentation),
    };
    for(SEL callback : callbacks) {
        if(class_getMethodImplementation(cls, callback) !=
                class_getMethodImplementation(UIViewController.class, callback)) {
            return false;
        }
    }
    return true;
}

extern "C" bool LC32NativeLegacyRotationEnabled(void) {
    static const bool enabled = [] {
        const char *disabled = getenv("LC32_DISABLE_UIKIT_COMPATIBILITY");
        return !(disabled && strcmp(disabled, "1") == 0) &&
            !dyld_program_sdk_at_least({2, 0x00080000});
    }();
    return enabled;
}

extern "C" UIViewController *LC32NativeLegacyRotationDirectController(
        UIWindow *window) {
    if(!window || NativeRoot(window)) return nil;
    UIViewController *controller = ControllerForWindow(window, true);
    if(!controller || !RegisteredClass(object_getClass(controller))) return nil;
    return controller;
}

extern "C" void LC32PrepareNativeLegacyRotationClass(Class cls) {
    if(!cls || (!LC32NativeLegacyRotationEnabled() &&
            !LC32UIKitLegacyCompatibilityEnabled())) return;
    objc_setAssociatedObject((id)cls, RegisteredClassKey, @YES,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if(!LC32NativeLegacyRotationEnabled()) return;
    // Modern rotation policy arrived in iOS 6, before the iOS 8 geometry
    // change. Those guest controllers still need portrait backing coordinates
    // and the deprecated will/did lifecycle, but not legacy policy queries.
    if(!UsesLegacyRotationPolicy(cls)) return;
    class_addMethod(cls, @selector(supportedInterfaceOrientations),
        (IMP)LegacySupportedOrientations, method_getTypeEncoding(class_getInstanceMethod(
            UIViewController.class, @selector(supportedInterfaceOrientations))));
    SEL preferred = @selector(preferredInterfaceOrientationForPresentation);
    if(class_getMethodImplementation(cls, preferred) ==
            class_getMethodImplementation(UIViewController.class, preferred))
        class_addMethod(cls, preferred, (IMP)LegacyPreferredOrientation,
            method_getTypeEncoding(class_getInstanceMethod(UIViewController.class, preferred)));
}

extern "C" void LC32NativeLegacyRotationAdoptDirectRenderer(
        UIWindow *window, UIViewController *controller) {
    if(!window || !controller || NativeRoot(window) != controller) return;
    objc_setAssociatedObject(controller, DirectRendererOrientationKey,
        @0, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [Controllers() addObject:controller];
}

extern "C" void LC32NativeLegacyRotationAdoptSceneContainer(UIWindow *window,
        UIViewController *container, UIViewController *rendererController) {
    if(!LC32NativeLegacyRotationEnabled() || !window || !container ||
            NativeRoot(window) != container) return;
    LC32LegacyRotationState *state = WindowState(window);
    state.sceneContainer = container;
    state.manualOrientationController = rendererController;
    state.initializedController = container;
    objc_setAssociatedObject(container, SceneContainerKey,
        @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [Controllers() addObject:container];
    /* The native container is resized into landscape by old-SDK UIKit too.
     * Give it the same portrait backing setup as a registered guest root. */
    ((void (*)(id, SEL))objc_msgSend)(window,
        sel_registerName("_updateTransformLayer"));
}

extern "C" NSArray<UIWindow *> *LC32FinishNativeLegacyRotationStartup(void) {
    startupFinished = true;
    if(!LC32NativeLegacyRotationEnabled()) return @[];
    NSMutableArray<UIWindow *> *updatedWindows = [NSMutableArray array];
    for(UIViewController *controller in Controllers().allObjects) {
        NSNumber *derived = objc_getAssociatedObject(
            controller, DirectRendererOrientationKey);
        if(!derived) continue;
        UIView *view = NativeView(controller);
        UIWindow *window = view ? NativeWindow(view) : nil;
        if(!window || NativeRoot(window) != controller) continue;

        UIInterfaceOrientationMask mask = 0;
        // Only a direct GL root explicitly adopted from an old window gets
        // this one-time query, after the guest has finished initialization.
        // Ordinary legacy controllers keep the side-effect-free plist policy.
        const UIInterfaceOrientation orientations[] = {
                UIInterfaceOrientationPortrait,
                UIInterfaceOrientationPortraitUpsideDown,
                UIInterfaceOrientationLandscapeLeft,
                UIInterfaceOrientationLandscapeRight,
        };
        for(UIInterfaceOrientation orientation : orientations) {
            if(QueryRotation(window, controller, orientation)) {
                mask |= OrientationBit(orientation);
            }
        }
        if(!mask) continue;
        objc_setAssociatedObject(controller, DirectRendererOrientationKey,
            @(mask), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [updatedWindows addObject:window];
    }
    UpdateWindows(PreferredOrientation(), true);
    return updatedWindows;
}

extern "C" void LC32FitNativeLegacyRendererCanvas(UIWindow *window) {
    if(!window || !pthread_main_np()) return;
    UIViewController *controller = NativeRoot(window);
    if(!controller || !RegisteredClass(object_getClass(controller)) ||
            UIDevice.currentDevice.userInterfaceIdiom !=
                UIUserInterfaceIdiomPhone) return;
    static const BOOL requestsClassicMode =
        LC32BundleRequestsClassicMode(NSBundle.mainBundle);
    static const BOOL requestsFullscreen =
        [NSBundle.mainBundle.infoDictionary[@"UIStatusBarHidden"] boolValue];
    if(!requestsClassicMode && !requestsFullscreen) return;
    const UIInterfaceOrientationMask orientations = DeclaredOrientations();
    const bool landscapeOnly = orientations &&
        !(orientations & ~UIInterfaceOrientationMaskLandscape);
    const bool portraitOnly = orientations &&
        (orientations & UIInterfaceOrientationMaskPortrait) &&
        !(orientations & UIInterfaceOrientationMaskLandscape);
    const bool classicPortraitRenderer = requestsClassicMode &&
        requestsFullscreen && portraitOnly;
    const bool nativeLegacyRotation = LC32NativeLegacyRotationEnabled();
    if(!nativeLegacyRotation && !classicPortraitRenderer) return;
    /* A fullscreen GL controller can have a narrower authored
     * rotation policy than its bundle declares. In particular, a controller
     * with modern landscape methods and an all-orientations plist still needs
     * its drawable fitted before the engine samples the view size. The
     * direct OpenGL view and window geometry checks below establish that
     * canvas; only an authored modern policy can be queried at attachment. */
    if(!classicPortraitRenderer && !landscapeOnly && !requestsFullscreen) {
        return;
    }

    UIView *view = NativeView(controller);
    UIView *parent = view ? NativeSuperview(view) : nil;
    if(!parent || NativeWindow(view) != window) return;
    if(!classicPortraitRenderer && parent != window) return;
    if(!IsNativeOpenGLESView(view)) return;

    /* Only UIView's base IMPs are safe here: a scene callback may have no
     * guest CPU context, and a mirrored renderer can override these methods. */
    using AutoresizingSetter = void (*)(id, SEL, UIViewAutoresizing);
    static AutoresizingSetter setAutoresizing = (AutoresizingSetter)
        class_getMethodImplementation(UIView.class, @selector(setAutoresizingMask:));
    const CGRect viewport = LC32NativeViewBounds(window);
    const CGRect currentBounds = LC32NativeViewBounds(view);
    CGAffineTransform transform = LC32NativeViewTransform(view);
    LC32LegacyRotationState *state = WindowState(window);
    constexpr CGFloat epsilon = 0.001;
    if(state.fittingCanvas) return;

    if(classicPortraitRenderer) {
        // Root attachment precedes the guest's final frame assignment. Capture
        // its authored bounds at the startup idle boundary, after those writes.
        // An earlier snapshot would mistake the guest's own inset for a resize.
        if(!startupFinished) return;
        if(state.portraitCanvasYielded && state.canvasController == controller) {
            return;
        }
        if(!(viewport.size.height > viewport.size.width) ||
                !(currentBounds.size.height > currentBounds.size.width)) {
            return;
        }
        if((!state.portraitCanvas || state.canvasController != controller) &&
                CGAffineTransformIsIdentity(transform) &&
                fabs(currentBounds.size.width - viewport.size.width) < 0.5 &&
                currentBounds.size.height <= viewport.size.height + 0.5) {
            state.canvasController = controller;
            state.canvasBounds = currentBounds;
            state.portraitInitialViewport = viewport;
            // Modern UIKit can insert a presentation view above the root.
            // Save placement in window coordinates, then convert each fit
            // back into its current parent's coordinates before applying it.
            state.portraitInitialCenter = LC32NativeConvertViewPoint(
                window, LC32NativeViewCenter(view), parent);
            state.portraitAppliedTransform = CGAffineTransformIdentity;
            state.portraitCanvas = YES;
            state.portraitCanvasYielded = NO;
            setAutoresizing(view, @selector(setAutoresizingMask:),
                UIViewAutoresizingNone);
        }
        if(state.portraitCanvas && state.canvasController == controller) {
            LC32ObserveClassicCanvasScene(window.windowScene);
            if(!CGAffineTransformIsIdentity(transform) &&
                     !CGAffineTransformEqualToTransform(
                         transform, state.portraitAppliedTransform)) {
                return;
            }

            CGAffineTransform desiredTransform;
            CGPoint desiredCenter;
            if(!LC32CalculateCanvasFit(state.portraitInitialViewport, viewport,
                    CGAffineTransformIdentity, INFINITY,
                    &desiredTransform, &desiredCenter)) {
                return;
            }
            // Fit the original window coordinate space, preserving any inset
            // the guest chose for its renderer within that window.
            desiredCenter.x += desiredTransform.a *
                (state.portraitInitialCenter.x -
                    CGRectGetMidX(state.portraitInitialViewport));
            desiredCenter.y += desiredTransform.d *
                (state.portraitInitialCenter.y -
                    CGRectGetMidY(state.portraitInitialViewport));
            desiredCenter = LC32NativeConvertViewPoint(
                parent, desiredCenter, window);

            state.fittingCanvas = YES;
            @try {
                // UIKit can assign a new root frame after scene fitting has
                // already run. Restore the captured guest surface before
                // fitting presentation; explicit guest writes yield above.
                LC32ApplyNativeCanvasGeometry(view, state.canvasBounds,
                    desiredCenter, desiredTransform);
                state.portraitAppliedTransform = desiredTransform;
            } @finally {
                state.fittingCanvas = NO;
            }
            return;
        }
        return;
    }

    if(!(viewport.size.width > 0) ||
            !(viewport.size.height > viewport.size.width) ||
            !isfinite(viewport.size.width) || !isfinite(viewport.size.height) ||
            !isfinite(transform.a) || !isfinite(transform.b) ||
            !isfinite(transform.c) || !isfinite(transform.d) ||
            !isfinite(transform.tx) || !isfinite(transform.ty) ||
            fabs(transform.tx) > epsilon || fabs(transform.ty) > epsilon) return;
    const BOOL quarterTurn = IsNativeQuarterTurn(transform);
    const BOOL portraitLayout = CGAffineTransformIsIdentity(transform) &&
        currentBounds.size.height > currentBounds.size.width;
    if(!quarterTurn && !portraitLayout) return;

    if(requestsClassicMode && state.canvasController != controller) {
        /* Fullscreen guests can still receive applicationFrame's old bar
         * inset under a spoofed SDK, even when the scene reports a hidden bar.
         * The launch window defines their full canvas. Establish it during
         * root attachment, before the engine creates objects from its size;
         * waiting for a full-sized guest view would never capture this case. */
        const CGSize expectedSize = quarterTurn
            ? CGSizeMake(viewport.size.height, viewport.size.width)
            : viewport.size;
        if(!isfinite(currentBounds.size.width) ||
                !isfinite(currentBounds.size.height) ||
                fabs(currentBounds.size.width - expectedSize.width) >= 0.5 ||
                !(currentBounds.size.height > 0) ||
                currentBounds.size.height > expectedSize.height + 0.5 ||
                (!requestsFullscreen && (portraitLayout ||
                    fabs(currentBounds.size.height - expectedSize.height) >= 0.5))) {
            return;
        }
        state.canvasController = controller;
        state.canvasBounds = CGRectMake(currentBounds.origin.x,
            currentBounds.origin.y, viewport.size.height, viewport.size.width);
    }
    if(requestsClassicMode && state.canvasController == controller) {
        LC32ObserveClassicCanvasScene(window.windowScene);
    }

    BOOL initializeOrientation = NO;
    UIInterfaceOrientation initialOrientation = UIInterfaceOrientationUnknown;
    const UIInterfaceOrientationMask rendererOrientations = !startupFinished
        ? LC32NativeLegacyRendererSupportedOrientations(controller) : 0;
    const BOOL rendererLandscapeOnly = rendererOrientations &&
        !(rendererOrientations & ~UIInterfaceOrientationMaskLandscape);
    if((landscapeOnly || rendererLandscapeOnly) && !startupFinished &&
            requestsFullscreen && portraitLayout &&
            (rendererLandscapeOnly ||
             LC32LegacyRendererUsesNativeInitialOrientation(object_getClass(controller)))) {
        // Scene activation is asynchronous on a modern host. UIKit can
        // briefly attach a landscape renderer as portrait, even when its
        // controller later selects landscape from a broader bundle policy.
        // Engines can construct their first scene from those portrait bounds.
        // Use the root controller's cached policy, which may be narrower than
        // its bundle policy, and UIKit's matching legacy view transform.
        SEL selector = sel_registerName("_viewTransformForInterfaceOrientation:");
        using OrientationTransformGetter = CGAffineTransform (*)(id, SEL,
            UIInterfaceOrientation);
        static OrientationTransformGetter getOrientationTransform =
            (OrientationTransformGetter)class_getMethodImplementation(
                UIWindow.class, selector);
        initialOrientation = PreferredOrientation(rendererOrientations);
        const CGAffineTransform initialTransform = getOrientationTransform
            ? getOrientationTransform(window, selector, initialOrientation)
            : CGAffineTransformIdentity;
        if(IsNativeQuarterTurn(initialTransform)) {
            transform = initialTransform;
            initializeOrientation = YES;
        }
    }

    CGRect desiredBounds = requestsClassicMode ? state.canvasBounds :
        CGRectMake(currentBounds.origin.x, currentBounds.origin.y,
            viewport.size.height, viewport.size.width);
    if(portraitLayout && !initializeOrientation) {
        desiredBounds.size = CGSizeMake(desiredBounds.size.height,
            desiredBounds.size.width);
    }

    state.fittingCanvas = YES;
    @try {
        if(requestsClassicMode) {
            setAutoresizing(view, @selector(setAutoresizingMask:), UIViewAutoresizingNone);
        }
        /* Center in portrait backing coordinates. After the initial native
         * pose, UIKit retains ownership of rotation; native touch conversion
         * follows the same view transform as the renderer. */
        LC32ApplyNativeCanvasGeometry(view, desiredBounds,
            CGPointMake(CGRectGetMidX(viewport), CGRectGetMidY(viewport)),
            transform, !initializeOrientation);
        if(initializeOrientation && state.startupCanvasController != controller) {
            state.startupCanvasController = controller;
        }
    } @finally {
        state.fittingCanvas = NO;
    }
}

extern "C" void LC32NativeLegacyRotationDidSetGuestViewGeometry(id object) {
    if(!startupFinished || !pthread_main_np() ||
            ![object isKindOfClass:UIView.class]) {
        return;
    }
    UIView *view = (UIView *)object;
    UIWindow *window = NativeWindow(view);
    LC32LegacyRotationState *state =
        objc_getAssociatedObject(window, WindowStateKey);
    if(!state.portraitCanvas || state.fittingCanvas ||
            state.portraitCanvasYielded ||
            NativeRoot(window) != state.canvasController ||
            NativeView(state.canvasController) != view) {
        return;
    }
    state.portraitCanvasYielded = YES;
}

static void PlaceNativeAlertToScene(UIWindow *window) {
    if(!window || window.hidden ||
            !LC32NativeAlertWindowUsesScenePolicy(window)) {
        return;
    }
    UIViewController *presented = NativePresented(NativeRoot(window));
    if(![presented isKindOfClass:UIAlertController.class] ||
            presented.isBeingPresented || presented.isBeingDismissed) {
        return;
    }
    UIView *alertView = NativeView(presented);
    UIView *parent = NativeSuperview(alertView);
    if(!parent || NativeWindow(alertView) != window) return;

    const CGRect sceneBounds = window.windowScene.coordinateSpace.bounds;
    if(CGRectIsEmpty(sceneBounds)) return;
    const CGPoint sceneCenter = {
        CGRectGetMidX(sceneBounds), CGRectGetMidY(sceneBounds)
    };
    const CGPoint desiredCenter = LC32NativeConvertViewPoint(
        parent, sceneCenter, window);
    const CGAffineTransform alertTransform =
        LC32NativeViewTransform(alertView);
    const bool resetTurn = IsNativeQuarterTurn(alertTransform);
    if(!resetTurn && CGPointEqualToPoint(
            LC32NativeViewCenter(alertView), desiredCenter)) {
        return;
    }

    // The presentation is complete here. In a scene-owned alert window the
    // child needs no additional quarter turn, and its layout belongs at the
    // scene midpoint. Keep these changes in the same nonanimated transaction.
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    @try {
        [UIView performWithoutAnimation:^{
            if(resetTurn) {
                LC32NativeSetViewTransform(alertView,
                    CGAffineTransformIdentity);
            }
            LC32NativeSetViewCenter(alertView, desiredCenter);
        }];
    } @finally {
        [CATransaction commit];
    }
}

static void FitNativeAlertToScene(UIWindow *window) {
    UIWindowScene *scene = window.windowScene;
    if(!scene || !LC32IsNativeAlertPresenterWindow(window)) return;

    const CGRect sceneBounds = scene.coordinateSpace.bounds;
    if(CGRectIsEmpty(sceneBounds)) return;
    const CGPoint sceneCenter = {
        CGRectGetMidX(sceneBounds), CGRectGetMidY(sceneBounds)
    };

    // The alert belongs to the scene, but the old-SDK window rotation path
    // leaves its window in portrait coordinates. Give its native root the
    // scene's coordinates after UIKit's rotation callback has completed.
    LC32ApplyNativeCanvasGeometry(window, sceneBounds, sceneCenter,
        CGAffineTransformIdentity);
    UIView *rootView = NativeView(NativeRoot(window));
    if(rootView) {
        LC32ApplyNativeCanvasGeometry(rootView, sceneBounds, sceneCenter,
            CGAffineTransformIdentity);
        [rootView setNeedsLayout];
    }
    UIViewController *presented = NativePresented(NativeRoot(window));
    UIPresentationController *presentation = presented.presentationController;
    UIView *container = presentation.containerView;
    UIView *alertView = NativeView(presented);
    if(container && NativeWindow(container) == window) {
        // The presentation container can keep the portrait extent even after
        // the alert window and root have turned. Its alert is then centered
        // around the old portrait midpoint and clipped in landscape.
        LC32ApplyNativeCanvasGeometry(container, sceneBounds, sceneCenter,
            CGAffineTransformIdentity);
        [presentation containerViewWillLayoutSubviews];
        [container setNeedsLayout];
        [container layoutIfNeeded];
    }
    [rootView layoutIfNeeded];
    PlaceNativeAlertToScene(window);
    LC32ScheduleNativeLegacyAlertPlacement(window);
}

extern "C" void LC32ScheduleNativeLegacyAlertPlacement(UIWindow *window) {
    if(!window || !pthread_main_np() ||
            !LC32NativeAlertWindowUsesScenePolicy(window)) {
        return;
    }
    LC32LegacyRotationState *state = WindowState(window);
    if(state.alertPlacementScheduled) return;
    state.alertPlacementScheduled = YES;

    __weak UIWindow *pendingWindow = window;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *target = pendingWindow;
        if(!target) return;
        WindowState(target).alertPlacementScheduled = NO;
        PlaceNativeAlertToScene(target);
    });
}

extern "C" bool LC32SynchronizeNativeLegacyAlertWindow(UIWindow *window) {
    if(!LC32NativeLegacyRotationEnabled() || !pthread_main_np() ||
            !LC32IsNativeAlertPresenterWindow(window)) {
        return false;
    }
    TrackNativeAlertWindow(window);
    LC32NativeAlertSceneScope scenePolicy(window);
    UIViewController *controller = NativeRoot(window);
    UIWindowScene *scene = window.windowScene;
    UIInterfaceOrientation orientation = scene.interfaceOrientation;
    LC32LegacyRotationState *state = WindowState(window);
    const unsigned skipState = (!controller ? 1u : 0u) |
        (!scene ? 2u : 0u) | (window.hidden ? 4u : 0u) |
        (!OrientationBit(orientation) ? 8u : 0u);
    if(skipState) {
        state.alertSyncSkipState = skipState;
        return true;
    }
    state.alertSyncSkipState = 0;
    if(state.synchronizingAlertOrientation) return true;
    if(state.alertOrientationController == controller &&
            state.alertOrientation == orientation) {
        ((void (*)(id, SEL))objc_msgSend)(window,
            sel_registerName("_updateTransformLayer"));
        FitNativeAlertToScene(window);
        return true;
    }
    SEL rotate = sel_registerName("_updateToInterfaceOrientation:duration:force:");
    if(![window respondsToSelector:rotate]) return true;

    // The alert can be attached while the game still has a portrait scene.
    // Its native rotation client must receive the committed scene turn too;
    // changing the backing layer alone only centers a sideways alert. Record
    // completed updates so a native turn and this observer stay idempotent.
    state.synchronizingAlertOrientation = YES;
    @try {
        ((void (*)(id, SEL, UIInterfaceOrientation, NSTimeInterval, BOOL))objc_msgSend)(
            window, rotate, orientation, 0, YES);
        RememberNativeAlertOrientation(window, orientation);
    } @finally {
        state.synchronizingAlertOrientation = NO;
    }
    return true;
}

extern "C" void LC32SynchronizeNativeLegacyAlertWindows(UIWindowScene *scene) {
    if(!scene || !LC32NativeLegacyRotationEnabled() || !pthread_main_np()) return;
    // Native presentation windows need not appear in the public window list.
    // Keep their own scene association authoritative, including scene moves.
    for(UIWindow *window in NativeAlertWindows().allObjects) {
        if(window.windowScene == scene) {
            LC32SynchronizeNativeLegacyAlertWindow(window);
        }
    }
}

static void FitControllerCanvas(UIViewController *controller) {
    if(!RegisteredClass(object_getClass(controller))) return;
    UIView *view = NativeView(controller);
    UIWindow *window = view ? NativeWindow(view) : nil;
    LC32FitNativeLegacyRendererCanvas(window);
}

@interface UIPresentationController (LC32NativeAlertPlacement)
- (void)lc32_rotationContainerViewDidLayoutSubviews;
@end

@implementation UIPresentationController (LC32NativeAlertPlacement)
- (void)lc32_rotationContainerViewDidLayoutSubviews {
    [self lc32_rotationContainerViewDidLayoutSubviews];
    if(![self.presentedViewController isKindOfClass:UIAlertController.class]) {
        return;
    }
    PlaceNativeAlertToScene(NativeWindow(self.containerView));
}
@end

@interface UIViewController (LC32NativeLegacyRotation)
- (void)lc32_rotationViewWillLayoutSubviews;
- (void)lc32_rotationViewDidLayoutSubviews;
- (void)lc32_rotationViewDidMoveToWindow:(UIWindow *)window shouldAppearOrDisappear:(BOOL)appear;
- (void)lc32_rotationWindow:(UIWindow *)window willRotateToInterfaceOrientation:(UIInterfaceOrientation)orientation
    duration:(NSTimeInterval)duration newSize:(CGSize)size;
- (void)lc32_rotationWindow:(UIWindow *)window didRotateFromInterfaceOrientation:(UIInterfaceOrientation)orientation
    oldSize:(CGSize)size;
@end

@implementation UIViewController (LC32NativeLegacyRotation)
- (void)lc32_rotationViewWillLayoutSubviews {
    [self lc32_rotationViewWillLayoutSubviews];
    FitControllerCanvas(self);
}

- (void)lc32_rotationViewDidLayoutSubviews {
    [self lc32_rotationViewDidLayoutSubviews];
    UIView *view = NativeView(self);
    UIWindow *window = view ? NativeWindow(view) : nil;
    if(LC32IsNativeAlertPresenterWindow(window)) {
        // Correct the alert in this layout transaction so the next frame
        // cannot present UIKit's stale portrait placement first.
        PlaceNativeAlertToScene(window);
        LC32ScheduleNativeLegacyAlertPlacement(window);
        return;
    }
    FitControllerCanvas(self);
}

- (void)lc32_rotationViewDidMoveToWindow:(UIWindow *)window shouldAppearOrDisappear:(BOOL)appear {
    [self lc32_rotationViewDidMoveToWindow:window shouldAppearOrDisappear:appear];
    if(!window || !pthread_main_np()) return;
    const bool nativeAlert = LC32IsNativeAlertPresenterWindow(window);
    if(nativeAlert) {
        LC32ObserveClassicCanvasScene(window.windowScene);
    } else {
        if(!RegisteredClass(object_getClass(self))) return;
        [Controllers() addObject:self];
        LC32FitNativeLegacyRendererCanvas(window);
        if(!startupFinished) return;
    }
    // Revalidate deferred attachment work; a replaced or detached controller
    // must not initialize the next owner of its old window.
    __weak UIViewController *pendingController = self;
    __weak UIWindow *pendingWindow = window;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *controller = pendingController;
        UIWindow *target = pendingWindow;
        if(!controller || !target) return;
        if(nativeAlert) {
            // A native alert attaches its presented child as well as its
            // presenter. The child is not the window's root controller.
            if(NativeWindow(NativeView(controller)) != target) return;
            LC32SynchronizeNativeLegacyAlertWindow(target);
            return;
        }
        if(ControllerForWindow(target, true) != controller) return;
        UpdateWindow(target, PreferredOrientation(), true);
    });
}

- (void)lc32_rotationWindow:(UIWindow *)window willRotateToInterfaceOrientation:(UIInterfaceOrientation)orientation
        duration:(NSTimeInterval)duration newSize:(CGSize)size {
    [self lc32_rotationWindow:window willRotateToInterfaceOrientation:orientation duration:duration newSize:size];
    if(RegisteredClass(object_getClass(self)) && startupFinished && LC32NativeLegacyRotationCanCallGuest())
        [self willRotateToInterfaceOrientation:orientation duration:duration];
}

- (void)lc32_rotationWindow:(UIWindow *)window didRotateFromInterfaceOrientation:(UIInterfaceOrientation)orientation
        oldSize:(CGSize)size {
    [self lc32_rotationWindow:window didRotateFromInterfaceOrientation:orientation oldSize:size];
    if(RegisteredClass(object_getClass(self)) && startupFinished && LC32NativeLegacyRotationCanCallGuest())
        [self didRotateFromInterfaceOrientation:orientation];
}
@end

@interface UIWindow (LC32NativeLegacyRotation)
- (void)lc32_updateToInterfaceOrientation:(UIInterfaceOrientation)orientation
    duration:(NSTimeInterval)duration force:(BOOL)force;
- (void)lc32_configureRootLayer:(CALayer *)root sceneTransformLayer:(CALayer *)scene
    transformLayer:(CALayer *)transform;
- (BOOL)lc32_windowOwnsInterfaceOrientation;
- (BOOL)lc32_windowOwnsInterfaceOrientationTransform;
- (BOOL)lc32_shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation
    checkForDismissal:(BOOL)check isRotationDisabled:(BOOL *)disabled;
+ (void)lc32_nativeLegacyDeviceOrientationChanged:(NSNotification *)notification;
+ (void)lc32_nativeLegacyApplicationDidBecomeActive:(NSNotification *)notification;
@end

@implementation UIWindow (LC32NativeLegacyRotation)
- (void)lc32_updateToInterfaceOrientation:(UIInterfaceOrientation)orientation
        duration:(NSTimeInterval)duration force:(BOOL)force {
    const bool nativeAlert = LC32IsNativeAlertPresenterWindow(self);
    LC32NativeAlertSceneScope scenePolicy(nativeAlert ? self : nil);
    // Scene-owned windows do not run the old backing update as part of their
    // view rotation. Sync its extent before resizing the client and its root
    // transform afterwards, including a same-orientation scene-size change.
    // Old-policy rootless controllers retain their renderer-owned turn
    // lifecycle. Controllers without that policy only need backing updates.
    UIViewController *backingController = ControllerForWindow(self, true);
    BOOL legacy = backingController && (NativeRoot(self) ||
        !UsesLegacyRotationPolicy(object_getClass(backingController)));
    SEL refresh = sel_registerName("_updateTransformLayer");
    if(legacy) ((void (*)(id, SEL))objc_msgSend)(self, refresh);
    [self lc32_updateToInterfaceOrientation:orientation duration:duration force:force];
    if(legacy) ((void (*)(id, SEL))objc_msgSend)(self, refresh);
    LC32FitNativeLegacyRendererCanvas(self);
    if(nativeAlert) {
        RememberNativeAlertOrientation(self, orientation);
        FitNativeAlertToScene(self);
    }
}
- (void)lc32_configureRootLayer:(CALayer *)root sceneTransformLayer:(CALayer *)scene
        transformLayer:(CALayer *)transform {
    LC32NativeAlertSceneScope scenePolicy(self);
    // A presented overlay suspends the renderer's rotation queries, not the
    // backing coordinate system of the window beneath it.
    if(!ControllerForWindow(self, true)) {
        [self lc32_configureRootLayer:root sceneTransformLayer:scene transformLayer:transform];
        return;
    }
    // The pre-iOS-8 compositor rotates the client in portrait window space.
    // Scene-owned windows now skip its inverse root-layer rotation and retain
    // landscape backing bounds, leaving that client sideways and clipped.
    // Select UIKit's original backing-layer setup only inside this operation;
    // the scene must still own orientation requests and events everywhere else.
    UIWindow *previous = configuringLegacyWindow;
    configuringLegacyWindow = self;
    @try {
        [self lc32_configureRootLayer:root sceneTransformLayer:scene transformLayer:transform];
    } @finally {
        configuringLegacyWindow = previous;
    }
    LC32FitNativeLegacyRendererCanvas(self);
}
- (BOOL)lc32_windowOwnsInterfaceOrientation {
    return configuringLegacyWindow == self || [self lc32_windowOwnsInterfaceOrientation];
}
- (BOOL)lc32_windowOwnsInterfaceOrientationTransform {
    return configuringLegacyWindow == self || [self lc32_windowOwnsInterfaceOrientationTransform];
}
+ (void)load {
    if(!LC32NativeLegacyRotationEnabled() &&
            !LC32UIKitLegacyCompatibilityEnabled()) return;
    // Scene root layout can overwrite a captured portrait drawable with
    // either SDK. These callbacks only fit registered guest roots and never
    // change UIKit's orientation policy on the modern process-SDK path.
    Swizzle(UIViewController.class,
        @selector(viewWillLayoutSubviews),
        @selector(lc32_rotationViewWillLayoutSubviews));
    Swizzle(UIViewController.class,
        @selector(viewDidLayoutSubviews),
        @selector(lc32_rotationViewDidLayoutSubviews));
    if(!LC32NativeLegacyRotationEnabled()) return;
    Swizzle(UIPresentationController.class,
        @selector(containerViewDidLayoutSubviews),
        @selector(lc32_rotationContainerViewDidLayoutSubviews));
    Swizzle(self, sel_registerName("_updateToInterfaceOrientation:duration:force:"),
        @selector(lc32_updateToInterfaceOrientation:duration:force:));
    Swizzle(self, sel_registerName("_configureRootLayer:sceneTransformLayer:transformLayer:"),
        @selector(lc32_configureRootLayer:sceneTransformLayer:transformLayer:));
    Swizzle(self, sel_registerName("_windowOwnsInterfaceOrientation"),
        @selector(lc32_windowOwnsInterfaceOrientation));
    Swizzle(self, sel_registerName("_windowOwnsInterfaceOrientationTransform"),
        @selector(lc32_windowOwnsInterfaceOrientationTransform));
    Swizzle(UIViewController.class,
        sel_registerName("viewDidMoveToWindow:shouldAppearOrDisappear:"),
        @selector(lc32_rotationViewDidMoveToWindow:shouldAppearOrDisappear:));
    // The scene-era callbacks retained native bookkeeping but dropped the
    // deprecated public callbacks expected by pre-iOS-6 guest controllers.
    Swizzle(UIViewController.class,
        sel_registerName("window:willRotateToInterfaceOrientation:duration:newSize:"),
        @selector(lc32_rotationWindow:willRotateToInterfaceOrientation:duration:newSize:));
    Swizzle(UIViewController.class,
        sel_registerName("window:didRotateFromInterfaceOrientation:oldSize:"),
        @selector(lc32_rotationWindow:didRotateFromInterfaceOrientation:oldSize:));
    nativeRotationQuery = (NativeRotationQuery)class_getMethodImplementation(self,
        sel_registerName("_shouldAutorotateToInterfaceOrientation:checkForDismissal:isRotationDisabled:"));
    Swizzle(self,
        sel_registerName("_shouldAutorotateToInterfaceOrientation:checkForDismissal:isRotationDisabled:"),
        @selector(lc32_shouldAutorotateToInterfaceOrientation:checkForDismissal:isRotationDisabled:));
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(lc32_nativeLegacyDeviceOrientationChanged:)
        name:UIDeviceOrientationDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(lc32_nativeLegacyApplicationDidBecomeActive:)
        name:UIApplicationDidBecomeActiveNotification object:nil];
}

- (BOOL)lc32_shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation
        checkForDismissal:(BOOL)check isRotationDisabled:(BOOL *)disabled {
    BOOL allowed = [self lc32_shouldAutorotateToInterfaceOrientation:orientation
        checkForDismissal:check isRotationDisabled:disabled];
    UIViewController *controller = ControllerForWindow(self);
    if(!allowed || !controller) return allowed;
    return QueryRotation(self, controller, orientation);
}

+ (void)lc32_nativeLegacyDeviceOrientationChanged:(__unused NSNotification *)notification {
    // The enums use the same values (the landscape *names* are opposite).
    UIInterfaceOrientation orientation = (UIInterfaceOrientation)UIDevice.currentDevice.orientation;
    if(OrientationBit(orientation)) UpdateWindows(orientation, false);
}

+ (void)lc32_nativeLegacyApplicationDidBecomeActive:
        (__unused NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        /* An initialized controller gets a backing refresh without another
         * deprecated rotation lifecycle. This also handles a resume which
         * changes the scene size without changing its orientation. */
        UpdateWindows(PreferredOrientation(), true);
    });
}
@end
