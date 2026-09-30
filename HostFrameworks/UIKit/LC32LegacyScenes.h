#pragma once

#import <UIKit/UIKit.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Supply a native scene lifecycle for a guest with only an app delegate.
 * Authored scene configurations and delegate methods retain their policy. */
void LC32PrepareLegacySceneLifecycle(NSString *delegateClassName);
void LC32InstallLegacySceneDelegatePreparation(void);
void LC32RegisterLegacySceneWindow(UIWindow *window);
void LC32ObserveClassicCanvasScene(UIWindowScene *scene);
void LC32UIKitRefitLegacyScene(UIWindowScene *scene);
BOOL LC32GuestRequestsClassicPortraitPhoneCanvas(void);

#ifdef __cplusplus
}
#endif
