#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#if LC32_TEST_LANDSCAPE_DIRECT_RENDERER
#import <LC32/LC32.h>
#import "LC32LegacyCanvas.h"
#endif
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

/* Run as a portrait phone app with SDK spoofing on and off. The ordinary
 * UIKit variant requires Classic Mode. The direct-renderer variant also
 * covers Classic Mode off and an initial window smaller than the scene.
 * Its controller variant assigns an empty guest controller's view without
 * making that controller the window root, like an early modal-panel host.
 * Resize the native viewport after launch and verify fixed guest geometry,
 * stacking and hit testing. Linux compiles this fixture; its assertions
 * require UIKit in LiveContainer on a device.
 *
 * The landscape variant reproduces a pre-controller app without launch art:
 * LSRequiresIPhoneOS=YES, UIStatusBarHidden=YES, initial
 * UIInterfaceOrientationLandscapeRight, no supported-orientations array,
 * and no Default.png or other launch image. Run with SDK spoofing and
 * Classic Mode individually on and off. Its explicit LandscapeLeft request
 * must replace the bundle's initial side without resizing the drawable. */
static void check(const char *name, BOOL passed) {
    printf("classic-direct-view-%s: %s\n", name, passed ? "PASS" : "FAIL");
    if(!passed) exit(1);
}

#if LC32_TEST_DIRECT_GL_RENDERER
@interface LC32DirectCanvasRenderer : UIView
@end

@implementation LC32DirectCanvasRenderer
+ (Class)layerClass {
    return CAEAGLLayer.class;
}
@end

#if LC32_TEST_RENDERER_CONTROLLER
@interface LC32DirectCanvasController : UIViewController
@end

@implementation LC32DirectCanvasController
@end
#endif
#endif

@interface LC32ClassicDirectController : UIViewController
@end

@implementation LC32ClassicDirectController

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation {
    return orientation == UIInterfaceOrientationPortrait;
}

@end

@interface LC32ClassicDirectDelegate : NSObject <UIApplicationDelegate> {
    UIWindow *_window;
    UIViewController *_controller;
    UIButton *_button;
    UIView *_overlay;
    UIView *_canvasView;
    CGRect _launchBounds;
    CGRect _buttonFrame;
    CGRect _overlayFrame;
    unsigned _ticks;
    BOOL _expanded;
#if LC32_TEST_LANDSCAPE_DIRECT_RENDERER
    BOOL _changedSide;
#endif
}
@property(nonatomic, retain) UIWindow *window;
@property(nonatomic, retain) UIViewController *rootViewController;
@end

@implementation LC32ClassicDirectDelegate

@synthesize window = _window;
@synthesize rootViewController = _controller;

