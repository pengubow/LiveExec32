#pragma once

#import <UIKit/UIKit.h>

#ifdef __cplusplus
extern "C" {
#endif

bool LC32IsNativeAlertPresenterWindow(UIWindow *window);
bool LC32NativeAlertWindowUsesScenePolicy(UIWindow *window);

#ifdef __cplusplus
}

#endif
