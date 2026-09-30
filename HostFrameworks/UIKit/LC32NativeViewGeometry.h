#pragma once

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

/* Scene callbacks may have no guest CPU context. Use UIView's base methods
 * without invoking geometry overrides on a mirrored guest subclass. */
static inline CGRect LC32NativeViewBounds(UIView *view) {
    using Getter = CGRect (*)(id, SEL);
    static Getter getter = reinterpret_cast<Getter>(
        class_getMethodImplementation(UIView.class, @selector(bounds)));
    return view ? getter(view, @selector(bounds)) : CGRectZero;
}

static inline CGPoint LC32NativeViewCenter(UIView *view) {
    using Getter = CGPoint (*)(id, SEL);
    static Getter getter = reinterpret_cast<Getter>(
        class_getMethodImplementation(UIView.class, @selector(center)));
    return view ? getter(view, @selector(center)) : CGPointZero;
}

static inline CGAffineTransform LC32NativeViewTransform(UIView *view) {
    using Getter = CGAffineTransform (*)(id, SEL);
    static Getter getter = reinterpret_cast<Getter>(
        class_getMethodImplementation(UIView.class, @selector(transform)));
    return view ? getter(view, @selector(transform)) : CGAffineTransformIdentity;
}

static inline CALayer *LC32NativeViewLayer(UIView *view) {
    using Getter = CALayer *(*)(id, SEL);
    static Getter getter = reinterpret_cast<Getter>(
        class_getMethodImplementation(UIView.class, @selector(layer)));
    return view ? getter(view, @selector(layer)) : nil;
}

static inline CGPoint LC32NativeConvertViewPoint(
        UIView *view, CGPoint point, UIView *sourceView) {
    using Converter = CGPoint (*)(id, SEL, CGPoint, UIView *);
    static Converter converter = reinterpret_cast<Converter>(
        class_getMethodImplementation(UIView.class,
            @selector(convertPoint:fromView:)));
    return converter(view, @selector(convertPoint:fromView:), point, sourceView);
}

static inline void LC32NativeSetViewBounds(UIView *view, CGRect bounds) {
    using Setter = void (*)(id, SEL, CGRect);
    static Setter setter = reinterpret_cast<Setter>(
        class_getMethodImplementation(UIView.class, @selector(setBounds:)));
    if(view) setter(view, @selector(setBounds:), bounds);
}

static inline void LC32NativeSetViewCenter(UIView *view, CGPoint center) {
    using Setter = void (*)(id, SEL, CGPoint);
    static Setter setter = reinterpret_cast<Setter>(
        class_getMethodImplementation(UIView.class, @selector(setCenter:)));
    if(view) setter(view, @selector(setCenter:), center);
}

static inline void LC32NativeSetViewTransform(
        UIView *view, CGAffineTransform transform) {
    using Setter = void (*)(id, SEL, CGAffineTransform);
    static Setter setter = reinterpret_cast<Setter>(
        class_getMethodImplementation(UIView.class, @selector(setTransform:)));
    if(view) setter(view, @selector(setTransform:), transform);
}

static inline bool LC32AnimationChangesCanvasGeometry(CAAnimation *animation) {
    if(![animation isKindOfClass:CAPropertyAnimation.class]) return false;
    NSString *keyPath = ((CAPropertyAnimation *)animation).keyPath;
    for(NSString *property in @[@"bounds", @"position", @"transform"]) {
        if([keyPath isEqualToString:property] ||
                [keyPath hasPrefix:[property stringByAppendingString:@"."]]) {
            return true;
        }
    }
    return false;
}

static inline void LC32CancelCanvasGeometryAnimations(UIView *view,
        bool preserveTransformAnimation) {
    CALayer *layer = LC32NativeViewLayer(view);
    for(NSString *key in layer.animationKeys) {
        CAAnimation *animation = [layer animationForKey:key];
        if(!LC32AnimationChangesCanvasGeometry(animation)) continue;
        NSString *keyPath = ((CAPropertyAnimation *)animation).keyPath;
        if(preserveTransformAnimation &&
                ([keyPath isEqualToString:@"transform"] ||
                 [keyPath hasPrefix:@"transform."])) {
            continue;
        }
        [layer removeAnimationForKey:key];
    }
}

static inline void LC32ApplyNativeCanvasGeometry(UIView *view, CGRect bounds,
        CGPoint center, CGAffineTransform transform,
        bool preserveTransformAnimation = false) {
    if(!view) return;
    const BOOL boundsChanged = !CGRectEqualToRect(
        LC32NativeViewBounds(view), bounds);
    const BOOL centerChanged = !CGPointEqualToPoint(
        LC32NativeViewCenter(view), center);
    const BOOL transformChanged = !CGAffineTransformEqualToTransform(
        LC32NativeViewTransform(view), transform);
    /* UIKit can enqueue a root resize before this fit restores the model
     * geometry. Disabling actions below does not remove that existing
     * animation, even when the model already matches the fixed canvas.
     * This helper owns only canvas geometry; leave other animations alone. */
    // A native landscape turn animates the renderer and backing together.
    // Preserve that turn when fitting changes only its extent or placement.
    // Portrait canvas scaling and an authored initial pose still cancel a
    // conflicting transform along with stale resize animations.
    LC32CancelCanvasGeometryAnimations(view,
        preserveTransformAnimation && !transformChanged);
    if(!boundsChanged && !centerChanged && !transformChanged) return;

    /* A refit compensates for the host's coordinate-space change. It must
     * reach the same submitted frame and must not acquire an independent
     * resize animation from the surrounding UIKit transition. Never reset
     * the transform through identity or write unchanged geometry. */
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    @try {
        [UIView performWithoutAnimation:^{
            if(boundsChanged) LC32NativeSetViewBounds(view, bounds);
            if(centerChanged) LC32NativeSetViewCenter(view, center);
            if(transformChanged) LC32NativeSetViewTransform(view, transform);
        }];
    } @finally {
        [CATransaction commit];
    }
}