- (BOOL)application:(__unused UIApplication *)application
        didFinishLaunchingWithOptions:(__unused NSDictionary *)options {
    const CGRect initialWindowBounds = [[UIScreen mainScreen] bounds];
    _launchBounds = initialWindowBounds;
#if LC32_TEST_LANDSCAPE_DIRECT_RENDERER
    NSBundle *bundle = [NSBundle mainBundle];
    NSDictionary *info = [bundle infoDictionary];
    check("bundle-has-no-launch-art",
        !LC32BundleContainsPhoneLaunchArt(bundle, info));
    check("bundle-has-only-initial-side",
        [info[@"UIInterfaceOrientation"] isEqual:
            @"UIInterfaceOrientationLandscapeRight"] &&
        info[@"UISupportedInterfaceOrientations"] == nil &&
        info[@"UISupportedInterfaceOrientations~iphone"] == nil);
    _launchBounds.size = CGSizeMake(
        MIN(initialWindowBounds.size.width, initialWindowBounds.size.height),
        MAX(initialWindowBounds.size.width, initialWindowBounds.size.height));
    [application setStatusBarOrientation:UIInterfaceOrientationLandscapeLeft
                               animated:NO];
#elif LC32_TEST_DIRECT_GL_RENDERER
    _launchBounds.size.width *= 0.75;
    _launchBounds.size.height *= 0.75;
#endif
    _window = [[UIWindow alloc] initWithFrame:_launchBounds];
#if LC32_TEST_DIRECT_GL_RENDERER
    /* The app can show its window before creating or attaching the renderer.
     * Adoption must also work at the completed launch/activation boundary. */
    [_window makeKeyAndVisible];
    _canvasView = [[LC32DirectCanvasRenderer alloc] initWithFrame:_launchBounds];
#if LC32_TEST_RENDERER_CONTROLLER
    _controller = [[LC32DirectCanvasController alloc] init];
    [_controller setView:_canvasView];
#endif
    [_window addSubview:_canvasView];
#else
    _controller = [[LC32ClassicDirectController alloc] init];
    _canvasView = [[UIView alloc] initWithFrame:_launchBounds];
    [_canvasView setAutoresizingMask:UIViewAutoresizingFlexibleTopMargin |
        UIViewAutoresizingFlexibleBottomMargin];
    [_controller setView:_canvasView];
    [_window addSubview:_canvasView];
#endif

    _buttonFrame = CGRectMake(_launchBounds.size.width * 0.2,
        _launchBounds.size.height * 0.2, _launchBounds.size.width * 0.3,
        _launchBounds.size.height * 0.15);
    _button = [[UIButton alloc] initWithFrame:_buttonFrame];
    [_canvasView addSubview:_button];

    _overlayFrame = CGRectMake(_launchBounds.size.width * 0.8,
        _launchBounds.size.height * 0.8, _launchBounds.size.width * 0.1,
        _launchBounds.size.height * 0.1);
    _overlay = [[UIView alloc] initWithFrame:_overlayFrame];
    [_overlay setAutoresizingMask:UIViewAutoresizingFlexibleLeftMargin |
        UIViewAutoresizingFlexibleTopMargin];
    [_window addSubview:_overlay];
#if !LC32_TEST_DIRECT_GL_RENDERER
    [_window makeKeyAndVisible];
#endif
    check("guest-window-root-stays-nil", [_window rootViewController] == nil);
    [NSTimer scheduledTimerWithTimeInterval:0.1 target:self
        selector:@selector(checkViewport:) userInfo:nil repeats:YES];
    return YES;
}

- (void)checkViewport:(NSTimer *)timer {
    if(++_ticks < 15) return;
#if LC32_TEST_LANDSCAPE_DIRECT_RENDERER
    NSString *orientationKey = @"windowScene.interfaceOrientation";
    NSNumber *sceneOrientation = LC32InvokeHostObjectSelector(
        [_window host_self], LC32GetHostSelector(@selector(valueForKeyPath:)),
        [orientationKey host_self], (uint64_t)0);
    const UIInterfaceOrientation expectedOrientation = _changedSide
        ? UIInterfaceOrientationLandscapeRight
        : UIInterfaceOrientationLandscapeLeft;
    if([sceneOrientation integerValue] != expectedOrientation) {
        if(_ticks < 100) return;
        check("scene-honors-explicit-side", NO);
    }
    check("scene-honors-explicit-side", YES);
#endif
    if(!_expanded) {
        [self checkCanvasGeometry];
        const CGRect frame = [_window frame];
        const CGRect expanded = CGRectMake(frame.origin.x, frame.origin.y,
            frame.size.width * 1.25, frame.size.height * 1.75);
        [_window setFrame:expanded];
        _expanded = YES;
        return;
    }
    if(_ticks < 25) return;

    const CGRect viewport = [_window bounds];
#if LC32_TEST_LANDSCAPE_DIRECT_RENDERER
    check("viewport-really-expanded", viewport.size.width > _launchBounds.size.height &&
        viewport.size.height > _launchBounds.size.width);
#else
    check("viewport-really-expanded", viewport.size.width > _launchBounds.size.width &&
        viewport.size.height > _launchBounds.size.height);
#endif
    [self checkCanvasGeometry];
#if LC32_TEST_LANDSCAPE_DIRECT_RENDERER
    if(!_changedSide) {
        _changedSide = YES;
        _ticks = 0;
        [[UIApplication sharedApplication] setStatusBarOrientation:
            UIInterfaceOrientationLandscapeRight animated:NO];
        return;
    }
#endif
    [timer invalidate];
    exit(0);
}

