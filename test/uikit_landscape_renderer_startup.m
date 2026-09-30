#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

/* Package as a phone-only, fullscreen app declaring all four orientations.
 * Run with SDK spoofing and Classic Mode individually on and off. The guest
 * creates its renderer from pre-iOS-8 UIScreen coordinates, then samples it
 * immediately after assigning the root and exposing the window, as a game
 * engine does before it constructs the first scene. The authored controller
 * policy is narrower than the bundle, like Geometry Dash 1.11. No fixed
 * display size or deferred engine initialization is used. Linux can only build this test;
 * the assertions require native UIKit in LiveContainer on a device. */
static CGSize launchLandscapeSize;
static BOOL rendererInstalled;
static unsigned portraitLayouts;

static void check(const char *name, BOOL passed) {
    printf("landscape-startup-%s: %s\n", name, passed ? "PASS" : "FAIL");
    if(!passed) exit(1);
}

@interface LC32LandscapeStartupView : UIView
@end

@implementation LC32LandscapeStartupView

+ (Class)layerClass {
    return [CAEAGLLayer class];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    const CGSize size = [self bounds].size;
    if(rendererInstalled && size.height > size.width) ++portraitLayouts;
}

@end

@interface LC32LandscapeStartupController : UIViewController
@end

@implementation LC32LandscapeStartupController

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}

- (BOOL)shouldAutorotate {
    return YES;
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation {
    return UIInterfaceOrientationIsLandscape(orientation);
}

@end

@interface LC32LandscapeStartupDelegate : NSObject <UIApplicationDelegate> {
    UIWindow *_window;
    LC32LandscapeStartupController *_controller;
    unsigned _ticks;
    BOOL _activated;
}
@property(nonatomic, retain) UIWindow *window;
@end

@implementation LC32LandscapeStartupDelegate

@synthesize window = _window;

- (BOOL)application:(__unused UIApplication *)application
        didFinishLaunchingWithOptions:(__unused NSDictionary *)options {
    const CGRect screenBounds = [[UIScreen mainScreen] bounds];
    check("legacy-screen-coordinates-remain-portrait",
        screenBounds.size.height > screenBounds.size.width);
    launchLandscapeSize = CGSizeMake(
        MAX(screenBounds.size.width, screenBounds.size.height),
        MIN(screenBounds.size.width, screenBounds.size.height));
    _window = [[UIWindow alloc] initWithFrame:screenBounds];
    _controller = [[LC32LandscapeStartupController alloc] init];
    [_controller setWantsFullScreenLayout:YES];
    UIView *renderer = [[LC32LandscapeStartupView alloc] initWithFrame:screenBounds];
    [renderer setAutoresizingMask:UIViewAutoresizingFlexibleWidth |
        UIViewAutoresizingFlexibleHeight];
    [_controller setView:renderer];
    [renderer release];
    [_window setRootViewController:_controller];
    rendererInstalled = YES;
    const CGSize rootSize = [[_controller view] bounds].size;
    check("root-assignment-before-engine-size-sample",
        fabs(rootSize.width - launchLandscapeSize.width) < 0.5 &&
        fabs(rootSize.height - launchLandscapeSize.height) < 0.5);
    [_window makeKeyAndVisible];
    const CGSize engineSize = [[_controller view] bounds].size;
    check("window-exposure-before-engine-size-sample",
        fabs(engineSize.width - launchLandscapeSize.width) < 0.5 &&
        fabs(engineSize.height - launchLandscapeSize.height) < 0.5);
    check("guest-root-identity", [_window rootViewController] == _controller);
    [NSTimer scheduledTimerWithTimeInterval:0.1 target:self
        selector:@selector(checkSettlement:) userInfo:nil repeats:YES];
    return YES;
}

- (void)applicationDidBecomeActive:(__unused UIApplication *)application {
    _activated = YES;
}

- (void)checkSettlement:(NSTimer *)timer {
    ++_ticks;
    if(_ticks >= 100) check("scene-settlement-timeout", NO);
    if(!_activated || !UIInterfaceOrientationIsLandscape(
            [[UIApplication sharedApplication] statusBarOrientation]) || _ticks < 10) return;
    const CGSize rendererSize = [[_controller view] bounds].size;
    check("landscape-after-scene-activation", rendererSize.width > rendererSize.height);
    check("no-portrait-layout-after-engine-start", portraitLayouts == 0);
    check("guest-root-identity-after-activation", [_window rootViewController] == _controller);
    printf("landscape-startup-geometry: launch=%s settled=%s\n",
        [NSStringFromCGSize(launchLandscapeSize) UTF8String],
        [NSStringFromCGSize(rendererSize) UTF8String]);
    [timer invalidate];
    exit(0);
}

- (void)dealloc {
    [_window release];
    [_controller release];
    [super dealloc];
}

@end

int main(int argc, char **argv) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil,
            NSStringFromClass([LC32LandscapeStartupDelegate class]));
    }
}
