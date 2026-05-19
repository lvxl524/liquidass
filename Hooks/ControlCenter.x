#import "../LiquidGlass.h"
#import "../Shared/LGHookSupport.h"
#import "../Shared/LGBannerCaptureSupport.h"
#import "../Shared/LGPrefAccessors.h"
#import <objc/runtime.h>

static const NSInteger kControlCenterTintTag = 0xCC26;

static void *kControlCenterGlassKey = &kControlCenterGlassKey;
static void *kControlCenterTintKey = &kControlCenterTintKey;
static void *kControlCenterBackdropViewKey = &kControlCenterBackdropViewKey;
static void *kControlCenterLastLiveCaptureTimeKey = &kControlCenterLastLiveCaptureTimeKey;
static void *kControlCenterAttachedKey = &kControlCenterAttachedKey;
static void *kControlCenterOriginalAlphaKey = &kControlCenterOriginalAlphaKey;
static void *kControlCenterOriginalCornerRadiusKey = &kControlCenterOriginalCornerRadiusKey;
static void *kControlCenterOriginalClipsKey = &kControlCenterOriginalClipsKey;
static void *kControlCenterMaterialOriginalAlphaKey = &kControlCenterMaterialOriginalAlphaKey;
static void *kControlCenterMaterialOriginalHiddenKey = &kControlCenterMaterialOriginalHiddenKey;
static void *kControlCenterFullscreenBlurCapKey = &kControlCenterFullscreenBlurCapKey;

static LGDisplayLinkState sControlCenterDisplayLinkState = {0};
static LGDisplayLinkState sControlCenterFullscreenBlurCapState = {0};
static NSHashTable<UIView *> *sControlCenterHosts = nil;
static NSHashTable<UIView *> *sControlCenterFullscreenMaterials = nil;
static BOOL sControlCenterOverlayVisible = NO;

LG_ENABLED_BOOL_PREF_FUNC(LGControlCenterEnabled, "ControlCenter.Enabled", YES)
LG_FLOAT_PREF_FUNC(LGControlCenterBezelWidth, "ControlCenter.BezelWidth", 18.0)
LG_FLOAT_PREF_FUNC(LGControlCenterGlassThickness, "ControlCenter.GlassThickness", 120.0)
LG_FLOAT_PREF_FUNC(LGControlCenterRefractionScale, "ControlCenter.RefractionScale", 1.35)
LG_FLOAT_PREF_FUNC(LGControlCenterRefractiveIndex, "ControlCenter.RefractiveIndex", 1.2)
LG_FLOAT_PREF_FUNC(LGControlCenterSpecularOpacity, "ControlCenter.SpecularOpacity", 0.55)
LG_FLOAT_PREF_FUNC(LGControlCenterBlur, "ControlCenter.Blur", 10.0)
LG_FLOAT_PREF_FUNC(LGControlCenterWallpaperScale, "ControlCenter.WallpaperScale", 0.25)
LG_FLOAT_PREF_FUNC(LGControlCenterLightTintAlpha, "ControlCenter.LightTintAlpha", 0.10)
LG_FLOAT_PREF_FUNC(LGControlCenterDarkTintAlpha, "ControlCenter.DarkTintAlpha", 0.18)
LG_FLOAT_PREF_FUNC(LGControlCenterLiveCaptureFPS, "ControlCenter.LiveCaptureFPS", 22.0)
LG_FLOAT_PREF_FUNC(LGControlCenterFullscreenBlurRadius, "ControlCenter.FullscreenBlurRadius", 12.0)
LG_FLOAT_PREF_FUNC(LGControlCenterPasscodeBezelWidth, "Lockscreen.Passcode.BezelWidth", 30.0)
LG_FLOAT_PREF_FUNC(LGControlCenterPasscodeGlassThickness, "Lockscreen.Passcode.GlassThickness", 80.0)
LG_FLOAT_PREF_FUNC(LGControlCenterPasscodeRefractionScale, "Lockscreen.Passcode.RefractionScale", 1.0)
LG_FLOAT_PREF_FUNC(LGControlCenterPasscodeRefractiveIndex, "Lockscreen.Passcode.RefractiveIndex", 1.5)
LG_FLOAT_PREF_FUNC(LGControlCenterPasscodeSpecularOpacity, "Lockscreen.Passcode.SpecularOpacity", 0.6)
LG_FLOAT_PREF_FUNC(LGControlCenterPasscodeBlur, "Lockscreen.Passcode.Blur", 3.0)
LG_FLOAT_PREF_FUNC(LGControlCenterPasscodeWallpaperScale, "Lockscreen.Passcode.WallpaperScale", 0.5)
LG_FLOAT_PREF_FUNC(LGControlCenterWidgetBezelWidth, "Widgets.BezelWidth", 18.0)
LG_FLOAT_PREF_FUNC(LGControlCenterWidgetGlassThickness, "Widgets.GlassThickness", 150.0)
LG_FLOAT_PREF_FUNC(LGControlCenterWidgetRefractionScale, "Widgets.RefractionScale", 1.8)
LG_FLOAT_PREF_FUNC(LGControlCenterWidgetRefractiveIndex, "Widgets.RefractiveIndex", 1.2)
LG_FLOAT_PREF_FUNC(LGControlCenterWidgetSpecularOpacity, "Widgets.SpecularOpacity", 0.6)
LG_FLOAT_PREF_FUNC(LGControlCenterWidgetBlur, "Widgets.Blur", 8.0)
LG_FLOAT_PREF_FUNC(LGControlCenterWidgetWallpaperScale, "Widgets.WallpaperScale", 0.5)