- (void)checkCanvasGeometry {
    UIView *view = _canvasView;
    const CGRect viewport = [_window bounds];
    const CGRect displayed = [view convertRect:[view bounds] toView:_window];
    CGSize displayedSize = _launchBounds.size;
#if LC32_TEST_LANDSCAPE_DIRECT_RENDERER
    displayedSize = CGSizeMake(_launchBounds.size.height, _launchBounds.size.width);
    const CGPoint origin = [view convertPoint:CGPointZero toView:_window];
    const CGPoint xAxis = [view convertPoint:CGPointMake(1, 0) toView:_window];
    const CGPoint yAxis = [view convertPoint:CGPointMake(0, 1) toView:_window];
    check("portrait-basis-turns-once",
        fabs(xAxis.x - origin.x) < 0.01 &&
        fabs(yAxis.y - origin.y) < 0.01 &&
        (_changedSide ? xAxis.y < origin.y && yAxis.x > origin.x
                      : xAxis.y > origin.y && yAxis.x < origin.x));
#endif
    CGFloat expectedScale = fmin(
        viewport.size.width / displayedSize.width,
        viewport.size.height / displayedSize.height);
#if LC32_TEST_LANDSCAPE_DIRECT_RENDERER
    if(LC32BundleRequestsClassicMode([NSBundle mainBundle])) {
        expectedScale = fmin(expectedScale, 1);
    }
#endif
    UIView *nativeRootView = [[view superview] superview];
    const CGRect rootInWindow = [nativeRootView convertRect:[nativeRootView bounds]
        toView:_window];
    check("native-wrapper-fills-window", CGRectEqualToRect(rootInWindow, viewport));
    check("canvas-bounds-preserved", CGRectEqualToRect([view bounds], _launchBounds));
    check("button-frame-preserved", CGRectEqualToRect([_button frame], _buttonFrame));
    check("overlay-frame-preserved", CGRectEqualToRect([_overlay frame], _overlayFrame));
    check("centered-in-expanded-viewport",
        fabs(CGRectGetMidX(displayed) - CGRectGetMidX(viewport)) < 0.5 &&
        fabs(CGRectGetMidY(displayed) - CGRectGetMidY(viewport)) < 0.5);
    check("classic-viewport-scale",
        fabs(displayed.size.width - displayedSize.width * expectedScale) < 0.5 &&
        fabs(displayed.size.height - displayedSize.height * expectedScale) < 0.5);
    check("guest-root-stays-nil-after-resize", [_window rootViewController] == nil);
#if LC32_TEST_DIRECT_GL_RENDERER
    check("renderer-keeps-its-own-layer",
        [[view layer] isKindOfClass:CAEAGLLayer.class]);
#endif
    check("controller-stays-with-view", [view nextResponder] ==
        (_controller ?: (UIResponder *)[view superview]));
    check("direct-view-stacking-preserved", [view superview] == [_overlay superview] &&
        [[[view superview] subviews] indexOfObject:view] <
        [[[view superview] subviews] indexOfObject:_overlay]);
#if LC32_TEST_DIRECT_GL_RENDERER
    const UIViewAutoresizing expectedMask = UIViewAutoresizingNone;
#else
    const UIViewAutoresizing expectedMask = UIViewAutoresizingFlexibleTopMargin |
        UIViewAutoresizingFlexibleBottomMargin;
#endif
    check("autoresizing-masks-preserved",
        [view autoresizingMask] == expectedMask &&
        [_overlay autoresizingMask] == (UIViewAutoresizingFlexibleLeftMargin |
            UIViewAutoresizingFlexibleTopMargin));
    const CGPoint hitPoint = [view convertPoint:[_button center] toView:_window];
    check("button-hit-test-preserved", [_window hitTest:hitPoint withEvent:nil] == _button);
}

- (void)dealloc {
    [_overlay release];
    [_button release];
    [_controller release];
    [_canvasView release];
    [_window release];
    [super dealloc];
}

@end

int main(int argc, char **argv) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil,
            NSStringFromClass([LC32ClassicDirectDelegate class]));
    }
}
