#import "../LiquidGlass.h"
#import "../Shared/LGBannerCaptureSupport.h"
#import "../Shared/LGHookSupport.h"
#import "../Shared/LGSharedSupport.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

static CGFloat sControlCenterSmallModuleCornerRadius = 0.0;
static const CFTimeInterval kControlCenterDisplayLinkVisibilityGrace = 0.45;
static void *kControlCenterGlassKey = &kControlCenterGlassKey;
static void *kControlCenterBackdropViewKey = &kControlCenterBackdropViewKey;
static void *kControlCenterLastLiveCaptureTimeKey = &kControlCenterLastLiveCaptureTimeKey;
static void *kControlCenterFullscreenBlurCapKey = &kControlCenterFullscreenBlurCapKey;
static void *kControlCenterOriginalCornerStateKey = &kControlCenterOriginalCornerStateKey;
static void *kSpecularOnlyBlurScalingAllowedKey = &kSpecularOnlyBlurScalingAllowedKey;
static void *kSpecularOnlyBlurScalingAppliedScaleKey = &kSpecularOnlyBlurScalingAppliedScaleKey;
static LGDisplayLinkState sControlCenterDisplayLinkState = {0};
static LGDisplayLinkState sControlCenterFullscreenBlurCapState = {0};
static NSHashTable<UIView *> *sControlCenterLiveCaptureHosts = nil;
static NSHashTable<UIView *> *sControlCenterFullscreenBackdropMaterials = nil;
static CFTimeInterval sControlCenterLastVisibleHostTime = 0.0;
static BOOL sControlCenterScanPending = NO;
static BOOL sControlCenterBackdropBlurRetryPending = NO;
static BOOL sSpecularOnlyBlurScaleApplying = NO;
static NSUInteger sControlCenterRefreshCursor = 0;

static BOOL LGControlCenterEnabled(void) {
    return LG_globalEnabled() && LG_prefBool(@"ControlCenter.Enabled", YES);
}

static BOOL LGControlCenterClassNameEquals(UIView *view, NSString *className) {
    return view && [NSStringFromClass(view.class) isEqualToString:className];
}

static void LGControlCenterDetachGlass(UIView *host);

static void LGControlCenterRememberOriginalCornerState(UIView *view) {
    if (!view || objc_getAssociatedObject(view, kControlCenterOriginalCornerStateKey)) return;
    NSMutableDictionary<NSString *, id> *state = [@{
        @"clipsToBounds": @(view.clipsToBounds),
        @"masksToBounds": @(view.layer.masksToBounds),
        @"cornerRadius": @(view.layer.cornerRadius),
    } mutableCopy];
    if (@available(iOS 13.0, *)) {
        state[@"cornerCurve"] = view.layer.cornerCurve ?: @"";
    }
    objc_setAssociatedObject(view, kControlCenterOriginalCornerStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void LGControlCenterRestoreCornerState(UIView *view) {
    if (!view) return;
    NSDictionary<NSString *, id> *state = objc_getAssociatedObject(view, kControlCenterOriginalCornerStateKey);
    if (state) {
        view.clipsToBounds = [state[@"clipsToBounds"] boolValue];
        view.layer.masksToBounds = [state[@"masksToBounds"] boolValue];
        view.layer.cornerRadius = [state[@"cornerRadius"] doubleValue];
        if (@available(iOS 13.0, *)) {
            NSString *cornerCurve = state[@"cornerCurve"];
            if (cornerCurve.length) view.layer.cornerCurve = cornerCurve;
        }
        objc_setAssociatedObject(view, kControlCenterOriginalCornerStateKey, nil, OBJC_ASSOCIATION_ASSIGN);
    }
    LGControlCenterDetachGlass(view);
}

static void LGControlCenterRestoreCornerStateInTree(UIView *root) {
    if (!root) return;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count > 0) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        LGControlCenterRestoreCornerState(view);
        for (UIView *subview in view.subviews) {
            [stack addObject:subview];
        }
    }
}

static NSHashTable<UIView *> *LGControlCenterLiveCaptureHostRegistry(void) {
    if (!sControlCenterLiveCaptureHosts) {
        sControlCenterLiveCaptureHosts = [NSHashTable weakObjectsHashTable];
    }
    return sControlCenterLiveCaptureHosts;
}

static NSHashTable<UIView *> *LGControlCenterFullscreenBackdropMaterialRegistry(void) {
    if (!sControlCenterFullscreenBackdropMaterials) {
        sControlCenterFullscreenBackdropMaterials = [NSHashTable weakObjectsHashTable];
    }
    return sControlCenterFullscreenBackdropMaterials;
}

static void LGControlCenterApplyCornerRadius(UIView *view, CGFloat cornerRadius) {
    if (!view) return;
    if (!LGControlCenterEnabled()) {
        LGControlCenterRestoreCornerState(view);
        return;
    }
    if (cornerRadius <= 0.0) return;
    LGControlCenterRememberOriginalCornerState(view);
    view.clipsToBounds = YES;
    view.layer.masksToBounds = YES;
    view.layer.cornerRadius = cornerRadius;
    if (@available(iOS 13.0, *)) {
        view.layer.cornerCurve = kCACornerCurveCircular;
    }
}

static void LGControlCenterEnsureGlassForMaterialView(UIView *materialView, CGFloat cornerRadius);

static void LGControlCenterApplyGlassCornerRadius(UIView *view, CGFloat cornerRadius) {
    LGControlCenterApplyCornerRadius(view, cornerRadius);
    if (LGControlCenterClassNameEquals(view, @"MTMaterialView")) {
        LGControlCenterEnsureGlassForMaterialView(view, cornerRadius);
    }
}

static BOOL LGControlCenterHostIsVisible(UIView *host) {
    if (!host || !host.window || host.hidden || host.alpha <= 0.01f || host.layer.opacity <= 0.01f) return NO;
    UIView *current = host.superview;
    while (current && current != host.window) {
        if (current.hidden || current.alpha <= 0.01f || current.layer.opacity <= 0.01f) return NO;
        current = current.superview;
    }

    CALayer *layer = host.layer.presentationLayer ?: host.layer;
    CGRect bounds = layer.bounds;
    if (CGRectGetWidth(bounds) <= 1.0 || CGRectGetHeight(bounds) <= 1.0) return NO;
    CGRect windowFrame = [layer convertRect:bounds toLayer:host.window.layer];
    CGRect visibleBounds = CGRectInset(host.window.bounds, -8.0, -8.0);
    if (CGRectIntersectsRect(visibleBounds, windowFrame)) return YES;

    CGRect modelFrame = [host convertRect:host.bounds toView:host.window];
    return CGRectIntersectsRect(visibleBounds, modelFrame);
}

static BOOL LGControlCenterHostHasVisibleHierarchy(UIView *host) {
    if (!host || !host.window || host.hidden || host.alpha <= 0.01f || host.layer.opacity <= 0.01f) return NO;
    UIView *current = host.superview;
    while (current && current != host.window) {
        if (current.hidden || current.alpha <= 0.01f || current.layer.opacity <= 0.01f) return NO;
        current = current.superview;
    }
    return YES;
}

static NSString *LGControlCenterViewSummary(UIView *view) {
    if (!view) return @"(null)";
    return [NSString stringWithFormat:@"%p %@ frame=%@ bounds=%@ window=%d hidden=%d alpha=%.2f opacity=%.2f subviews=%lu",
            view,
            NSStringFromClass(view.class),
            NSStringFromCGRect(view.frame),
            NSStringFromCGRect(view.bounds),
            view.window ? 1 : 0,
            view.hidden ? 1 : 0,
            view.alpha,
            view.layer.opacity,
            (unsigned long)view.subviews.count];
}

static NSString *LGControlCenterAncestorChain(UIView *view) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    UIView *cursor = view;
    NSUInteger depth = 0;
    while (cursor && depth < 12) {
        [parts addObject:NSStringFromClass(cursor.class)];
        cursor = cursor.superview;
        depth++;
    }
    if (cursor) [parts addObject:@"..."];
    return [parts componentsJoinedByString:@" <- "];
}