typedef struct {
    CGFloat bezelWidth;
    CGFloat glassThickness;
    CGFloat refractionScale;
    CGFloat refractiveIndex;
    CGFloat specularOpacity;
    CGFloat blur;
    CGFloat wallpaperScale;
} LGControlCenterGlassParams;

static NSHashTable<UIView *> *LGControlCenterHostRegistry(void) {
    if (!sControlCenterHosts) {
        sControlCenterHosts = [NSHashTable weakObjectsHashTable];
    }
    return sControlCenterHosts;
}

static NSHashTable<UIView *> *LGControlCenterFullscreenMaterialRegistry(void) {
    if (!sControlCenterFullscreenMaterials) {
        sControlCenterFullscreenMaterials = [NSHashTable weakObjectsHashTable];
    }
    return sControlCenterFullscreenMaterials;
}

static UIView *LGControlCenterFindSubviewOfClass(UIView *root, Class cls) {
    if (!root || !cls) return nil;
    if ([root isKindOfClass:cls]) return root;
    for (UIView *subview in root.subviews) {
        UIView *match = LGControlCenterFindSubviewOfClass(subview, cls);
        if (match) return match;
    }
    return nil;
}

static NSArray<UIView *> *LGControlCenterFindAllSubviewsOfClass(UIView *root, Class cls) {
    NSMutableArray<UIView *> *result = [NSMutableArray array];
    if (!root || !cls) return result;
    for (UIView *subview in root.subviews) {
        if ([subview isKindOfClass:cls]) [result addObject:subview];
        [result addObjectsFromArray:LGControlCenterFindAllSubviewsOfClass(subview, cls)];
    }
    return result;
}

static CGFloat LGControlCenterModuleRadius(UIView *moduleView) {
    CGFloat width = CGRectGetWidth(moduleView.bounds);
    CGFloat height = CGRectGetHeight(moduleView.bounds);
    if (width <= 1.0 || height <= 1.0) return 0.0;
    if ((width < 100.0 && height < 100.0) && fabs(width - height) < 1.0) {
        return width * 0.5;
    } else if (fabs(width - height) > 1.0) {
        return fmin(width, height) * 0.5;
    } else if (width > 100.0 && height > 100.0) {
        return width * 0.25;
    }
    return fmin(width, height) * 0.25;
}

static BOOL LGControlCenterModuleIsSquareish(UIView *host) {
    CGFloat width = CGRectGetWidth(host.bounds);
    CGFloat height = CGRectGetHeight(host.bounds);
    CGFloat minDim = fmin(width, height);
    CGFloat maxDim = fmax(width, height);
    if (minDim <= 1.0) return NO;
    return (maxDim / minDim) <= 1.18;
}

static BOOL LGControlCenterModuleUsesPasscodeParams(UIView *host) {
    if (!LGControlCenterModuleIsSquareish(host)) return NO;
    CGFloat maxDim = fmax(CGRectGetWidth(host.bounds), CGRectGetHeight(host.bounds));
    return maxDim <= 110.0;
}

static BOOL LGControlCenterModuleUsesWidgetParams(UIView *host) {
    if (!LGControlCenterModuleIsSquareish(host)) return NO;
    CGFloat minDim = fmin(CGRectGetWidth(host.bounds), CGRectGetHeight(host.bounds));
    return minDim >= 120.0;
}

static BOOL LGIsControlCenterModuleContainer(UIView *view) {
    if (!view || !view.window) return NO;
    return [NSStringFromClass(view.class) isEqualToString:@"CCUIContentModuleContentContainerView"];
}

static BOOL LGControlCenterViewHierarchyIsVisible(UIView *view) {
    if (!view || !view.window) return NO;
    UIWindow *window = view.window;
    if (window.hidden || window.alpha <= 0.01f || window.layer.opacity <= 0.01f) return NO;
    UIView *current = view;
    while (current && current != window) {
        if (current.hidden || current.alpha <= 0.01f || current.layer.opacity <= 0.01f) return NO;
        current = current.superview;
    }
    return YES;
}

static BOOL LGControlCenterHostIsVisible(UIView *host) {
    if (!sControlCenterOverlayVisible) return NO;
    if (!LGIsControlCenterModuleContainer(host) || !LGControlCenterViewHierarchyIsVisible(host)) return NO;
    CALayer *layer = host.layer.presentationLayer ?: host.layer;
    CGRect bounds = layer.bounds;
    if (CGRectGetWidth(bounds) <= 1.0 || CGRectGetHeight(bounds) <= 1.0) return NO;
    CGRect windowFrame = [layer convertRect:bounds toLayer:host.window.layer];
    return CGRectIntersectsRect(CGRectInset(host.window.bounds, -8.0, -8.0), windowFrame);
}

