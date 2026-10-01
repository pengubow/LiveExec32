#pragma once

#import <UIKit/UIKit.h>

/* Install the shared compositor predicate once. Each native component still
 * validates and installs its own methods independently. */
bool LC32InstallNativeWindowScenePolicy(void);
bool LC32NativeWindowScenePolicyInstalled(void);

/* Native alerts and keyboards belong to current UIKit. Their matched native
 * operations use its scene compositor; a nested guest operation clears the
 * scope and retains the process's linked-SDK policy. */
class LC32NativeWindowSceneScope {
public:
    explicit LC32NativeWindowSceneScope(UIWindow *window);
    ~LC32NativeWindowSceneScope();
    LC32NativeWindowSceneScope(const LC32NativeWindowSceneScope &) = delete;
    LC32NativeWindowSceneScope &operator=(const LC32NativeWindowSceneScope &) = delete;

private:
    __unsafe_unretained UIWindow *previous_;
};

/* Some native alert methods query the class predicate before their window
 * exists. Select the modern branch only for that exact original caller. */
class LC32NativeWindowCallerScope {
public:
    LC32NativeWindowCallerScope(bool enabled, IMP caller);
    ~LC32NativeWindowCallerScope();
    LC32NativeWindowCallerScope(const LC32NativeWindowCallerScope &) = delete;
    LC32NativeWindowCallerScope &operator=(const LC32NativeWindowCallerScope &) = delete;

private:
    void *previous_;
};