static void LGControlCenterConfigureGlass(LiquidGlassView *glass, CGFloat cornerRadius) {
    if (!glass) return;
    glass.cornerRadius = cornerRadius;
    glass.bezelWidth = LG_prefFloat(@"ControlCenter.BezelWidth", 18.0);
    glass.glassThickness = LG_prefFloat(@"ControlCenter.GlassThickness", 120.0);
    glass.refractionScale = LG_prefFloat(@"ControlCenter.RefractionScale", 1.35);
    glass.refractiveIndex = LG_prefFloat(@"ControlCenter.RefractiveIndex", 1.2);
    glass.specularOpacity = LG_prefFloat(@"ControlCenter.SpecularOpacity", 0.55);
    glass.blur = LG_prefFloat(@"ControlCenter.Blur", 10.0);
    glass.wallpaperScale = LG_prefFloat(@"ControlCenter.WallpaperScale", 0.25);
    glass.releasesWallpaperAfterUpload = YES;
    glass.updateGroup = LGUpdateGroupControlCenter;
}

static void LGControlCenterSyncDisplayLinkActivity(void);

static CGFloat LGControlCenterFullscreenBackdropBlurRadius(void) {
    return fmax(0.0, LG_prefFloat(@"ControlCenter.FullscreenBackdropBlurRadius", 8.0));
}

static BOOL LGControlCenterIsBlurRadiusKey(NSString *key) {
    if (![key isKindOfClass:[NSString class]]) return NO;
    return [key isEqualToString:@"inputRadius"] ||
           [key isEqualToString:@"radius"] ||
           [key isEqualToString:@"inputBlurRadius"] ||
           [key isEqualToString:@"blurRadius"];
}

static id LGControlCenterClampedBlurRadiusValue(id value, CGFloat radius) {
    if (![value respondsToSelector:@selector(doubleValue)]) return value;
    CGFloat incoming = [value doubleValue];
    if (incoming <= radius) return value;
    return @(radius);
}

static BOOL LGSpecularOnlyExperimentalEnabled(void) {
    return NO;
}

static CGFloat LGSpecularOnlyExperimentalBlurScale(void) {
    CGFloat scale = LG_prefFloat(@"SpecularOnly.BlurScale", 0.8);
    if (LG_prefBool(@"SpecularOnly.ControlCenter.OverrideEnabled", NO)) {
        scale = LG_prefFloat(@"SpecularOnly.ControlCenter.BlurScale", scale);
    }
    return MAX(0.0, MIN(1.5, scale));
}

static id LGSpecularOnlyScaledBlurRadiusValue(id value) {
    if (![value respondsToSelector:@selector(doubleValue)]) return value;
    return @(MAX(0.0, [value doubleValue] * LGSpecularOnlyExperimentalBlurScale()));
}

static BOOL LGSpecularOnlyBlurScalingAllowedForObject(id object) {
    return object && [objc_getAssociatedObject(object, kSpecularOnlyBlurScalingAllowedKey) boolValue];
}

static void LGSpecularOnlySetBlurScalingAllowedForObject(id object, BOOL allowed) {
    if (!object) return;
    objc_setAssociatedObject(object,
                             kSpecularOnlyBlurScalingAllowedKey,
                             allowed ? @YES : nil,
                             allowed ? OBJC_ASSOCIATION_RETAIN_NONATOMIC : OBJC_ASSOCIATION_ASSIGN);
    if (!allowed) {
        objc_setAssociatedObject(object, kSpecularOnlyBlurScalingAppliedScaleKey, nil, OBJC_ASSOCIATION_ASSIGN);
    }
}

static void LGSpecularOnlyMarkBlurScalingLayerTree(CALayer *layer, BOOL allowed) {
    if (!layer) return;
    LGSpecularOnlySetBlurScalingAllowedForObject(layer, allowed);
    for (CALayer *sublayer in layer.sublayers) {
        LGSpecularOnlyMarkBlurScalingLayerTree(sublayer, allowed);
    }
}

static void __attribute__((unused)) LGSpecularOnlyMarkBlurScalingView(UIView *view, BOOL allowed) {
    if (!view) return;
    LGSpecularOnlySetBlurScalingAllowedForObject(view, allowed);
    LGSpecularOnlyMarkBlurScalingLayerTree(view.layer, allowed);
}