static BOOL LGControlCenterHasAncestorClassNamed(UIView *view, NSString *className) {
    UIView *ancestor = view.superview;
    while (ancestor) {
        if ([NSStringFromClass(ancestor.class) isEqualToString:className]) return YES;
        ancestor = ancestor.superview;
    }
    return NO;
}

static BOOL LGControlCenterResponderChainContainsClassNamed(UIView *view, NSString *className) {
    UIResponder *responder = view;
    while (responder) {
        if ([NSStringFromClass(responder.class) isEqualToString:className]) return YES;
        responder = responder.nextResponder;
    }
    return NO;
}

static BOOL LGIsControlCenterFullscreenMaterialView(UIView *view) {
    if (!view || !view.window) return NO;
    if (![NSStringFromClass(view.class) isEqualToString:@"MTMaterialView"]) return NO;
    if (LGControlCenterHasAncestorClassNamed(view, @"CCUIContentModuleContentContainerView")) return NO;
    if (!LGControlCenterResponderChainContainsClassNamed(view, @"CCUIModularControlCenterOverlayViewController") &&
        !LGControlCenterHasAncestorClassNamed(view, @"CCUIModularControlCenterOverlayViewController")) {
        return NO;
    }
    CGRect screenBounds = UIScreen.mainScreen.bounds;
    CGRect screenFrame = CGRectZero;
    if (@available(iOS 13.0, *)) {
        id<UICoordinateSpace> space = UIScreen.mainScreen.coordinateSpace;
        if (space && !CGRectIsEmpty(space.bounds)) screenBounds = space.bounds;
        screenFrame = [view convertRect:view.bounds toCoordinateSpace:UIScreen.mainScreen.coordinateSpace];
    } else {
        screenFrame = [view convertRect:view.bounds toView:nil];
    }
    CGFloat viewArea = CGRectGetWidth(screenFrame) * CGRectGetHeight(screenFrame);
    CGFloat screenArea = CGRectGetWidth(screenBounds) * CGRectGetHeight(screenBounds);
    return viewArea >= screenArea * 0.45;
}

static BOOL LGControlCenterIsBlurRadiusKey(NSString *key) {
    if (![key isKindOfClass:[NSString class]]) return NO;
    return [key isEqualToString:@"inputRadius"] ||
           [key isEqualToString:@"radius"] ||
           [key isEqualToString:@"inputBlurRadius"];
}

static id LGControlCenterClampedRadiusValue(id value, CGFloat radius) {
    if (![value isKindOfClass:[NSNumber class]]) return value;
    CGFloat incoming = [(NSNumber *)value doubleValue];
    if (incoming <= radius) return value;
    return @(radius);
}

