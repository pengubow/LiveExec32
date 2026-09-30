#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

/* Package as a phone-only app with UIStatusBarHidden=YES and no orientation
 * keys. Run with SDK spoofing both on and off. The fixture keeps a portrait
 * CAEAGLLayer surface, rejects UIKit landscape turns, and explicitly requests
 * each landscape side as renderer-era games did. All sizes come from launch
 * geometry. Assertions cover scene direction, drawable extent, centering,
 * root identity, and absence of recursive policy callbacks. Link with SDK 7.0
 * metadata so the host selects the old-renderer compatibility path. */
static CGSize launchSize;
static unsigned queryDepth;
static unsigned maximumQueryDepth;
static unsigned queries;
static unsigned landscapeLeftQueries;

static void check(const char *name, BOOL passed) {
    printf("manual-projection-%s: %s\n", name, passed ? "PASS" : "FAIL");
    if(!passed) exit(1);
}

static void checkDrawableFitsInView(UIView *drawable, UIView *clippingView,
        const char *name) {
    const CGRect projected = [drawable convertRect:[drawable bounds]
        toView:clippingView];
    const CGRect clippingBounds = [clippingView bounds];
    check(name, clippingView &&
        CGRectGetMinX(projected) >= CGRectGetMinX(clippingBounds) - 0.5 &&
        CGRectGetMinY(projected) >= CGRectGetMinY(clippingBounds) - 0.5 &&
        CGRectGetMaxX(projected) <= CGRectGetMaxX(clippingBounds) + 0.5 &&
        CGRectGetMaxY(projected) <= CGRectGetMaxY(clippingBounds) + 0.5);
}

@interface LC32ManualProjectionView : UIView
@end

@implementation LC32ManualProjectionView

+ (Class)layerClass {
    return [CAEAGLLayer class];
}

@end

@interface LC32ManualProjectionController : UIViewController
@end

@implementation LC32ManualProjectionController

- (void)loadView {
    UIView *view = [[LC32ManualProjectionView alloc]
        initWithFrame:CGRectMake(0, 0, launchSize.width, launchSize.height)];
    [self setView:view];
    [view release];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation {
    ++queries;
    ++queryDepth;
    maximumQueryDepth = MAX(maximumQueryDepth, queryDepth);
    if(orientation == UIInterfaceOrientationLandscapeLeft) {
        ++landscapeLeftQueries;
    }
    if(UIInterfaceOrientationIsLandscape(orientation)) {
        [[UIApplication sharedApplication] setStatusBarOrientation:orientation animated:NO];
    }
    --queryDepth;
    return orientation == UIInterfaceOrientationPortrait;
}

@end

@interface LC32ManualProjectionDelegate : NSObject <UIApplicationDelegate> {
    UIWindow *_window;
    UIViewController *_controller;
    unsigned _ticks;
    unsigned _stableTicks;
    unsigned _previousQueries;
    BOOL _didBecomeActive;
    BOOL _checkedPortraitPolicy;
    BOOL _secondSide;
}
@end

@implementation LC32ManualProjectionDelegate

- (BOOL)application:(UIApplication *)application
        didFinishLaunchingWithOptions:(__unused NSDictionary *)options {
    const CGSize screenSize = [[UIScreen mainScreen] bounds].size;
    launchSize = CGSizeMake(MIN(screenSize.width, screenSize.height),
        MAX(screenSize.width, screenSize.height));
    _window = [[UIWindow alloc] initWithFrame:
        CGRectMake(0, 0, launchSize.width, launchSize.height)];
    _controller = [[LC32ManualProjectionController alloc] init];
    [_controller setWantsFullScreenLayout:YES];
    [_window setRootViewController:_controller];
    [application setStatusBarOrientation:UIInterfaceOrientationLandscapeRight animated:NO];
    [_window makeKeyAndVisible];
    [NSTimer scheduledTimerWithTimeInterval:0.1 target:self
        selector:@selector(checkGeometry:) userInfo:nil repeats:YES];
    return YES;
}

- (void)applicationDidBecomeActive:(__unused UIApplication *)application {
    _didBecomeActive = YES;
}

- (void)checkGeometry:(NSTimer *)timer {
    ++_ticks;
    if(_ticks >= 100) check("settlement-timeout", NO);
    const UIInterfaceOrientation expected = _secondSide
        ? UIInterfaceOrientationLandscapeLeft : UIInterfaceOrientationLandscapeRight;
    const UIInterfaceOrientation actual = [[UIApplication sharedApplication] statusBarOrientation];
    if(actual != expected || queries != _previousQueries) {
        _stableTicks = 0;
        _previousQueries = queries;
        return;
    }
    if(++_stableTicks < 5) return;

    check("launch-activation-callback", _didBecomeActive);
    UIView *view = [_controller view];
    const CGRect bounds = [view bounds];
    check("drawable-extent", fabs(bounds.size.width - launchSize.width) < 0.5 &&
        fabs(bounds.size.height - launchSize.height) < 0.5);
    const CGAffineTransform compositor = [[view superview] transform];
    const CGFloat side = expected == UIInterfaceOrientationLandscapeLeft ? 1 : -1;
    check("projection-compositor", fabs(compositor.a) < 0.001 &&
        fabs(compositor.d) < 0.001 && compositor.b * side > 0 &&
        compositor.c * side < 0);
    const CGPoint centerInWindow = [view convertPoint:
        CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds)) toView:_window];
    const CGRect windowBounds = [_window bounds];
    check("drawable-centered", fabs(centerInWindow.x - CGRectGetMidX(windowBounds)) < 0.5 &&
        fabs(centerInWindow.y - CGRectGetMidY(windowBounds)) < 0.5);
    checkDrawableFitsInView(view, _window, "drawable-not-clipped-by-window");
    checkDrawableFitsInView(view, [[view superview] superview],
        "drawable-not-clipped-by-container");
    check("guest-root-identity", [_window rootViewController] == _controller);
    check("nonrecursive-policy", maximumQueryDepth <= 1);
    if(!_secondSide) {
        /* Identifying this renderer must ask for its requested side once.
         * A four-direction modern mask probe would turn its projection to
         * the opposite side before returning to its launch direction. */
        check("launch-does-not-probe-opposite-landscape", landscapeLeftQueries == 0);
    }
    printf("manual-projection-scene: orientation=%ld extent=%s queries=%u\n",
        (long)actual, [NSStringFromCGRect(bounds) UTF8String], queries);

    if(!_checkedPortraitPolicy) {
        _checkedPortraitPolicy = YES;
        check("portrait-policy-keeps-landscape-request",
            [_controller shouldAutorotateToInterfaceOrientation:UIInterfaceOrientationPortrait] &&
            [[UIApplication sharedApplication] statusBarOrientation] == expected);
        _stableTicks = 0;
        return;
    }
    if(!_secondSide) {
        _secondSide = YES;
        _stableTicks = 0;
        [_controller shouldAutorotateToInterfaceOrientation:UIInterfaceOrientationLandscapeLeft];
        return;
    }
    [timer invalidate];
    exit(0);
}

@end

int main(int argc, char **argv) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil,
            NSStringFromClass([LC32ManualProjectionDelegate class]));
    }
}