static void LGSpecularOnlyScaleBlurFilter(id filter) {
    if (!LGSpecularOnlyBlurScalingAllowedForObject(filter)) return;
    CGFloat scale = LGSpecularOnlyExperimentalBlurScale();
    NSNumber *appliedScale = objc_getAssociatedObject(filter, kSpecularOnlyBlurScalingAppliedScaleKey);
    if (appliedScale && fabs(appliedScale.doubleValue - scale) < 0.001) return;
    NSArray<NSString *> *candidateKeys = @[@"inputRadius", @"radius", @"inputBlurRadius", @"blurRadius"];
    for (NSString *key in candidateKeys) {
        @try {
            id currentValue = [filter valueForKey:key];
            id scaledValue = LGSpecularOnlyScaledBlurRadiusValue(currentValue);
            if (scaledValue != currentValue) {
                [filter setValue:scaledValue forKey:key];
            }
        } @catch (__unused NSException *exception) {
        }
    }
    objc_setAssociatedObject(filter, kSpecularOnlyBlurScalingAppliedScaleKey, @(scale), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void LGSpecularOnlyScaleBlurFilterArray(id filters) {
    if (![filters isKindOfClass:[NSArray class]]) return;
    BOOL wasApplying = sSpecularOnlyBlurScaleApplying;
    sSpecularOnlyBlurScaleApplying = YES;
    for (id filter in (NSArray *)filters) {
        LGSpecularOnlySetBlurScalingAllowedForObject(filter, YES);
        LGSpecularOnlyScaleBlurFilter(filter);
    }
    sSpecularOnlyBlurScaleApplying = wasApplying;
}

static void LGSpecularOnlyScaleBlurLayer(CALayer *layer) {
    if (!layer || !LGSpecularOnlyExperimentalEnabled() || !LGSpecularOnlyBlurScalingAllowedForObject(layer)) return;
    LGSpecularOnlyScaleBlurFilterArray(layer.filters);
    @try {
        LGSpecularOnlyScaleBlurFilterArray([layer valueForKey:@"backgroundFilters"]);
    } @catch (__unused NSException *exception) {
    }
    LGSpecularOnlyMarkBlurScalingLayerTree(layer, YES);
    for (CALayer *sublayer in layer.sublayers) {
        LGSpecularOnlyScaleBlurLayer(sublayer);
    }
}

static void __attribute__((unused)) LGSpecularOnlyScaleBlurForHookedView(UIView *view) {
    if (!LGSpecularOnlyBlurScalingAllowedForObject(view)) return;
    LGSpecularOnlyScaleBlurLayer(view.layer);
}

static void LGControlCenterMarkBlurCappedObject(id object, CGFloat radius) {
    if (!object) return;
    objc_setAssociatedObject(object, kControlCenterFullscreenBlurCapKey, @(radius), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void LGControlCenterClampBlurFilter(id filter, CGFloat radius) {
    if (!filter) return;
    LGControlCenterMarkBlurCappedObject(filter, radius);
    NSArray<NSString *> *candidateKeys = @[@"inputRadius", @"radius", @"inputBlurRadius", @"blurRadius"];
    for (NSString *key in candidateKeys) {
        @try {
            id currentValue = [filter valueForKey:key];
            id cappedValue = LGControlCenterClampedBlurRadiusValue(currentValue, radius);
            if (cappedValue != currentValue) {
                [filter setValue:cappedValue forKey:key];
            }
        } @catch (__unused NSException *exception) {
        }
    }
}

static void LGControlCenterClampBlurFilterArray(id filters, CGFloat radius) {
    if (![filters isKindOfClass:[NSArray class]]) return;
    for (id filter in (NSArray *)filters) {
        LGControlCenterClampBlurFilter(filter, radius);
    }
}

static void LGControlCenterMarkBlurCapOnLayer(CALayer *layer, CGFloat radius) {
    if (!layer) return;
    LGControlCenterMarkBlurCappedObject(layer, radius);
    LGControlCenterClampBlurFilterArray(layer.filters, radius);
    @try {
        LGControlCenterClampBlurFilterArray([layer valueForKey:@"backgroundFilters"], radius);
    } @catch (__unused NSException *exception) {
    }
    for (CALayer *sublayer in layer.sublayers) {
        LGControlCenterMarkBlurCapOnLayer(sublayer, radius);
    }
}

static void LGControlCenterClampBlurAnimation(CAAnimation *animation, CGFloat radius) {
    if (!animation) return;
    NSString *keyPath = nil;
    @try {
        keyPath = [animation valueForKey:@"keyPath"];
    } @catch (__unused NSException *exception) {
    }
    if (![keyPath isKindOfClass:[NSString class]]) return;
    NSString *lowerKeyPath = keyPath.lowercaseString;
    if (![lowerKeyPath containsString:@"radius"] && ![lowerKeyPath containsString:@"blur"]) return;

    if ([animation isKindOfClass:[CABasicAnimation class]]) {
        CABasicAnimation *basic = (CABasicAnimation *)animation;
        basic.fromValue = LGControlCenterClampedBlurRadiusValue(basic.fromValue, radius);
        basic.toValue = LGControlCenterClampedBlurRadiusValue(basic.toValue, radius);
        basic.byValue = LGControlCenterClampedBlurRadiusValue(basic.byValue, radius);
    } else if ([animation isKindOfClass:[CAKeyframeAnimation class]]) {
        CAKeyframeAnimation *keyframe = (CAKeyframeAnimation *)animation;
        NSMutableArray *values = nil;
        for (id value in keyframe.values) {
            if (!values) values = [NSMutableArray arrayWithCapacity:keyframe.values.count];
            [values addObject:LGControlCenterClampedBlurRadiusValue(value, radius)];
        }
        if (values) keyframe.values = values;
    } else if ([animation isKindOfClass:[CAAnimationGroup class]]) {
        CAAnimationGroup *group = (CAAnimationGroup *)animation;
        for (CAAnimation *child in group.animations) {
            LGControlCenterClampBlurAnimation(child, radius);
        }
    }
}

static void LGSpecularOnlyScaleBlurAnimation(CAAnimation *animation) {
    if (!animation) return;
    NSString *keyPath = nil;
    @try {
        keyPath = [animation valueForKey:@"keyPath"];
    } @catch (__unused NSException *exception) {
    }
    if (![keyPath isKindOfClass:[NSString class]]) return;
    NSString *lowerKeyPath = keyPath.lowercaseString;
    if (![lowerKeyPath containsString:@"radius"] && ![lowerKeyPath containsString:@"blur"]) return;

    if ([animation isKindOfClass:[CABasicAnimation class]]) {
        CABasicAnimation *basic = (CABasicAnimation *)animation;
        basic.fromValue = LGSpecularOnlyScaledBlurRadiusValue(basic.fromValue);
        basic.toValue = LGSpecularOnlyScaledBlurRadiusValue(basic.toValue);
        basic.byValue = LGSpecularOnlyScaledBlurRadiusValue(basic.byValue);
    } else if ([animation isKindOfClass:[CAKeyframeAnimation class]]) {
        CAKeyframeAnimation *keyframe = (CAKeyframeAnimation *)animation;
        NSMutableArray *values = nil;
        for (id value in keyframe.values) {
            if (!values) values = [NSMutableArray arrayWithCapacity:keyframe.values.count];
            [values addObject:LGSpecularOnlyScaledBlurRadiusValue(value)];
        }
        if (values) keyframe.values = values;
    } else if ([animation isKindOfClass:[CAAnimationGroup class]]) {
        CAAnimationGroup *group = (CAAnimationGroup *)animation;
        for (CAAnimation *child in group.animations) {
            LGSpecularOnlyScaleBlurAnimation(child);
        }
    }
}

static BOOL LGControlCenterRootLooksLikeOverlayView(UIView *root) {
    if (!root) return NO;
    BOOL hasScrollView = NO;
    BOOL hasHeaderPocket = NO;
    for (UIView *subview in root.subviews) {
        if (LGControlCenterClassNameEquals(subview, @"CCUIScrollView")) hasScrollView = YES;
        if (LGControlCenterClassNameEquals(subview, @"CCUIHeaderPocketView")) hasHeaderPocket = YES;
    }
    return hasScrollView || hasHeaderPocket;
}

static BOOL LGControlCenterIsFullscreenBackdropMaterialView(UIView *view) {
    if (!LGControlCenterClassNameEquals(view, @"MTMaterialView")) return NO;
    UIView *root = view.superview;
    if (!LGControlCenterRootLooksLikeOverlayView(root)) return NO;
    if (CGRectGetWidth(view.bounds) < 100.0 || CGRectGetHeight(view.bounds) < 100.0) return NO;
    return CGRectContainsRect(CGRectInset(root.bounds, -2.0, -2.0), view.frame);
}

static void LGControlCenterApplyFullscreenBackdropMaterialBlur(UIView *materialView) {
    if (!LGControlCenterEnabled() || !LGControlCenterIsFullscreenBackdropMaterialView(materialView)) return;
    [LGControlCenterFullscreenBackdropMaterialRegistry() addObject:materialView];
    materialView.hidden = NO;
    materialView.alpha = 1.0;
    materialView.layer.opacity = 1.0f;
    LGControlCenterMarkBlurCapOnLayer(materialView.layer, LGControlCenterFullscreenBackdropBlurRadius());
    sControlCenterFullscreenBlurCapState.activeCount = LGControlCenterFullscreenBackdropMaterialRegistry().allObjects.count;
    LGDisplayLinkStateDidChangeActivity(&sControlCenterFullscreenBlurCapState);
    if (sControlCenterFullscreenBlurCapState.activeCount > 0) {
        LGStartDisplayLinkStateWithPreferenceKey(&sControlCenterFullscreenBlurCapState,
                                                 LGPreferredLiveCaptureFramesPerSecond(15),
                                                 @"DisplayLink.ControlCenter.Enabled",
                                                 ^{
            NSArray<UIView *> *materials = LGControlCenterFullscreenBackdropMaterialRegistry().allObjects;
            for (UIView *material in materials) {
                if (!material.window || !LGControlCenterIsFullscreenBackdropMaterialView(material)) {
                    [LGControlCenterFullscreenBackdropMaterialRegistry() removeObject:material];
                    continue;
                }
                LGControlCenterApplyFullscreenBackdropMaterialBlur(material);
            }
            sControlCenterFullscreenBlurCapState.activeCount = LGControlCenterFullscreenBackdropMaterialRegistry().allObjects.count;
            LGDisplayLinkStateDidChangeActivity(&sControlCenterFullscreenBlurCapState);
            if (sControlCenterFullscreenBlurCapState.activeCount == 0) {
                LGStopDisplayLinkState(&sControlCenterFullscreenBlurCapState);
            }
        });
    }
}

static void LGControlCenterScheduleFullscreenBackdropMaterialBlur(UIView *materialView) {
    if (!LGControlCenterEnabled() || !materialView) return;
    __weak UIView *weakMaterialView = materialView;
    LGControlCenterApplyFullscreenBackdropMaterialBlur(materialView);
    int64_t delays[] = {
        (int64_t)(0.03 * NSEC_PER_SEC),
        (int64_t)(0.08 * NSEC_PER_SEC),
        (int64_t)(0.16 * NSEC_PER_SEC),
        (int64_t)(0.32 * NSEC_PER_SEC),
        (int64_t)(0.55 * NSEC_PER_SEC),
    };
    for (NSUInteger i = 0; i < sizeof(delays) / sizeof(delays[0]); i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delays[i]), dispatch_get_main_queue(), ^{
            LGControlCenterApplyFullscreenBackdropMaterialBlur(weakMaterialView);
        });
    }
}

static void LGControlCenterApplyFullscreenBackdropBlur(UIView *root) {
    if (!LGControlCenterEnabled() || !root) return;
    for (UIView *subview in root.subviews) {
        LGControlCenterApplyFullscreenBackdropMaterialBlur(subview);
    }
}

static void LGControlCenterScheduleFullscreenBackdropBlur(UIView *root) {
    if (!LGControlCenterEnabled() || !root) return;
    __weak UIView *weakRoot = root;
    LGControlCenterApplyFullscreenBackdropBlur(root);
    if (sControlCenterBackdropBlurRetryPending) return;
    sControlCenterBackdropBlurRetryPending = YES;
    int64_t delays[] = {
        (int64_t)(0.04 * NSEC_PER_SEC),
        (int64_t)(0.10 * NSEC_PER_SEC),
        (int64_t)(0.20 * NSEC_PER_SEC),
        (int64_t)(0.38 * NSEC_PER_SEC),
        (int64_t)(0.65 * NSEC_PER_SEC),
    };
    for (NSUInteger i = 0; i < sizeof(delays) / sizeof(delays[0]); i++) {
        BOOL finalPass = (i + 1 == sizeof(delays) / sizeof(delays[0]));
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delays[i]), dispatch_get_main_queue(), ^{
            LGControlCenterApplyFullscreenBackdropBlur(weakRoot);
            if (finalPass) sControlCenterBackdropBlurRetryPending = NO;
        });
    }
}