static void LGControlCenterMarkBlurCappedObject(id object, CGFloat radius) {
    if (!object) return;
    objc_setAssociatedObject(object, kControlCenterFullscreenBlurCapKey, @(radius), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void LGControlCenterClampExistingFilterRadiusIfNeeded(id filter, CGFloat radius) {
    if (!filter) return;
    NSArray<NSString *> *candidateKeys = @[@"inputRadius", @"radius", @"inputBlurRadius"];
    for (NSString *key in candidateKeys) {
        @try {
            id currentValue = [filter valueForKey:key];
            id cappedValue = LGControlCenterClampedRadiusValue(currentValue, radius);
            if (cappedValue != currentValue) {
                [filter setValue:cappedValue forKey:key];
            }
        } @catch (NSException *exception) {
            LGDebugLog(@"control center blur filter clamp failed key=%@ %@ %@", key, exception.name, exception.reason);
        }
    }
}

static void LGControlCenterMarkBlurFilterArray(id filters, CGFloat radius) {
    if (![filters isKindOfClass:[NSArray class]]) return;
    for (id filter in (NSArray *)filters) {
        LGControlCenterMarkBlurCappedObject(filter, radius);
        LGControlCenterClampExistingFilterRadiusIfNeeded(filter, radius);
    }
}

static void LGControlCenterMarkBlurCapOnLayer(CALayer *layer, CGFloat radius) {
    if (!layer) return;
    LGControlCenterMarkBlurCappedObject(layer, radius);
    NSArray *filters = layer.filters;
    LGControlCenterMarkBlurFilterArray(filters, radius);
    @try {
        NSArray *backgroundFilters = [layer valueForKey:@"backgroundFilters"];
        if ([backgroundFilters isKindOfClass:[NSArray class]]) {
            LGControlCenterMarkBlurFilterArray(backgroundFilters, radius);
        }
    } @catch (NSException *exception) {
        LGDebugLog(@"control center background filter read failed %@ %@", exception.name, exception.reason);
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
    } @catch (NSException *exception) {
        LGDebugLog(@"control center animation keyPath read failed %@ %@", exception.name, exception.reason);
    }
    if (![keyPath isKindOfClass:[NSString class]]) return;
    NSString *lowerKeyPath = keyPath.lowercaseString;
    if (![lowerKeyPath containsString:@"radius"] &&
        ![lowerKeyPath containsString:@"blur"]) {
        return;
    }

    if ([animation isKindOfClass:[CABasicAnimation class]]) {
        CABasicAnimation *basic = (CABasicAnimation *)animation;
        basic.fromValue = LGControlCenterClampedRadiusValue(basic.fromValue, radius);
        basic.toValue = LGControlCenterClampedRadiusValue(basic.toValue, radius);
        basic.byValue = LGControlCenterClampedRadiusValue(basic.byValue, radius);
    } else if ([animation isKindOfClass:[CAKeyframeAnimation class]]) {
        CAKeyframeAnimation *keyframe = (CAKeyframeAnimation *)animation;
        NSMutableArray *values = nil;
        for (id value in keyframe.values) {
            if (!values) values = [NSMutableArray arrayWithCapacity:keyframe.values.count];
            [values addObject:LGControlCenterClampedRadiusValue(value, radius)];
        }
        if (values) keyframe.values = values;
    } else if ([animation isKindOfClass:[CAAnimationGroup class]]) {
        CAAnimationGroup *group = (CAAnimationGroup *)animation;
        for (CAAnimation *child in group.animations) {
            LGControlCenterClampBlurAnimation(child, radius);
        }
    }
}

static void LGControlCenterApplyFullscreenMaterialBlur(UIView *view) {
    if (!LGControlCenterEnabled()) return;
    if (!LGIsControlCenterFullscreenMaterialView(view)) return;
    [LGControlCenterFullscreenMaterialRegistry() addObject:view];
    view.hidden = NO;
    view.alpha = 1.0;
    view.layer.opacity = 1.0f;
    LGControlCenterMarkBlurCapOnLayer(view.layer, MAX(0.0, LGControlCenterFullscreenBlurRadius()));
}

static BOOL LGControlCenterFullscreenMaterialIsVisible(UIView *view) {
    if (!sControlCenterOverlayVisible) return NO;
    if (!view || !view.window || view.hidden || view.alpha <= 0.01f || view.layer.opacity <= 0.01f) return NO;
    CALayer *layer = view.layer.presentationLayer ?: view.layer;
    CGRect bounds = layer.bounds;
    if (CGRectGetWidth(bounds) <= 1.0 || CGRectGetHeight(bounds) <= 1.0) return NO;
    CGRect screenFrame = [layer convertRect:bounds toLayer:view.window.layer];
    CGRect screenBounds = view.window.bounds;
    return CGRectIntersectsRect(CGRectInset(screenBounds, -8.0, -8.0), screenFrame);
}

static void LGControlCenterRefreshFullscreenBlurCapMaterials(void) {
    NSHashTable<UIView *> *materials = LGControlCenterFullscreenMaterialRegistry();
    for (UIView *material in materials.allObjects) {
        if (!LGControlCenterFullscreenMaterialIsVisible(material) ||
            !LGIsControlCenterFullscreenMaterialView(material)) {
            [materials removeObject:material];
            continue;
        }
        LGControlCenterApplyFullscreenMaterialBlur(material);
    }
    sControlCenterFullscreenBlurCapState.activeCount = materials.allObjects.count;
    LGDisplayLinkStateDidChangeActivity(&sControlCenterFullscreenBlurCapState);
    if (sControlCenterFullscreenBlurCapState.activeCount == 0) {
        LGStopDisplayLinkState(&sControlCenterFullscreenBlurCapState);
    }
}

static void LGControlCenterStartFullscreenBlurCapDisplayLink(void) {
    LGStartDisplayLinkStateWithPreferenceKey(&sControlCenterFullscreenBlurCapState,
                                             LGPreferredLiveCaptureFramesPerSecond(LG_prefFloat(@"ControlCenter.FullscreenBlurCapFPS", 25.0)),
                                             @"DisplayLink.ControlCenter.Enabled",
                                             ^{
        LGControlCenterRefreshFullscreenBlurCapMaterials();
    });
}

static void LGControlCenterTrackFullscreenMaterial(UIView *view) {
    if (!LGControlCenterFullscreenMaterialIsVisible(view)) {
        [LGControlCenterFullscreenMaterialRegistry() removeObject:view];
        LGControlCenterRefreshFullscreenBlurCapMaterials();
        return;
    }
    LGControlCenterApplyFullscreenMaterialBlur(view);
    sControlCenterFullscreenBlurCapState.activeCount = LGControlCenterFullscreenMaterialRegistry().allObjects.count;
    LGDisplayLinkStateDidChangeActivity(&sControlCenterFullscreenBlurCapState);
    if (sControlCenterFullscreenBlurCapState.activeCount > 0) {
        LGControlCenterStartFullscreenBlurCapDisplayLink();
    }
}

static BOOL LGControlCenterModuleIsExpanded(UIView *host) {
    BOOL expanded = NO;
    @try {
        expanded = [[host valueForKey:@"_expanded"] boolValue];
    } @catch (NSException *exception) {
        LGDebugLog(@"control center expanded state read failed %@ %@", exception.name, exception.reason);
        expanded = NO;
    }
    return expanded;
}

static CGFloat LGControlCenterCornerRadiusForHost(UIView *host) {
    Class mediaCls = NSClassFromString(@"MRUNowPlayingView");
    Class continuousSliderCls = NSClassFromString(@"CCUIContinuousSliderView");
    Class steppedSliderCls = NSClassFromString(@"CCUISteppedSliderView");
    Class focusCls = NSClassFromString(@"FCUIActivityListContentView");

    BOOL expanded = LGControlCenterModuleIsExpanded(host);
    BOOL containsMedia = LGControlCenterFindSubviewOfClass(host, mediaCls) != nil;
    BOOL containsSlider = LGControlCenterFindSubviewOfClass(host, continuousSliderCls) != nil;
    BOOL containsSteppedSlider = LGControlCenterFindSubviewOfClass(host, steppedSliderCls) != nil;
    BOOL containsFocus = LGControlCenterFindSubviewOfClass(host, focusCls) != nil;
    BOOL isStandaloneSlider = (containsSlider || containsSteppedSlider) && !containsMedia;

    CGFloat minDim = fmin(CGRectGetWidth(host.bounds), CGRectGetHeight(host.bounds));
    if (isStandaloneSlider) return minDim * 0.5;
    if (expanded) return containsFocus ? 35.0 : 65.0;
    return LGControlCenterModuleRadius(host);
}

static LGControlCenterGlassParams LGControlCenterGlassParamsForHost(UIView *host) {
    if (LGControlCenterModuleUsesPasscodeParams(host)) {
        return (LGControlCenterGlassParams){
            .bezelWidth = LGControlCenterPasscodeBezelWidth(),
            .glassThickness = LGControlCenterPasscodeGlassThickness(),
            .refractionScale = LGControlCenterPasscodeRefractionScale(),
            .refractiveIndex = LGControlCenterPasscodeRefractiveIndex(),
            .specularOpacity = LGControlCenterPasscodeSpecularOpacity(),
            .blur = LGControlCenterPasscodeBlur(),
            .wallpaperScale = LGControlCenterPasscodeWallpaperScale(),
        };
    }
    if (LGControlCenterModuleUsesWidgetParams(host)) {
        return (LGControlCenterGlassParams){
            .bezelWidth = LGControlCenterWidgetBezelWidth(),
            .glassThickness = LGControlCenterWidgetGlassThickness(),
            .refractionScale = LGControlCenterWidgetRefractionScale(),
            .refractiveIndex = LGControlCenterWidgetRefractiveIndex(),
            .specularOpacity = LGControlCenterWidgetSpecularOpacity(),
            .blur = LGControlCenterWidgetBlur(),
            .wallpaperScale = LGControlCenterWidgetWallpaperScale(),
        };
    }
    return (LGControlCenterGlassParams){
        .bezelWidth = LGControlCenterBezelWidth(),
        .glassThickness = LGControlCenterGlassThickness(),
        .refractionScale = LGControlCenterRefractionScale(),
        .refractiveIndex = LGControlCenterRefractiveIndex(),
        .specularOpacity = LGControlCenterSpecularOpacity(),
        .blur = LGControlCenterBlur(),
        .wallpaperScale = LGControlCenterWallpaperScale(),
    };
}

static void LGControlCenterConfigureGlass(LiquidGlassView *glass, UIView *host, CGFloat cornerRadius) {
    if (!glass) return;
    LGControlCenterGlassParams params = LGControlCenterGlassParamsForHost(host);
    glass.cornerRadius = cornerRadius;
    glass.bezelWidth = params.bezelWidth;
    glass.glassThickness = params.glassThickness;
    glass.refractionScale = params.refractionScale;
    glass.refractiveIndex = params.refractiveIndex;
    glass.specularOpacity = params.specularOpacity;
    glass.blur = params.blur;
    glass.wallpaperScale = params.wallpaperScale;
}

static UIColor *LGControlCenterTintColorForView(UIView *view) {
    return LGDefaultTintColorForViewWithOverrideKey(view,
                                                   LGControlCenterLightTintAlpha(),
                                                   LGControlCenterDarkTintAlpha(),
                                                   @"ControlCenter.TintOverrideMode");
}

static void LGControlCenterRememberOriginalState(UIView *host) {
    if (!objc_getAssociatedObject(host, kControlCenterOriginalAlphaKey))
        objc_setAssociatedObject(host, kControlCenterOriginalAlphaKey, @(host.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!objc_getAssociatedObject(host, kControlCenterOriginalCornerRadiusKey))
        objc_setAssociatedObject(host, kControlCenterOriginalCornerRadiusKey, @(host.layer.cornerRadius), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!objc_getAssociatedObject(host, kControlCenterOriginalClipsKey))
        objc_setAssociatedObject(host, kControlCenterOriginalClipsKey, @(host.clipsToBounds), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void LGControlCenterRestoreOriginalState(UIView *host) {
    NSNumber *alpha = objc_getAssociatedObject(host, kControlCenterOriginalAlphaKey);
    if (alpha) host.alpha = alpha.doubleValue;
    NSNumber *radius = objc_getAssociatedObject(host, kControlCenterOriginalCornerRadiusKey);
    if (radius) host.layer.cornerRadius = radius.doubleValue;
    NSNumber *clips = objc_getAssociatedObject(host, kControlCenterOriginalClipsKey);
    if (clips) host.clipsToBounds = clips.boolValue;
}

static void LGControlCenterRestoreMaterialViews(UIView *host) {
    Class materialCls = NSClassFromString(@"MTMaterialView");
    for (UIView *material in LGControlCenterFindAllSubviewsOfClass(host, materialCls)) {
        NSNumber *hidden = objc_getAssociatedObject(material, kControlCenterMaterialOriginalHiddenKey);
        NSNumber *alpha = objc_getAssociatedObject(material, kControlCenterMaterialOriginalAlphaKey);
        if (hidden) material.hidden = hidden.boolValue;
        if (alpha) material.alpha = alpha.doubleValue;
    }
}

static void LGControlCenterHideBackgroundMaterials(UIView *host) {
    Class materialCls = NSClassFromString(@"MTMaterialView");
    CGFloat hostArea = CGRectGetWidth(host.bounds) * CGRectGetHeight(host.bounds);
    if (hostArea <= 1.0) return;
    for (UIView *material in LGControlCenterFindAllSubviewsOfClass(host, materialCls)) {
        CGRect frame = [material convertRect:material.bounds toView:host];
        CGFloat area = CGRectGetWidth(frame) * CGRectGetHeight(frame);
        if (area < hostArea * 0.45) continue;
        if (!objc_getAssociatedObject(material, kControlCenterMaterialOriginalHiddenKey))
            objc_setAssociatedObject(material, kControlCenterMaterialOriginalHiddenKey, @(material.hidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!objc_getAssociatedObject(material, kControlCenterMaterialOriginalAlphaKey))
            objc_setAssociatedObject(material, kControlCenterMaterialOriginalAlphaKey, @(material.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        material.hidden = YES;
        material.alpha = 0.0;
    }
}

static void LGControlCenterEnsureTintOverlay(UIView *host, CGFloat cornerRadius) {
    UIView *tint = LGEnsureTintOverlayView(host,
                                           kControlCenterTintKey,
                                           kControlCenterTintTag,
                                           host.bounds,
                                           UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight);
    LGConfigureTintOverlayView(tint,
                               LGControlCenterTintColorForView(host),
                               cornerRadius,
                               host.layer,
                               YES);
    [host bringSubviewToFront:tint];
}

static void LGControlCenterDetachHost(UIView *host) {
    if (!host) return;
    [LGControlCenterHostRegistry() removeObject:host];
    LGRemoveAssociatedSubview(host, kControlCenterTintKey);
    LiquidGlassView *glass = objc_getAssociatedObject(host, kControlCenterGlassKey);
    if (glass) [glass removeFromSuperview];
    objc_setAssociatedObject(host, kControlCenterGlassKey, nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(host, kControlCenterLastLiveCaptureTimeKey, nil, OBJC_ASSOCIATION_ASSIGN);
    LGRemoveLiveBackdropCaptureView(host, kControlCenterBackdropViewKey);
    LGControlCenterRestoreMaterialViews(host);
    LGControlCenterRestoreOriginalState(host);
    if ([objc_getAssociatedObject(host, kControlCenterAttachedKey) boolValue]) {
        objc_setAssociatedObject(host, kControlCenterAttachedKey, nil, OBJC_ASSOCIATION_ASSIGN);
    }
}

static void LGControlCenterStartDisplayLink(void);
static void LGControlCenterInjectHost(UIView *host);
static void LGControlCenterSyncDisplayLinkActivity(void);
static void LGControlCenterRefreshFullscreenBlurCapMaterials(void);

static void LGControlCenterRefreshAttachedHosts(void) {
    for (UIView *host in LGControlCenterHostRegistry().allObjects) {
        if (!host.window || !LGIsControlCenterModuleContainer(host)) {
            LGControlCenterDetachHost(host);
            continue;
        }
        LGControlCenterInjectHost(host);
    }
    LGControlCenterSyncDisplayLinkActivity();
}

static void LGControlCenterStartDisplayLink(void) {
    NSInteger fps = LG_prefersLiveCapture(@"ControlCenter.RenderingMode")
        ? LGPreferredLiveCaptureFramesPerSecond(LGControlCenterLiveCaptureFPS())
        : LGPreferredFramesPerSecondForKey(@"ControlCenter.FPS", 1);
    LGStartDisplayLinkStateWithPreferenceKey(&sControlCenterDisplayLinkState,
                                             fps,
                                             @"DisplayLink.ControlCenter.Enabled",
                                             ^{
        NSInteger nextFPS = LG_prefersLiveCapture(@"ControlCenter.RenderingMode")
            ? LGPreferredLiveCaptureFramesPerSecond(LGControlCenterLiveCaptureFPS())
            : LGPreferredFramesPerSecondForKey(@"ControlCenter.FPS", 1);
        LGSetDisplayLinkStatePreferredFPS(&sControlCenterDisplayLinkState, nextFPS);
        if (LG_prefersLiveCapture(@"ControlCenter.RenderingMode")) LGControlCenterRefreshAttachedHosts();
        else LG_updateRegisteredGlassViews(LGUpdateGroupControlCenter);
    });
}

static void LGControlCenterAttachHostIfNeeded(UIView *host) {
    [LGControlCenterHostRegistry() addObject:host];
    if ([objc_getAssociatedObject(host, kControlCenterAttachedKey) boolValue]) {
        LGControlCenterSyncDisplayLinkActivity();
        return;
    }
    objc_setAssociatedObject(host, kControlCenterAttachedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    LGControlCenterSyncDisplayLinkActivity();
}

static void LGControlCenterSyncDisplayLinkActivity(void) {
    NSInteger visibleHostCount = 0;
    if (sControlCenterOverlayVisible) {
        for (UIView *host in LGControlCenterHostRegistry().allObjects) {
            if (!LGControlCenterHostIsVisible(host)) continue;
            visibleHostCount++;
        }
    }
    sControlCenterDisplayLinkState.activeCount = visibleHostCount;
    LGDisplayLinkStateDidChangeActivity(&sControlCenterDisplayLinkState);
    if (visibleHostCount > 0) {
        LGControlCenterStartDisplayLink();
    } else {
        LGStopDisplayLinkState(&sControlCenterDisplayLinkState);
    }
}

static void LGControlCenterSetOverlayVisible(BOOL visible) {
    if (sControlCenterOverlayVisible == visible) return;
    sControlCenterOverlayVisible = visible;
    if (visible) {
        LGControlCenterRefreshAttachedHosts();
        LGControlCenterRefreshFullscreenBlurCapMaterials();
    } else {
        sControlCenterDisplayLinkState.activeCount = 0;
        LGDisplayLinkStateDidChangeActivity(&sControlCenterDisplayLinkState);
        LGStopDisplayLinkState(&sControlCenterDisplayLinkState);
        sControlCenterFullscreenBlurCapState.activeCount = 0;
        LGDisplayLinkStateDidChangeActivity(&sControlCenterFullscreenBlurCapState);
        LGStopDisplayLinkState(&sControlCenterFullscreenBlurCapState);
    }
}

static void LGControlCenterInjectHost(UIView *host) {
    CFTimeInterval profileStart = LGProfileBegin();
    if (!LGIsControlCenterModuleContainer(host) || !LGControlCenterEnabled()) {
        LGControlCenterDetachHost(host);
        LGProfileEnd(@"control_center.inject", profileStart);
        return;
    }
    if (!LGControlCenterHostIsVisible(host)) {
        [LGControlCenterHostRegistry() addObject:host];
        LGControlCenterSyncDisplayLinkActivity();
        LGProfileEnd(@"control_center.inject", profileStart);
        return;
    }

    CGFloat cornerRadius = LGControlCenterCornerRadiusForHost(host);
    LGControlCenterRememberOriginalState(host);
    host.alpha = 1.0;
    host.clipsToBounds = YES;
    host.layer.masksToBounds = YES;
    host.layer.cornerRadius = cornerRadius;
    if (@available(iOS 13.0, *)) host.layer.cornerCurve = kCACornerCurveContinuous;

    LiquidGlassView *glass = objc_getAssociatedObject(host, kControlCenterGlassKey);
    BOOL hadGlass = (glass != nil);
    if (!LGShouldRefreshLiveCaptureForHost(host,
                                           @"ControlCenter.RenderingMode",
                                           kControlCenterLastLiveCaptureTimeKey,
                                           LGControlCenterLiveCaptureFPS(),
                                           hadGlass)) {
        glass.frame = host.bounds;
        LGControlCenterConfigureGlass(glass, host, cornerRadius);
        LGControlCenterHideBackgroundMaterials(host);
        LGControlCenterEnsureTintOverlay(host, cornerRadius);
        [glass updateOrigin];
        LGProfileEnd(@"control_center.inject", profileStart);
        return;
    }

    CGPoint snapshotOrigin = CGPointZero;
    UIImage *snapshot = LG_getHomescreenSnapshot(&snapshotOrigin);
    if (!snapshot && !LG_prefersLiveCapture(@"ControlCenter.RenderingMode")) {
        LGControlCenterDetachHost(host);
        LGProfileEnd(@"control_center.inject", profileStart);
        return;
    }

    if (!glass) {
        glass = [[LiquidGlassView alloc] initWithFrame:host.bounds wallpaper:snapshot wallpaperOrigin:snapshotOrigin];
        glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        glass.userInteractionEnabled = NO;
        glass.updateGroup = LGUpdateGroupControlCenter;
        [host insertSubview:glass atIndex:0];
        objc_setAssociatedObject(host, kControlCenterGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        glass.frame = host.bounds;
        if (!LG_prefersLiveCapture(@"ControlCenter.RenderingMode")) {
            glass.wallpaperImage = snapshot;
        }
    }

    LGControlCenterConfigureGlass(glass, host, cornerRadius);
    LGControlCenterHideBackgroundMaterials(host);

    if (!LGApplyRenderingModeToGlassHost(host,
                                         glass,
                                         @"ControlCenter.RenderingMode",
                                         kControlCenterBackdropViewKey,
                                         snapshot,
                                         snapshotOrigin)) {
        LGProfileEnd(@"control_center.inject", profileStart);
        return;
    }
    if (LG_prefersLiveCapture(@"ControlCenter.RenderingMode")) {
        LGMarkLiveCaptureRefreshedForHost(host, kControlCenterLastLiveCaptureTimeKey);
    }
    LGControlCenterEnsureTintOverlay(host, cornerRadius);
    LGControlCenterAttachHostIfNeeded(host);
    LGProfileEnd(@"control_center.inject", profileStart);
}

static void LGControlCenterPrefsChanged(CFNotificationCenterRef center,
                                        void *observer,
                                        CFStringRef name,
                                        const void *object,
                                        CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        LGControlCenterRefreshAttachedHosts();
    });
}

%group LGControlCenterSpringBoard

%hook CCUIContentModuleContentContainerView

- (void)didMoveToWindow {
    %orig;
    UIView *self_ = (UIView *)self;
    if (!self_.window) {
        LGControlCenterDetachHost(self_);
        return;
    }
    LGControlCenterInjectHost(self_);
}

- (void)layoutSubviews {
    %orig;
    UIView *self_ = (UIView *)self;
    if (!self_.window) return;
    LGControlCenterInjectHost(self_);
}

%end

%hook CCUIModularControlCenterOverlayViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    LGControlCenterSetOverlayVisible(YES);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    LGControlCenterSetOverlayVisible(YES);
}

- (void)viewWillDisappear:(BOOL)animated {
    LGControlCenterSetOverlayVisible(NO);
    %orig;
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    LGControlCenterSetOverlayVisible(NO);
}

%end

%hook MTMaterialView

- (void)didMoveToWindow {
    %orig;
    LGControlCenterTrackFullscreenMaterial((UIView *)self);
}

- (void)didMoveToSuperview {
    %orig;
    LGControlCenterTrackFullscreenMaterial((UIView *)self);
}

- (void)layoutSubviews {
    %orig;
    LGControlCenterTrackFullscreenMaterial((UIView *)self);
}

%end

%hook CAFilter

- (void)setValue:(id)value forKey:(NSString *)key {
    NSNumber *radius = objc_getAssociatedObject(self, kControlCenterFullscreenBlurCapKey);
    if (radius && LGControlCenterIsBlurRadiusKey(key)) {
        value = LGControlCenterClampedRadiusValue(value, radius.doubleValue);
    }
    %orig(value, key);
}

- (void)setValue:(id)value forKeyPath:(NSString *)keyPath {
    NSNumber *radius = objc_getAssociatedObject(self, kControlCenterFullscreenBlurCapKey);
    if (radius && [keyPath isKindOfClass:[NSString class]]) {
        NSArray<NSString *> *components = [keyPath componentsSeparatedByString:@"."];
        NSString *lastKey = components.lastObject;
        if (LGControlCenterIsBlurRadiusKey(lastKey)) {
            value = LGControlCenterClampedRadiusValue(value, radius.doubleValue);
        }
    }
    %orig(value, keyPath);
}

%end

%hook CALayer

- (void)setFilters:(NSArray *)filters {
    NSNumber *radius = objc_getAssociatedObject(self, kControlCenterFullscreenBlurCapKey);
    if (radius) {
        LGControlCenterMarkBlurFilterArray(filters, radius.doubleValue);
    }
    %orig(filters);
}

- (void)setValue:(id)value forKey:(NSString *)key {
    NSNumber *radius = objc_getAssociatedObject(self, kControlCenterFullscreenBlurCapKey);
    if (radius && [key isEqualToString:@"backgroundFilters"]) {
        LGControlCenterMarkBlurFilterArray(value, radius.doubleValue);
    }
    %orig(value, key);
}

- (void)setValue:(id)value forKeyPath:(NSString *)keyPath {
    NSNumber *radius = objc_getAssociatedObject(self, kControlCenterFullscreenBlurCapKey);
    if (radius && [keyPath isKindOfClass:[NSString class]]) {
        NSArray<NSString *> *components = [keyPath componentsSeparatedByString:@"."];
        NSString *lastKey = components.lastObject;
        if (LGControlCenterIsBlurRadiusKey(lastKey)) {
            value = LGControlCenterClampedRadiusValue(value, radius.doubleValue);
        }
    }
    %orig(value, keyPath);
}

- (void)addAnimation:(CAAnimation *)animation forKey:(NSString *)key {
    NSNumber *radius = objc_getAssociatedObject(self, kControlCenterFullscreenBlurCapKey);
    if (radius) {
        LGControlCenterClampBlurAnimation(animation, radius.doubleValue);
    }
    %orig(animation, key);
}

%end

%end

%ctor {
    if (!LGIsSpringBoardProcess()) return;
    LGObservePreferenceChanges(^{
        LGControlCenterPrefsChanged(NULL, NULL, NULL, NULL, NULL);
    });
    %init(LGControlCenterSpringBoard);
}
