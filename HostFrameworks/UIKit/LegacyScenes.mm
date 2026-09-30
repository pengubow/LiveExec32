#import "LC32LegacyScenes.h"
#import "LC32LegacyRotation.h"
#import "bridge.h"
#import <objc/message.h>
#import <objc/runtime.h>
#include <limits.h>
#include <pthread.h>

@interface LC32LegacySceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic) BOOL hasActivated;
@property(nonatomic) BOOL active;
@property(nonatomic) BOOL backgrounded;
@end

namespace {
bool legacySceneLifecycleEnabled;
const void *classicSceneGeometryOriginalKey = &classicSceneGeometryOriginalKey;
const void *classicSceneGeometryInstalledKey = &classicSceneGeometryInstalledKey;
const void *classicSceneObservedBoundsKey = &classicSceneObservedBoundsKey;
const void *classicSceneObservedOrientationKey = &classicSceneObservedOrientationKey;
enum class LegacySceneBridgeMode {
    Disabled,
    ModernAdapters,
};

LegacySceneBridgeMode SceneBridgeMode() {
    if(LC32UIKitLegacyCompatibilityEnabled()) {
        return LegacySceneBridgeMode::ModernAdapters;
    }
    return LegacySceneBridgeMode::Disabled;
}

using SetApplicationDelegate = void (*)(id, SEL, id<UIApplicationDelegate>);
SetApplicationDelegate originalSetApplicationDelegate;

void PrepareAssignedApplicationDelegate(id application, SEL selector,
        id<UIApplicationDelegate> delegate) {
    originalSetApplicationDelegate(application, selector, delegate);
    if(delegate) {
        LC32PrepareLegacySceneLifecycle(
            NSStringFromClass(object_getClass(delegate)));
    }
}

void ClassicCanvasSceneGeometryUpdated(id delegate, SEL selector,
        UIWindowScene *scene, id<UICoordinateSpace> previousCoordinateSpace,
        UIInterfaceOrientation previousInterfaceOrientation,
        UITraitCollection *previousTraitCollection) {
    Class delegateClass = object_getClass(delegate);
    NSNumber *saved = objc_getAssociatedObject(
        (id)delegateClass, classicSceneGeometryOriginalKey);
    if(saved) {
        using GeometryUpdated = void (*)(id, SEL, UIWindowScene *,
            id<UICoordinateSpace>, UIInterfaceOrientation, UITraitCollection *);
        GeometryUpdated original = reinterpret_cast<GeometryUpdated>(
            static_cast<uintptr_t>(saved.unsignedLongLongValue));
        original(delegate, selector, scene, previousCoordinateSpace,
            previousInterfaceOrientation, previousTraitCollection);
    }
    LC32UIKitRefitLegacyScene(scene);
}

void ObserveClassicCanvasRunLoop(CFRunLoopObserverRef,
        CFRunLoopActivity, void *) {
    for(UIScene *connectedScene in UIApplication.sharedApplication.connectedScenes) {
        if(![connectedScene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *scene = (UIWindowScene *)connectedScene;
        NSValue *previous = objc_getAssociatedObject(
            scene, classicSceneObservedBoundsKey);
        if(!previous || scene.delegate) continue;

        const CGRect bounds = scene.coordinateSpace.bounds;
        NSNumber *previousOrientation = objc_getAssociatedObject(
            scene, classicSceneObservedOrientationKey);
        UIInterfaceOrientation orientation = scene.interfaceOrientation;
        if(CGRectEqualToRect(previous.CGRectValue, bounds) &&
                previousOrientation.integerValue == orientation) continue;
        objc_setAssociatedObject(scene, classicSceneObservedBoundsKey,
            [NSValue valueWithCGRect:bounds], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(scene, classicSceneObservedOrientationKey,
            @(orientation), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        LC32UIKitRefitLegacyScene(scene);
    }
}

void ObserveClassicCanvasWithoutDelegate(UIWindowScene *scene) {
    if(objc_getAssociatedObject(scene, classicSceneObservedBoundsKey)) return;

    objc_setAssociatedObject(scene, classicSceneObservedBoundsKey,
        [NSValue valueWithCGRect:scene.coordinateSpace.bounds],
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(scene, classicSceneObservedOrientationKey,
        @(scene.interfaceOrientation), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CFRunLoopObserverRef observer = CFRunLoopObserverCreate(
            kCFAllocatorDefault,
            kCFRunLoopBeforeWaiting | kCFRunLoopExit, true, 0,
            ObserveClassicCanvasRunLoop, nullptr);
        if(!observer) return;
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, kCFRunLoopCommonModes);
        CFRelease(observer);
    });
}

NSHashTable<UIWindow *> *LegacySceneWindows() {
    static NSHashTable<UIWindow *> *windows;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        windows = [NSHashTable weakObjectsHashTable];
    });
    return windows;
}

void ForwardLegacyApplicationEvent(SEL selector) {
    if(SceneBridgeMode() != LegacySceneBridgeMode::ModernAdapters) return;
    UIApplication *application = UIApplication.sharedApplication;
    id<UIApplicationDelegate> delegate = application.delegate;
    if(!delegate || ![delegate respondsToSelector:selector]) return;
    using ApplicationEvent = void (*)(id, SEL, UIApplication *);
    reinterpret_cast<ApplicationEvent>(objc_msgSend)(
        delegate, selector, application);
}

UISceneConfiguration *LegacySceneConfiguration(id, SEL,
        UIApplication *, UISceneSession *session, UISceneConnectionOptions *) {
    UISceneConfiguration *configuration = [[UISceneConfiguration alloc]
        initWithName:@"LiveExec32 legacy scene" sessionRole:session.role];
    configuration.sceneClass = UIWindowScene.class;
    if([session.role isEqualToString:UIWindowSceneSessionRoleApplication]) {
        configuration.delegateClass = LC32LegacySceneDelegate.class;
    }
    return configuration;
}
}

extern "C" void LC32PrepareLegacySceneLifecycle(NSString *delegateClassName) {
    const LegacySceneBridgeMode mode = SceneBridgeMode();
    if(mode == LegacySceneBridgeMode::Disabled || !delegateClassName) return;
    Class delegateClass = NSClassFromString(delegateClassName);
    if(!delegateClass || ![(id)delegateClass isGuestClass] ||
            NSBundle.mainBundle.infoDictionary[@"UIApplicationSceneManifest"]) {
        return;
    }
    const SEL configurationSelector =
        @selector(application:configurationForConnectingSceneSession:options:);
    if(class_getInstanceMethod(delegateClass, configurationSelector)) return;
    const struct objc_method_description declaration = protocol_getMethodDescription(
        @protocol(UIApplicationDelegate), configurationSelector, NO, YES);
    if(!declaration.types || !class_addMethod(delegateClass,
            configurationSelector, (IMP)LegacySceneConfiguration, declaration.types)) {
        return;
    }
    legacySceneLifecycleEnabled = true;
}

extern "C" void LC32InstallLegacySceneDelegatePreparation(void) {
    if(SceneBridgeMode() == LegacySceneBridgeMode::Disabled) return;
    Method setter = class_getInstanceMethod(UIApplication.class,
        @selector(setDelegate:));
    if(!setter) return;
    IMP current = method_getImplementation(setter);
    if(current == reinterpret_cast<IMP>(PrepareAssignedApplicationDelegate)) {
        return;
    }
    originalSetApplicationDelegate = reinterpret_cast<SetApplicationDelegate>(
        method_setImplementation(setter,
            reinterpret_cast<IMP>(PrepareAssignedApplicationDelegate)));
}

extern "C" void LC32RegisterLegacySceneWindow(UIWindow *window) {
    if(!legacySceneLifecycleEnabled || !pthread_main_np() ||
            !window.guest_selfOrNull) return;
    [LegacySceneWindows() addObject:window];
}

extern "C" void LC32ObserveClassicCanvasScene(UIWindowScene *scene) {
    if(!scene || !pthread_main_np()) {
        return;
    }
    id delegate = scene.delegate;
    Class delegateClass = delegate ? object_getClass(delegate) : Nil;
    const bool installed = delegateClass && objc_getAssociatedObject(
        (id)delegateClass, classicSceneGeometryInstalledKey);
    if(!delegateClass) {
        ObserveClassicCanvasWithoutDelegate(scene);
        return;
    }
    if(installed ||
            [delegate isKindOfClass:LC32LegacySceneDelegate.class]) return;

    const SEL selector = @selector(windowScene:didUpdateCoordinateSpace:
        interfaceOrientation:traitCollection:);
    Method inherited = class_getInstanceMethod(delegateClass, selector);
    const struct objc_method_description declaration =
        protocol_getMethodDescription(@protocol(UIWindowSceneDelegate),
            selector, NO, YES);
    const char *types = inherited ? method_getTypeEncoding(inherited)
                                  : declaration.types;
    if(!types) return;
    IMP observer = reinterpret_cast<IMP>(ClassicCanvasSceneGeometryUpdated);
    IMP previous = nullptr;
    if(!class_addMethod(delegateClass, selector, observer, types)) {
        Method own = class_getInstanceMethod(delegateClass, selector);
        if(!own) return;
        previous = method_setImplementation(own, observer);
    } else if(inherited) {
        previous = method_getImplementation(inherited);
    }
    if(previous && previous != observer) {
        objc_setAssociatedObject((id)delegateClass,
            classicSceneGeometryOriginalKey,
            @(reinterpret_cast<uintptr_t>(previous)),
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    objc_setAssociatedObject((id)delegateClass,
        classicSceneGeometryInstalledKey, @YES,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@implementation LC32LegacySceneDelegate

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session
        options:(__unused UISceneConnectionOptions *)connectionOptions {
    if(![scene isKindOfClass:UIWindowScene.class] ||
            ![session.role isEqualToString:UIWindowSceneSessionRoleApplication]) return;
    UIWindowScene *windowScene = (UIWindowScene *)scene;
    NSMutableSet<UIWindow *> *windows = [NSMutableSet setWithArray:
        LegacySceneWindows().allObjects];
    id<UIApplicationDelegate> delegate = UIApplication.sharedApplication.delegate;
    if([delegate respondsToSelector:@selector(window)]) {
        UIWindow *declaredWindow = delegate.window;
        if(declaredWindow) [windows addObject:declaredWindow];
    }

    UIWindow *primaryWindow = nil;
    for(UIWindow *window in windows) {
        if(window.windowScene && window.windowScene != windowScene) continue;
        const BOOL wasKey = window.isKeyWindow;
        if(wasKey || (!primaryWindow && !window.hidden &&
                window.windowLevel == UIWindowLevelNormal)) {
            primaryWindow = window;
        }
        if(window.windowScene != windowScene) window.windowScene = windowScene;
    }
    self.window = primaryWindow;
    if(primaryWindow) {
        /* The guest has already made its launch window visible. Reattach it
         * through UIWindow's native implementation without repeating an
         * authored guest override after the scene connection. */
        using MakeKeyAndVisible = void (*)(id, SEL);
        MakeKeyAndVisible makeKeyAndVisible = reinterpret_cast<MakeKeyAndVisible>(
            class_getMethodImplementation(UIWindow.class, @selector(makeKeyAndVisible)));
        makeKeyAndVisible(primaryWindow, @selector(makeKeyAndVisible));
    }
    LC32UIKitRefitLegacyScene(windowScene);
}

- (void)sceneWillEnterForeground:(__unused UIScene *)scene {
    if(!self.hasActivated || !self.backgrounded) return;
    self.backgrounded = NO;
    ForwardLegacyApplicationEvent(@selector(applicationWillEnterForeground:));
}

- (void)sceneDidBecomeActive:(UIScene *)scene {
    if(self.active) return;
    self.active = YES;
    self.hasActivated = YES;
    self.backgrounded = NO;
    ForwardLegacyApplicationEvent(@selector(applicationDidBecomeActive:));
    if([scene isKindOfClass:UIWindowScene.class]) {
        LC32UIKitRefitLegacyScene((UIWindowScene *)scene);
    }
}

- (void)sceneWillResignActive:(__unused UIScene *)scene {
    if(!self.active) return;
    self.active = NO;
    ForwardLegacyApplicationEvent(@selector(applicationWillResignActive:));
}

- (void)sceneDidEnterBackground:(__unused UIScene *)scene {
    if(self.backgrounded) return;
    self.backgrounded = YES;
    ForwardLegacyApplicationEvent(@selector(applicationDidEnterBackground:));
}

- (void)windowScene:(UIWindowScene *)windowScene
        didUpdateCoordinateSpace:(__unused id<UICoordinateSpace>)previousCoordinateSpace
        interfaceOrientation:(__unused UIInterfaceOrientation)previousInterfaceOrientation
        traitCollection:(__unused UITraitCollection *)previousTraitCollection {
    LC32UIKitRefitLegacyScene(windowScene);
}

@end