static void LGControlCenterDetachGlass(UIView *host) {
    if (!host) return;
    [LGControlCenterLiveCaptureHostRegistry() removeObject:host];
    LiquidGlassView *glass = objc_getAssociatedObject(host, kControlCenterGlassKey);
    [glass removeFromSuperview];
    objc_setAssociatedObject(host, kControlCenterGlassKey, nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(host, kControlCenterLastLiveCaptureTimeKey, nil, OBJC_ASSOCIATION_ASSIGN);
    LGRemoveLiveBackdropCaptureView(host, kControlCenterBackdropViewKey);
}

static BOOL LGControlCenterHostHasLiveBackdrop(UIView *host) {
    return objc_getAssociatedObject(host, kControlCenterBackdropViewKey) != nil;
}

static void LGControlCenterResetLiveBackdrops(NSString *reason) {
    NSUInteger count = 0;
    for (UIView *host in LGControlCenterLiveCaptureHostRegistry().allObjects) {
        if (!host) continue;
        LGRemoveLiveBackdropCaptureView(host, kControlCenterBackdropViewKey);
        objc_setAssociatedObject(host, kControlCenterLastLiveCaptureTimeKey, nil, OBJC_ASSOCIATION_ASSIGN);
        if (LG_prefersLiveCapture(@"ControlCenter.RenderingMode")) {
            LiquidGlassView *glass = objc_getAssociatedObject(host, kControlCenterGlassKey);
            glass.hidden = YES;
        }
        count++;
    }
    LGDebugLog(@"cc reset live backdrops reason=%@ hosts=%lu", reason ?: @"unknown", (unsigned long)count);
}

static void LGControlCenterEnsureGlassForMaterialViewWithOptions(UIView *materialView,
                                                                 CGFloat cornerRadius,
                                                                 BOOL allowLiveCapture,
                                                                 BOOL syncActivity) {
    if (!LGControlCenterEnabled()) return;
    BOOL liveMode = LG_prefersLiveCapture(@"ControlCenter.RenderingMode");
    BOOL hostVisible = LGControlCenterHostIsVisible(materialView);
    BOOL hostHierarchyVisible = LGControlCenterHostHasVisibleHierarchy(materialView);
    if (!hostHierarchyVisible) {
        LGDebugLog(@"cc ensure skip invisible host=%@ chain=%@",
                   LGControlCenterViewSummary(materialView),
                   LGControlCenterAncestorChain(materialView));
        return;
    }

    CGPoint snapshotOrigin = CGPointZero;
    UIImage *snapshot = LG_getHomescreenSnapshot(&snapshotOrigin);
    if (!snapshot && !LG_prefersLiveCapture(@"ControlCenter.RenderingMode")) {
        LGDebugLog(@"cc ensure skip no snapshot host=%@", LGControlCenterViewSummary(materialView));
        return;
    }

    LiquidGlassView *glass = objc_getAssociatedObject(materialView, kControlCenterGlassKey);
    BOOL hadGlass = (glass != nil);
    if (!glass) {
        LGDebugLog(@"cc inject glass host=%@ radius=%.2f snapshot=%d chain=%@",
                   LGControlCenterViewSummary(materialView),
                   cornerRadius,
                   snapshot ? 1 : 0,
                   LGControlCenterAncestorChain(materialView));
        glass = [[LiquidGlassView alloc] initWithFrame:materialView.bounds wallpaper:snapshot wallpaperOrigin:snapshotOrigin];
        glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        glass.userInteractionEnabled = NO;
        [materialView insertSubview:glass atIndex:0];
        objc_setAssociatedObject(materialView, kControlCenterGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        glass.frame = materialView.bounds;
        if (!LG_prefersLiveCapture(@"ControlCenter.RenderingMode")) {
            glass.wallpaperImage = snapshot;
        }
        if (glass.superview != materialView) {
            [glass removeFromSuperview];
            [materialView insertSubview:glass atIndex:0];
        }
    }

    LGControlCenterConfigureGlass(glass, cornerRadius);
    [LGControlCenterLiveCaptureHostRegistry() addObject:materialView];

    if (!hostVisible) {
        LGDebugLog(@"cc ensure registered offscreen host=%@ chain=%@",
                   LGControlCenterViewSummary(materialView),
                   LGControlCenterAncestorChain(materialView));
        [glass updateOrigin];
        if (syncActivity) LGControlCenterSyncDisplayLinkActivity();
        return;
    }

    BOOL hasLiveBackdrop = LGControlCenterHostHasLiveBackdrop(materialView);
    if (liveMode && !hasLiveBackdrop) {
        objc_setAssociatedObject(materialView, kControlCenterLastLiveCaptureTimeKey, nil, OBJC_ASSOCIATION_ASSIGN);
    }

    if (liveMode && !allowLiveCapture) {
        [glass updateOrigin];
        if (syncActivity) LGControlCenterSyncDisplayLinkActivity();
        return;
    }

    if (hasLiveBackdrop &&
        !LGShouldRefreshLiveCaptureForHost(materialView,
                                           @"ControlCenter.RenderingMode",
                                           kControlCenterLastLiveCaptureTimeKey,
                                           LG_prefFloat(@"ControlCenter.LiveCaptureFPS", 22.0),
                                           hadGlass)) {
        [glass updateOrigin];
        if (syncActivity) LGControlCenterSyncDisplayLinkActivity();
        return;
    }

    if (!LGApplyRenderingModeToGlassHost(materialView,
                                         glass,
                                         @"ControlCenter.RenderingMode",
                                         kControlCenterBackdropViewKey,
                                         snapshot,
                                         snapshotOrigin)) {
        LGDebugLog(@"cc rendering failed host=%@ hadGlass=%d snapshot=%d",
                   LGControlCenterViewSummary(materialView),
                   hadGlass ? 1 : 0,
                   snapshot ? 1 : 0);
        if (!hadGlass) LGControlCenterDetachGlass(materialView);
        if (syncActivity) LGControlCenterSyncDisplayLinkActivity();
        return;
    }

    glass.hidden = NO;
    if (liveMode) {
        if (LGControlCenterHostHasLiveBackdrop(materialView)) {
            LGMarkLiveCaptureRefreshedForHost(materialView, kControlCenterLastLiveCaptureTimeKey);
        } else {
            LGDebugLog(@"cc live fallback snapshot host=%@", LGControlCenterViewSummary(materialView));
            objc_setAssociatedObject(materialView, kControlCenterLastLiveCaptureTimeKey, nil, OBJC_ASSOCIATION_ASSIGN);
        }
    }
    if (syncActivity) LGControlCenterSyncDisplayLinkActivity();
}

static void LGControlCenterEnsureGlassForMaterialView(UIView *materialView, CGFloat cornerRadius) {
    LGControlCenterEnsureGlassForMaterialViewWithOptions(materialView, cornerRadius, YES, YES);
}

static void LGControlCenterRefreshLiveCaptureHosts(void) {
    NSArray<UIView *> *hosts = LGControlCenterLiveCaptureHostRegistry().allObjects;
    NSMutableArray<UIView *> *visibleHosts = [NSMutableArray array];
    NSMutableArray<UIView *> *missingBackdropHosts = [NSMutableArray array];
    for (UIView *host in hosts) {
        if (!host.window) {
            LGDebugLog(@"cc refresh detach no-window host=%@", LGControlCenterViewSummary(host));
            LGControlCenterDetachGlass(host);
            continue;
        }
        if (!LGControlCenterHostIsVisible(host)) continue;
        [visibleHosts addObject:host];
        if (!LGControlCenterHostHasLiveBackdrop(host)) [missingBackdropHosts addObject:host];
    }

    NSInteger captureBudget = MAX(1, MIN(4, (NSInteger)lround(LG_prefFloat(@"ControlCenter.LiveCaptureBudget", 2.0))));
    NSInteger capturesUsed = 0;
    NSMutableSet<UIView *> *captureHosts = [NSMutableSet set];

    for (UIView *host in missingBackdropHosts) {
        if (capturesUsed >= captureBudget) break;
        [captureHosts addObject:host];
        capturesUsed++;
    }

    NSUInteger visibleCount = visibleHosts.count;
    if (visibleCount > 0 && capturesUsed < captureBudget) {
        NSUInteger start = sControlCenterRefreshCursor % visibleCount;
        for (NSUInteger offset = 0; offset < visibleCount && capturesUsed < captureBudget; offset++) {
            UIView *host = visibleHosts[(start + offset) % visibleCount];
            if ([captureHosts containsObject:host]) continue;
            [captureHosts addObject:host];
            capturesUsed++;
        }
        sControlCenterRefreshCursor = (start + MAX((NSUInteger)1, (NSUInteger)capturesUsed)) % visibleCount;
    }

    for (UIView *host in visibleHosts) {
        CGFloat cornerRadius = host.layer.cornerRadius;
        if (cornerRadius <= 0.0) cornerRadius = fmin(CGRectGetWidth(host.bounds), CGRectGetHeight(host.bounds)) * 0.5;
        LGControlCenterEnsureGlassForMaterialViewWithOptions(host,
                                                             cornerRadius,
                                                             [captureHosts containsObject:host],
                                                             NO);
    }

    if (missingBackdropHosts.count > 0) {
        LGDebugLog(@"cc refresh visible=%lu missingBackdrop=%lu captures=%ld total=%lu",
                   (unsigned long)visibleHosts.count,
                   (unsigned long)missingBackdropHosts.count,
                   (long)capturesUsed,
                   (unsigned long)hosts.count);
    }

    sControlCenterDisplayLinkState.activeCount = visibleHosts.count;
    LGDisplayLinkStateDidChangeActivity(&sControlCenterDisplayLinkState);
}

static void LGControlCenterStartDisplayLink(void) {
    LGStartDisplayLinkStateWithPreferenceKey(&sControlCenterDisplayLinkState,
                                             LGPreferredLiveCaptureFramesPerSecond(LG_prefFloat(@"ControlCenter.LiveCaptureFPS", 22.0)),
                                             @"DisplayLink.ControlCenter.Enabled",
                                             ^{
        LGSetDisplayLinkStatePreferredFPS(&sControlCenterDisplayLinkState,
                                          LGPreferredLiveCaptureFramesPerSecond(LG_prefFloat(@"ControlCenter.LiveCaptureFPS", 22.0)));
        LGControlCenterRefreshLiveCaptureHosts();
    });
}

static void LGControlCenterSyncDisplayLinkActivity(void) {
    if (!LGControlCenterEnabled()) {
        sControlCenterDisplayLinkState.activeCount = 0;
        LGDisplayLinkStateDidChangeActivity(&sControlCenterDisplayLinkState);
        LGStopDisplayLinkState(&sControlCenterDisplayLinkState);
        return;
    }

    NSInteger visibleCount = 0;
    for (UIView *host in LGControlCenterLiveCaptureHostRegistry().allObjects) {
        if (LGControlCenterHostIsVisible(host)) visibleCount++;
    }

    CFTimeInterval now = CACurrentMediaTime();
    if (visibleCount > 0) {
        sControlCenterLastVisibleHostTime = now;
    }

    BOOL liveMode = LG_prefersLiveCapture(@"ControlCenter.RenderingMode");
    NSUInteger totalCount = LGControlCenterLiveCaptureHostRegistry().allObjects.count;
    BOOL withinVisibilityGrace = sControlCenterLastVisibleHostTime > 0.0 &&
        (now - sControlCenterLastVisibleHostTime) <= kControlCenterDisplayLinkVisibilityGrace;
    NSInteger effectiveVisibleCount = visibleCount;
    if (effectiveVisibleCount == 0 && liveMode && totalCount > 0 && withinVisibilityGrace) {
        effectiveVisibleCount = 1;
    }

    sControlCenterDisplayLinkState.activeCount = effectiveVisibleCount;
    LGDisplayLinkStateDidChangeActivity(&sControlCenterDisplayLinkState);
    if (effectiveVisibleCount > 0 && liveMode) {
        LGControlCenterStartDisplayLink();
    } else {
        LGStopDisplayLinkState(&sControlCenterDisplayLinkState);
    }
}

static BOOL LGControlCenterIsModuleCandidate(UIView *moduleView) {
    CGSize size = moduleView.bounds.size;
    CGFloat minSide = fmin(size.width, size.height);
    CGFloat maxSide = fmax(size.width, size.height);
    if (minSide < 20.0) return NO;
    return maxSide <= minSide * 1.25;
}

static CGFloat LGControlCenterModuleCornerRadius(UIView *moduleView) {
    CGFloat moduleHeight = CGRectGetHeight(moduleView.bounds);
    if (moduleHeight <= 0.0) return 0.0;

    CGFloat measuredRadius = moduleHeight * 0.5;
    if (moduleHeight < 100.0) {
        sControlCenterSmallModuleCornerRadius = measuredRadius;
        return measuredRadius;
    }
    return sControlCenterSmallModuleCornerRadius > 0.0 ? sControlCenterSmallModuleCornerRadius : measuredRadius;
}

static void LGControlCenterCirclifyModuleView(UIView *moduleView) {
    if (!LGControlCenterEnabled()) {
        LGControlCenterRestoreCornerStateInTree(moduleView);
        return;
    }
    if (!LGControlCenterClassNameEquals(moduleView, @"CCUIContentModuleContainerView")) return;
    if (!LGControlCenterIsModuleCandidate(moduleView)) return;

    UIView *contentContainer = nil;
    for (UIView *sub in moduleView.subviews) {
        if (LGControlCenterClassNameEquals(sub, @"CCUIContentModuleContentContainer") ||
            LGControlCenterClassNameEquals(sub, @"CCUIContentModuleContentContainerView")) {
            contentContainer = sub;
            break;
        }
    }

    CGFloat cornerRadius = LGControlCenterModuleCornerRadius(moduleView);
    LGControlCenterApplyCornerRadius(moduleView, cornerRadius);
    if (contentContainer) LGControlCenterApplyCornerRadius(contentContainer, cornerRadius);
}

static void LGControlCenterCirclifySquareModuleMaterialView(UIView *materialView) {
    if (!LGControlCenterEnabled()) {
        LGControlCenterRestoreCornerState(materialView);
        return;
    }
    if (!LGControlCenterClassNameEquals(materialView, @"MTMaterialView")) return;

    UIView *parent = materialView.superview;
    if (!LGControlCenterClassNameEquals(parent, @"CCUIContentModuleContentContainer") &&
        !LGControlCenterClassNameEquals(parent, @"CCUIContentModuleContentContainerView")) return;

    UIView *moduleView = nil;
    UIView *ancestor = parent.superview;
    while (ancestor) {
        if (LGControlCenterClassNameEquals(ancestor, @"CCUIContentModuleContainerView")) {
            moduleView = ancestor;
            break;
        }
        ancestor = ancestor.superview;
    }
    if (!moduleView || !LGControlCenterIsModuleCandidate(moduleView)) return;

    LGControlCenterApplyGlassCornerRadius(materialView, LGControlCenterModuleCornerRadius(moduleView));
}

static void LGControlCenterCirclifyMediaPlayerMaterialView(UIView *materialView) {
    if (!LGControlCenterEnabled()) {
        LGControlCenterRestoreCornerState(materialView);
        return;
    }
    if (!LGControlCenterClassNameEquals(materialView, @"MTMaterialView")) return;

    UIView *uiViewParent = materialView.superview;
    if (!LGControlCenterClassNameEquals(uiViewParent, @"UIView")) return;

    UIView *mruView = uiViewParent.superview;
    if (!LGControlCenterClassNameEquals(mruView, @"MRUControlCenterView")) return;

    UIView *contentContainer = mruView.superview;
    if (!LGControlCenterClassNameEquals(contentContainer, @"CCUIContentModuleContentContainer") &&
        !LGControlCenterClassNameEquals(contentContainer, @"CCUIContentModuleContentContainerView")) return;

    UIView *moduleView = nil;
    UIView *ancestor = contentContainer.superview;
    while (ancestor) {
        if (LGControlCenterClassNameEquals(ancestor, @"CCUIContentModuleContainerView")) {
            moduleView = ancestor;
            break;
        }
        ancestor = ancestor.superview;
    }
    if (!moduleView || !LGControlCenterIsModuleCandidate(moduleView)) return;

    LGControlCenterApplyGlassCornerRadius(materialView, LGControlCenterModuleCornerRadius(moduleView));
}

static void LGControlCenterCirclify1x2MaterialView(UIView *materialView) {
    if (!LGControlCenterEnabled()) {
        LGControlCenterRestoreCornerState(materialView);
        return;
    }
    if (!LGControlCenterClassNameEquals(materialView, @"MTMaterialView")) return;

    UIView *parent = materialView.superview;
    if (!LGControlCenterClassNameEquals(parent, @"CCUIContentModuleContentContainer") &&
        !LGControlCenterClassNameEquals(parent, @"CCUIContentModuleContentContainerView")) return;

    CGFloat width = CGRectGetWidth(materialView.bounds);
    CGFloat height = CGRectGetHeight(materialView.bounds);
    if (width <= 100.0 || height >= 100.0) return;

    BOOL hasUIViewSibling = NO;
    for (UIView *sibling in parent.subviews) {
        if (sibling != materialView && LGControlCenterClassNameEquals(sibling, @"UIView")) {
            hasUIViewSibling = YES;
            break;
        }
    }
    if (!hasUIViewSibling) return;

    LGControlCenterApplyGlassCornerRadius(materialView, height * 0.5);
}

static void LGControlCenterCirclifyFocusMaterialView(UIView *materialView) {
    if (!LGControlCenterEnabled()) {
        LGControlCenterRestoreCornerState(materialView);
        return;
    }
    if (!LGControlCenterClassNameEquals(materialView, @"MTMaterialView")) return;

    UIView *parent = materialView.superview;
    if (!LGControlCenterClassNameEquals(parent, @"UIView")) return;
    if (!LGControlCenterClassNameEquals(parent.superview, @"UIView")) return;
    if (!LGControlCenterClassNameEquals(parent.superview.superview, @"CCUIContentModuleContentContainerView")) return;

    CGFloat width = CGRectGetWidth(materialView.bounds);
    CGFloat height = CGRectGetHeight(materialView.bounds);
    if (width <= 100.0 || height >= 100.0) return;

    BOOL hasUIViewSibling = NO;
    for (UIView *sibling in parent.subviews) {
        if (sibling != materialView && LGControlCenterClassNameEquals(sibling, @"UIView")) {
            hasUIViewSibling = YES;
            break;
        }
    }
    if (!hasUIViewSibling) return;

    LGControlCenterApplyGlassCornerRadius(materialView, height * 0.5);
}

static void LGControlCenterApplyActivityControlMaterialView(UIView *materialView) {
    if (!LGControlCenterEnabled()) {
        LGControlCenterRestoreCornerState(materialView);
        return;
    }
    if (!LGControlCenterClassNameEquals(materialView, @"MTMaterialView")) return;

    UIView *contentView = materialView.superview;
    if (!LGControlCenterClassNameEquals(contentView, @"_FCUIActivityControlContentView")) return;
    if (!LGControlCenterClassNameEquals(contentView.superview, @"FCUIActivityControl")) return;

    CGFloat cornerRadius = materialView.layer.cornerRadius;
    if (cornerRadius <= 0.0) {
        cornerRadius = CGRectGetHeight(materialView.bounds) * 0.5;
    }
    LGControlCenterEnsureGlassForMaterialView(materialView, cornerRadius);
}

static void LGControlCenterCirclifyToggleFillView(UIView *buttonModuleView) {
    if (!LGControlCenterEnabled()) {
        LGControlCenterRestoreCornerStateInTree(buttonModuleView);
        return;
    }
    if (!LGControlCenterClassNameEquals(buttonModuleView, @"CCUIButtonModuleView")) return;

    UIView *moduleView = nil;
    UIView *ancestor = buttonModuleView.superview;
    while (ancestor) {
        if (LGControlCenterClassNameEquals(ancestor, @"CCUIContentModuleContainerView")) {
            moduleView = ancestor;
            break;
        }
        ancestor = ancestor.superview;
    }
    if (!moduleView || !LGControlCenterIsModuleCandidate(moduleView)) return;

    CGFloat cornerRadius = LGControlCenterModuleCornerRadius(moduleView);
    for (UIView *child in buttonModuleView.subviews) {
        if (LGControlCenterClassNameEquals(child, @"UIView")) {
            LGControlCenterApplyCornerRadius(child, cornerRadius);
        }
    }
}

static void LGControlCenterApplySliderSiblingMaterialRadius(UIView *sliderView) {
    UIView *parent = sliderView.superview;
    if (!parent) return;
    if (!LGControlCenterClassNameEquals(parent, @"CCUIContentModuleContentContainer") &&
        !LGControlCenterClassNameEquals(parent, @"CCUIContentModuleContentContainerView")) return;

    for (UIView *sibling in parent.subviews) {
        if (sibling == sliderView) continue;
        if (LGControlCenterClassNameEquals(sibling, @"MTMaterialView")) {
            LGControlCenterApplyGlassCornerRadius(sibling, CGRectGetWidth(sibling.bounds) * 0.5);
        }
    }
}

static void LGControlCenterApplySliderFillRadius(UIView *sliderView) {
    for (UIView *child in sliderView.subviews) {
        if (!LGControlCenterClassNameEquals(child, @"UIView")) continue;
        for (UIView *grandchild in child.subviews) {
            if (LGControlCenterClassNameEquals(grandchild, @"MTMaterialView")) {
                LGControlCenterApplyCornerRadius(grandchild, CGRectGetWidth(grandchild.bounds) * 0.5);
            }
        }
    }
}

static BOOL LGControlCenterHasAncestorNamed(UIView *view, NSString *className) {
    if (!view || !className.length) return NO;
    UIView *ancestor = view.superview;
    while (ancestor) {
        if (LGControlCenterClassNameEquals(ancestor, className)) return YES;
        ancestor = ancestor.superview;
    }
    return NO;
}

static BOOL LGControlCenterMaterialIsInsideSlider(UIView *materialView) {
    return LGControlCenterHasAncestorNamed(materialView, @"CCUIContinuousSliderView") ||
        LGControlCenterHasAncestorNamed(materialView, @"MRUContinuousSliderView");
}

static void LGControlCenterApplySliderViewRadii(UIView *sliderView) {
    if (!LGControlCenterEnabled()) {
        LGControlCenterRestoreCornerStateInTree(sliderView);
        return;
    }
    if (!LGControlCenterClassNameEquals(sliderView, @"CCUIContinuousSliderView")) return;

    LGControlCenterApplySliderSiblingMaterialRadius(sliderView);
    LGControlCenterApplySliderFillRadius(sliderView);
}

static void LGControlCenterApplyMRUSliderViewRadii(UIView *sliderView) {
    if (!LGControlCenterEnabled()) {
        LGControlCenterRestoreCornerStateInTree(sliderView);
        return;
    }
    if (!LGControlCenterClassNameEquals(sliderView, @"MRUContinuousSliderView")) return;

    for (UIView *child in sliderView.subviews) {
        if (LGControlCenterClassNameEquals(child, @"MTMaterialView")) {
            LGControlCenterApplyGlassCornerRadius(child, CGRectGetWidth(child.bounds) * 0.5);
        } else if (LGControlCenterClassNameEquals(child, @"UIView")) {
            for (UIView *grandchild in child.subviews) {
                if (LGControlCenterClassNameEquals(grandchild, @"MTMaterialView")) {
                    LGControlCenterApplyCornerRadius(grandchild, CGRectGetWidth(grandchild.bounds) * 0.5);
                }
            }
        }
    }
}

static void LGControlCenterRoundContentContainerMaterialViews(UIView *contentContainer) {
    if (!LGControlCenterEnabled()) {
        LGControlCenterRestoreCornerStateInTree(contentContainer);
        return;
    }
    if (!LGControlCenterClassNameEquals(contentContainer, @"CCUIContentModuleContentContainer") &&
        !LGControlCenterClassNameEquals(contentContainer, @"CCUIContentModuleContentContainerView")) return;

    @try {
        BOOL expanded = [contentContainer valueForKey:@"_expanded"] != nil &&
                        [[contentContainer valueForKey:@"_expanded"] boolValue];
        if (expanded) return;
    } @catch (NSException *e) {}

    UIView *moduleView = nil;
    UIView *ancestor = contentContainer.superview;
    while (ancestor) {
        if (LGControlCenterClassNameEquals(ancestor, @"CCUIContentModuleContainerView")) {
            moduleView = ancestor;
            break;
        }
        ancestor = ancestor.superview;
    }

    NSMutableArray *stack = [NSMutableArray arrayWithArray:contentContainer.subviews];
    while (stack.count > 0) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];

        if (LGControlCenterClassNameEquals(view, @"MTMaterialView")) {
            CGFloat width = CGRectGetWidth(view.bounds);
            CGFloat height = CGRectGetHeight(view.bounds);

            if (moduleView && LGControlCenterIsModuleCandidate(moduleView)) {
                if (LGControlCenterMaterialIsInsideSlider(view)) {
                    LGControlCenterApplyCornerRadius(view, LGControlCenterModuleCornerRadius(moduleView));
                } else {
                    LGControlCenterApplyGlassCornerRadius(view, LGControlCenterModuleCornerRadius(moduleView));
                }
            } else if (width > 100.0 && height < 100.0) {
                if (LGControlCenterMaterialIsInsideSlider(view)) {
                    LGControlCenterApplyCornerRadius(view, height * 0.5);
                } else {
                    LGControlCenterApplyGlassCornerRadius(view, height * 0.5);
                }
            } else {
                LGControlCenterApplyCornerRadius(view, width * 0.5);
            }
        }

        [stack addObjectsFromArray:view.subviews];
    }
}

