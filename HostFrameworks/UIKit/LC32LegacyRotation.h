#pragma once

#import <UIKit/UIKit.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Restore pre-iOS-8 guest rotation queries/callbacks and the native legacy
 * backing-layer setup, independently of modern-host canvas compensation. */
bool LC32NativeLegacyRotationEnabled(void);
/* Inspect authored policy before compatibility adapters are installed. */
bool LC32LegacyRendererUsesNativeInitialOrientation(Class cls);
/* Register guest roots for shared Classic Mode canvas preservation. Only
 * the old process-SDK path also installs deprecated rotation policy. */
void LC32PrepareNativeLegacyRotationClass(Class cls);
UIViewController *LC32NativeLegacyRotationDirectController(UIWindow *window);
void LC32NativeLegacyRotationAdoptDirectRenderer(
    UIWindow *window, UIViewController *controller);
NSArray<UIWindow *> *LC32FinishNativeLegacyRotationStartup(void);
void LC32NativeLegacyRotationAdoptSceneContainer(UIWindow *window,
    UIViewController *container, UIViewController *rendererController);
/* Fit fullscreen legacy renderers in native portrait window coordinates.
 * Native-policy roots without rotation callbacks start with landscape bounds;
 * a requested Classic Mode canvas retains its launch size through resume.
 * Portrait GL roots use the same preservation with either process SDK,
 * including roots inside UIKit's native presentation view. */
void LC32FitNativeLegacyRendererCanvas(UIWindow *window);
/* Synchronize UIAlertView's native presenter after its scene commits a turn.
 * Return true only for that native window on the old process-SDK path. */
bool LC32SynchronizeNativeLegacyAlertWindow(UIWindow *window);
/* Include tracked native presenter windows omitted from scene.windows. */
void LC32SynchronizeNativeLegacyAlertWindows(UIWindowScene *scene);
/* Place a presented native alert after UIKit finishes its presentation turn. */
void LC32ScheduleNativeLegacyAlertPlacement(UIWindow *window);
/* A guest geometry setter relinquishes the captured native-root canvas.
 * Native UIKit layout must not be mistaken for an authored geometry change. */
void LC32NativeLegacyRotationDidSetGuestViewGeometry(id object);

/* Supplied by the emulator: native layout callbacks can arrive before the
 * guest renderer is initialized or on a thread without a guest CPU context. */
BOOL LC32NativeLegacyRotationCanCallGuest(void);
/* Cache an authored modern policy during root attachment for a fullscreen
 * renderer without guest rotation callbacks. Later native layout reads the
 * cache without entering a guest thread. Zero means no such policy is ready. */
UIInterfaceOrientationMask LC32NativeLegacyRendererSupportedOrientations(
    UIViewController *controller);

#ifdef __cplusplus
}
#endif
