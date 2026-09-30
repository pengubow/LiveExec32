#pragma once

#import <UIKit/UIKit.h>

#ifdef __cplusplus
extern "C" {
#endif

bool LC32IsNativeAlertPresenterWindow(UIWindow *window);
bool LC32NativeAlertWindowUsesScenePolicy(UIWindow *window);

#ifdef __cplusplus
}

/* Native alert presentation is a matched scene-based operation. Its own
 * window must use that policy during rotation, presentation and dismissal;
 * guest windows retain the process's linked-SDK policy. */
class LC32NativeAlertSceneScope {
public:
    explicit LC32NativeAlertSceneScope(UIWindow *window);
    ~LC32NativeAlertSceneScope();
    LC32NativeAlertSceneScope(const LC32NativeAlertSceneScope &) = delete;
    LC32NativeAlertSceneScope &operator=(const LC32NativeAlertSceneScope &) = delete;

private:
    __unsafe_unretained UIWindow *previous_;
};
#endif