static void LGControlCenterApplyKnownView(UIView *view) {
    if (LGControlCenterClassNameEquals(view, @"CCUIContentModuleContainerView")) {
        LGControlCenterCirclifyModuleView(view);
    } else if (LGControlCenterClassNameEquals(view, @"CCUIContentModuleContentContainer") ||
               LGControlCenterClassNameEquals(view, @"CCUIContentModuleContentContainerView")) {
        LGControlCenterRoundContentContainerMaterialViews(view);
    } else if (LGControlCenterClassNameEquals(view, @"MTMaterialView")) {
        LGControlCenterCirclifySquareModuleMaterialView(view);
        LGControlCenterCirclifyMediaPlayerMaterialView(view);
        LGControlCenterCirclify1x2MaterialView(view);
        LGControlCenterCirclifyFocusMaterialView(view);
        LGControlCenterApplyActivityControlMaterialView(view);
    } else if (LGControlCenterClassNameEquals(view, @"CCUIButtonModuleView")) {
        LGControlCenterCirclifyToggleFillView(view);
    } else if (LGControlCenterClassNameEquals(view, @"CCUIContinuousSliderView")) {
        LGControlCenterApplySliderViewRadii(view);
    } else if (LGControlCenterClassNameEquals(view, @"MRUContinuousSliderView")) {
        LGControlCenterApplyMRUSliderViewRadii(view);
    }
}

