#import <UIKit/UIKit.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

/* Run as a portrait phone app in Classic Mode, with SDK spoofing on and off.
 * Like a pre-root-controller nib app, attach ordinary UIKit views directly to
 * the window. Resize the native viewport after launch and verify fixed guest
 * geometry, stacking and hit testing. Linux builds this fixture; executing
 * its assertions requires UIKit in LiveContainer on a device. */
static void check(const char *name, BOOL passed) {
    printf("classic-direct-view-%s: %s\n", name, passed ? "PASS" : "FAIL");
    if(!passed) exit(1);
}

@interface LC32ClassicDirectController : UIViewController
@end

@implementation LC32ClassicDirectController

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation {
    return orientation == UIInterfaceOrientationPortrait;
}

@end

@interface LC32ClassicDirectDelegate : NSObject <UIApplicationDelegate> {
    UIWindow *_window;
    LC32ClassicDirectController *_controller;
    UIButton *_button;
    UIView *_overlay;
    CGRect _launchBounds;
    CGRect _buttonFrame;
    CGRect _overlayFrame;
    unsigned _ticks;
    BOOL _expanded;
}
@property(nonatomic, retain) UIWindow *window;
@property(nonatomic, retain) LC32ClassicDirectController *rootViewController;
@end

@implementation LC32ClassicDirectDelegate

@synthesize window = _window;
@synthesize rootViewController = _controller;

- (BOOL)application:(__unused UIApplication *)application
        didFinishLaunchingWithOptions:(__unused NSDictionary *)options {
    _launchBounds = [[UIScreen mainScreen] bounds];
    _window = [[UIWindow alloc] initWithFrame:_launchBounds];
    _controller = [[LC32ClassicDirectController alloc] init];
    UIView *view = [[UIView alloc] initWithFrame:_launchBounds];
    [view setAutoresizingMask:UIViewAutoresizingFlexibleTopMargin |
        UIViewAutoresizingFlexibleBottomMargin];
    [_controller setView:view];
    [view release];

    _buttonFrame = CGRectMake(_launchBounds.size.width * 0.2,
        _launchBounds.size.height * 0.2, _launchBounds.size.width * 0.3,
        _launchBounds.size.height * 0.15);
    _button = [[UIButton alloc] initWithFrame:_buttonFrame];
    [[_controller view] addSubview:_button];
    [_window addSubview:[_controller view]];

    _overlayFrame = CGRectMake(_launchBounds.size.width * 0.8,
        _launchBounds.size.height * 0.8, _launchBounds.size.width * 0.1,
        _launchBounds.size.height * 0.1);
    _overlay = [[UIView alloc] initWithFrame:_overlayFrame];
    [_overlay setAutoresizingMask:UIViewAutoresizingFlexibleLeftMargin |
        UIViewAutoresizingFlexibleTopMargin];
    [_window addSubview:_overlay];
    [_window makeKeyAndVisible];
    check("guest-window-root-stays-nil", [_window rootViewController] == nil);
    [NSTimer scheduledTimerWithTimeInterval:0.1 target:self
        selector:@selector(checkViewport:) userInfo:nil repeats:YES];
    return YES;
}

- (void)checkViewport:(NSTimer *)timer {
    if(++_ticks < 15) return;
    if(!_expanded) {
        const CGRect frame = [_window frame];
        const CGRect expanded = CGRectMake(frame.origin.x, frame.origin.y,
            _launchBounds.size.width * 1.25, _launchBounds.size.height * 1.75);
        [_window setFrame:expanded];
        _expanded = YES;
        return;
    }
    if(_ticks < 25) return;

    UIView *view = [_controller view];
    const CGRect viewport = [_window bounds];
    const CGRect displayed = [view convertRect:[view bounds] toView:_window];
    const CGFloat expectedScale = fmin(
        viewport.size.width / _launchBounds.size.width,
        viewport.size.height / _launchBounds.size.height);
    check("viewport-really-expanded", viewport.size.width > _launchBounds.size.width &&
        viewport.size.height > _launchBounds.size.height);
    check("canvas-bounds-preserved", CGRectEqualToRect([view bounds], _launchBounds));
    check("button-frame-preserved", CGRectEqualToRect([_button frame], _buttonFrame));
    check("overlay-frame-preserved", CGRectEqualToRect([_overlay frame], _overlayFrame));
    check("centered-in-expanded-viewport",
        fabs(CGRectGetMidX(displayed) - CGRectGetMidX(viewport)) < 0.5 &&
        fabs(CGRectGetMidY(displayed) - CGRectGetMidY(viewport)) < 0.5);
    check("classic-viewport-scale",
        fabs(displayed.size.width - _launchBounds.size.width * expectedScale) < 0.5 &&
        fabs(displayed.size.height - _launchBounds.size.height * expectedScale) < 0.5);
    check("guest-root-stays-nil-after-resize", [_window rootViewController] == nil);
    check("controller-stays-with-view", [view nextResponder] == _controller);
    check("direct-view-stacking-preserved", [view superview] == [_overlay superview] &&
        [[[view superview] subviews] indexOfObject:view] <
        [[[view superview] subviews] indexOfObject:_overlay]);
    check("autoresizing-masks-preserved",
        [view autoresizingMask] == (UIViewAutoresizingFlexibleTopMargin |
            UIViewAutoresizingFlexibleBottomMargin) &&
        [_overlay autoresizingMask] == (UIViewAutoresizingFlexibleLeftMargin |
            UIViewAutoresizingFlexibleTopMargin));
    const CGPoint hitPoint = [view convertPoint:[_button center] toView:_window];
    check("button-hit-test-preserved", [_window hitTest:hitPoint withEvent:nil] == _button);
    [timer invalidate];
    exit(0);
}

- (void)dealloc {
    [_overlay release];
    [_button release];
    [_controller release];
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