static void LGControlCenterScanViewTree(UIView *root) {
    if (!root) return;
    if (!LGControlCenterEnabled()) {
        LGControlCenterRestoreCornerStateInTree(root);
        LGControlCenterSyncDisplayLinkActivity();
        return;
    }
    LGControlCenterApplyFullscreenBackdropBlur(root);
    __block NSUInteger visited = 0;
    __block NSUInteger materialCount = 0;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count > 0) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        visited++;
        if (LGControlCenterClassNameEquals(view, @"MTMaterialView")) materialCount++;
        LGControlCenterApplyKnownView(view);
        for (UIView *subview in view.subviews) {
            [stack addObject:subview];
        }
    }
    LGDebugLog(@"cc scan root=%@ visited=%lu materials=%lu registered=%lu",
               LGControlCenterViewSummary(root),
               (unsigned long)visited,
               (unsigned long)materialCount,
               (unsigned long)LGControlCenterLiveCaptureHostRegistry().allObjects.count);
    LGControlCenterSyncDisplayLinkActivity();
}

static void LGControlCenterScheduleViewScan(UIView *root) {
    if (!root) return;
    if (!LGControlCenterEnabled()) {
        LGControlCenterRestoreCornerStateInTree(root);
        LGControlCenterSyncDisplayLinkActivity();
        return;
    }
    __weak UIView *weakRoot = root;
    if (sControlCenterScanPending) return;
    sControlCenterScanPending = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        sControlCenterScanPending = NO;
        LGControlCenterScanViewTree(weakRoot);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        LGControlCenterScanViewTree(weakRoot);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.20 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        LGControlCenterScanViewTree(weakRoot);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.42 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        LGControlCenterScanViewTree(weakRoot);
    });
}

%group LGControlCenterSpringBoard

%hook CCUIContentModuleContainerView

- (void)willMoveToWindow:(UIWindow *)newWindow {
    LGControlCenterCirclifyModuleView((UIView *)self);
    %orig;
    LGControlCenterCirclifyModuleView((UIView *)self);
}

- (void)didMoveToWindow {
    %orig;
    LGControlCenterCirclifyModuleView((UIView *)self);
}

- (void)layoutSubviews {
    %orig;
    LGControlCenterCirclifyModuleView((UIView *)self);
}

%end

%hook CCUIContentModuleContentContainerView

- (void)didMoveToWindow {
    %orig;
    LGControlCenterRoundContentContainerMaterialViews((UIView *)self);
}

- (void)layoutSubviews {
    %orig;
    LGControlCenterRoundContentContainerMaterialViews((UIView *)self);
}

%end

%hook CCUIContentModuleContentContainer

- (void)didMoveToWindow {
    %orig;
    LGControlCenterRoundContentContainerMaterialViews((UIView *)self);
}

- (void)layoutSubviews {
    %orig;
    LGControlCenterRoundContentContainerMaterialViews((UIView *)self);
}

%end

%hook MTMaterialView

- (void)willMoveToSuperview:(UIView *)newSuperview {
    LGControlCenterScheduleFullscreenBackdropMaterialBlur((UIView *)self);
    LGControlCenterCirclifySquareModuleMaterialView((UIView *)self);
    LGControlCenterCirclifyMediaPlayerMaterialView((UIView *)self);
    LGControlCenterCirclify1x2MaterialView((UIView *)self);
    LGControlCenterCirclifyFocusMaterialView((UIView *)self);
    LGControlCenterApplyActivityControlMaterialView((UIView *)self);
    %orig;
    LGControlCenterScheduleFullscreenBackdropMaterialBlur((UIView *)self);
    LGControlCenterCirclifySquareModuleMaterialView((UIView *)self);
    LGControlCenterCirclifyMediaPlayerMaterialView((UIView *)self);
    LGControlCenterCirclify1x2MaterialView((UIView *)self);
    LGControlCenterCirclifyFocusMaterialView((UIView *)self);
    LGControlCenterApplyActivityControlMaterialView((UIView *)self);
}

- (void)didMoveToSuperview {
    %orig;
    LGControlCenterScheduleFullscreenBackdropMaterialBlur((UIView *)self);
    LGControlCenterCirclifySquareModuleMaterialView((UIView *)self);
    LGControlCenterCirclifyMediaPlayerMaterialView((UIView *)self);
    LGControlCenterCirclify1x2MaterialView((UIView *)self);
    LGControlCenterCirclifyFocusMaterialView((UIView *)self);
    LGControlCenterApplyActivityControlMaterialView((UIView *)self);
}

- (void)willMoveToWindow:(UIWindow *)newWindow {
    LGControlCenterScheduleFullscreenBackdropMaterialBlur((UIView *)self);
    LGControlCenterCirclifySquareModuleMaterialView((UIView *)self);
    LGControlCenterCirclifyMediaPlayerMaterialView((UIView *)self);
    LGControlCenterCirclify1x2MaterialView((UIView *)self);
    LGControlCenterCirclifyFocusMaterialView((UIView *)self);
    LGControlCenterApplyActivityControlMaterialView((UIView *)self);
    %orig;
    LGControlCenterScheduleFullscreenBackdropMaterialBlur((UIView *)self);
    LGControlCenterCirclifySquareModuleMaterialView((UIView *)self);
    LGControlCenterCirclifyMediaPlayerMaterialView((UIView *)self);
    LGControlCenterCirclify1x2MaterialView((UIView *)self);
    LGControlCenterCirclifyFocusMaterialView((UIView *)self);
    LGControlCenterApplyActivityControlMaterialView((UIView *)self);
}

- (void)didMoveToWindow {
    %orig;
    LGControlCenterScheduleFullscreenBackdropMaterialBlur((UIView *)self);
    LGControlCenterCirclifySquareModuleMaterialView((UIView *)self);
    LGControlCenterCirclifyMediaPlayerMaterialView((UIView *)self);
    LGControlCenterCirclify1x2MaterialView((UIView *)self);
    LGControlCenterCirclifyFocusMaterialView((UIView *)self);
    LGControlCenterApplyActivityControlMaterialView((UIView *)self);
}

- (void)layoutSubviews {
    %orig;
    LGControlCenterScheduleFullscreenBackdropMaterialBlur((UIView *)self);
    LGControlCenterCirclifySquareModuleMaterialView((UIView *)self);
    LGControlCenterCirclifyMediaPlayerMaterialView((UIView *)self);
    LGControlCenterCirclify1x2MaterialView((UIView *)self);
    LGControlCenterCirclifyFocusMaterialView((UIView *)self);
    LGControlCenterApplyActivityControlMaterialView((UIView *)self);
}

%end

%hook UIVisualEffectView

- (void)didMoveToWindow {
    %orig;
}

- (void)layoutSubviews {
    %orig;
}

%end

%hook CAFilter

- (void)setValue:(id)value forKey:(NSString *)key {
    if (!sSpecularOnlyBlurScaleApplying &&
        LGSpecularOnlyExperimentalEnabled() &&
        LGSpecularOnlyBlurScalingAllowedForObject(self) &&
        LGControlCenterIsBlurRadiusKey(key)) {
        value = LGSpecularOnlyScaledBlurRadiusValue(value);
    }
    NSNumber *radius = objc_getAssociatedObject(self, kControlCenterFullscreenBlurCapKey);
    if (radius && LGControlCenterEnabled() && LGControlCenterIsBlurRadiusKey(key)) {
        value = LGControlCenterClampedBlurRadiusValue(value, radius.doubleValue);
    }
    %orig(value, key);
}

- (void)setValue:(id)value forKeyPath:(NSString *)keyPath {
    if (!sSpecularOnlyBlurScaleApplying &&
        LGSpecularOnlyExperimentalEnabled() &&
        LGSpecularOnlyBlurScalingAllowedForObject(self) &&
        [keyPath isKindOfClass:[NSString class]]) {
        NSString *lastKey = [keyPath componentsSeparatedByString:@"."].lastObject;
        if (LGControlCenterIsBlurRadiusKey(lastKey)) {
            value = LGSpecularOnlyScaledBlurRadiusValue(value);
        }
    }
    NSNumber *radius = objc_getAssociatedObject(self, kControlCenterFullscreenBlurCapKey);
    if (radius && LGControlCenterEnabled() && [keyPath isKindOfClass:[NSString class]]) {
        NSString *lastKey = [keyPath componentsSeparatedByString:@"."].lastObject;
        if (LGControlCenterIsBlurRadiusKey(lastKey)) {
            value = LGControlCenterClampedBlurRadiusValue(value, radius.doubleValue);
        }
    }
    %orig(value, keyPath);
}

%end

%hook CALayer

- (void)setFilters:(NSArray *)filters {
    if (LGSpecularOnlyExperimentalEnabled() && LGSpecularOnlyBlurScalingAllowedForObject(self)) {
        LGSpecularOnlyScaleBlurFilterArray(filters);
    }
    NSNumber *radius = objc_getAssociatedObject(self, kControlCenterFullscreenBlurCapKey);
    if (radius && LGControlCenterEnabled()) {
        LGControlCenterClampBlurFilterArray(filters, radius.doubleValue);
    }
    %orig(filters);
}

- (void)setValue:(id)value forKey:(NSString *)key {
    if (LGSpecularOnlyExperimentalEnabled() &&
        LGSpecularOnlyBlurScalingAllowedForObject(self) &&
        [key isEqualToString:@"backgroundFilters"]) {
        LGSpecularOnlyScaleBlurFilterArray(value);
    }
    NSNumber *radius = objc_getAssociatedObject(self, kControlCenterFullscreenBlurCapKey);
    if (radius && LGControlCenterEnabled() && [key isEqualToString:@"backgroundFilters"]) {
        LGControlCenterClampBlurFilterArray(value, radius.doubleValue);
    }
    %orig(value, key);
}

- (void)setValue:(id)value forKeyPath:(NSString *)keyPath {
    if (LGSpecularOnlyExperimentalEnabled() &&
        LGSpecularOnlyBlurScalingAllowedForObject(self) &&
        [keyPath isKindOfClass:[NSString class]]) {
        NSString *lastKey = [keyPath componentsSeparatedByString:@"."].lastObject;
        if (LGControlCenterIsBlurRadiusKey(lastKey)) {
            value = LGSpecularOnlyScaledBlurRadiusValue(value);
        }
    }
    NSNumber *radius = objc_getAssociatedObject(self, kControlCenterFullscreenBlurCapKey);
    if (radius && LGControlCenterEnabled() && [keyPath isKindOfClass:[NSString class]]) {
        NSString *lastKey = [keyPath componentsSeparatedByString:@"."].lastObject;
        if (LGControlCenterIsBlurRadiusKey(lastKey)) {
            value = LGControlCenterClampedBlurRadiusValue(value, radius.doubleValue);
        }
    }
    %orig(value, keyPath);
}

- (void)addAnimation:(CAAnimation *)animation forKey:(NSString *)key {
    if (LGSpecularOnlyExperimentalEnabled() && LGSpecularOnlyBlurScalingAllowedForObject(self)) {
        LGSpecularOnlyScaleBlurAnimation(animation);
    }
    NSNumber *radius = objc_getAssociatedObject(self, kControlCenterFullscreenBlurCapKey);
    if (radius && LGControlCenterEnabled()) {
        LGControlCenterClampBlurAnimation(animation, radius.doubleValue);
    }
    %orig(animation, key);
}

%end

%hook CCUIButtonModuleView

- (void)willMoveToWindow:(UIWindow *)newWindow {
    %orig;
    LGControlCenterCirclifyToggleFillView((UIView *)self);
}

- (void)didMoveToWindow {
    %orig;
    LGControlCenterCirclifyToggleFillView((UIView *)self);
}

- (void)layoutSubviews {
    %orig;
    LGControlCenterCirclifyToggleFillView((UIView *)self);
}

%end

%hook CCUIContinuousSliderView

- (void)willMoveToWindow:(UIWindow *)newWindow {
    %orig;
    LGControlCenterApplySliderViewRadii((UIView *)self);
}

- (void)didMoveToWindow {
    %orig;
    LGControlCenterApplySliderViewRadii((UIView *)self);
}

- (void)layoutSubviews {
    %orig;
    LGControlCenterApplySliderViewRadii((UIView *)self);
}

%end

%hook MRUContinuousSliderView

- (void)willMoveToWindow:(UIWindow *)newWindow {
    %orig;
    LGControlCenterApplyMRUSliderViewRadii((UIView *)self);
}

- (void)didMoveToWindow {
    %orig;
    LGControlCenterApplyMRUSliderViewRadii((UIView *)self);
}

- (void)layoutSubviews {
    %orig;
    LGControlCenterApplyMRUSliderViewRadii((UIView *)self);
}

%end

%hook CCUIModularControlCenterOverlayViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    if (!LGControlCenterEnabled()) {
        LGControlCenterRestoreCornerStateInTree(((UIViewController *)self).view);
        LGControlCenterSyncDisplayLinkActivity();
        return;
    }
    LGControlCenterResetLiveBackdrops(@"viewWillAppear");
    LGControlCenterScheduleFullscreenBackdropBlur(((UIViewController *)self).view);
    LGControlCenterScheduleViewScan(((UIViewController *)self).view);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (!LGControlCenterEnabled()) {
        LGControlCenterRestoreCornerStateInTree(((UIViewController *)self).view);
        LGControlCenterSyncDisplayLinkActivity();
        return;
    }
    LGControlCenterScheduleFullscreenBackdropBlur(((UIViewController *)self).view);
    LGControlCenterScheduleViewScan(((UIViewController *)self).view);
}

- (void)viewWillDisappear:(BOOL)animated {
    if (LGControlCenterEnabled()) {
        LGControlCenterResetLiveBackdrops(@"viewWillDisappear");
    } else {
        LGControlCenterRestoreCornerStateInTree(((UIViewController *)self).view);
        LGControlCenterSyncDisplayLinkActivity();
    }
    %orig;
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    if (LGControlCenterEnabled()) {
        LGControlCenterResetLiveBackdrops(@"viewDidDisappear");
    } else {
        LGControlCenterRestoreCornerStateInTree(((UIViewController *)self).view);
    }
    LGControlCenterSyncDisplayLinkActivity();
}

- (void)viewDidLayoutSubviews {
    %orig;
    if (!LGControlCenterEnabled()) {
        LGControlCenterRestoreCornerStateInTree(((UIViewController *)self).view);
        LGControlCenterSyncDisplayLinkActivity();
        return;
    }
    LGControlCenterScheduleFullscreenBackdropBlur(((UIViewController *)self).view);
    LGControlCenterScheduleViewScan(((UIViewController *)self).view);
}

%end

%end

%ctor {
    if (!LGIsSpringBoardProcess()) return;
    %init(LGControlCenterSpringBoard);
}
