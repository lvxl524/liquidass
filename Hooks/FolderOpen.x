#import "../LiquidGlass.h"
#import "../Shared/LGHookSupport.h"
#import "../Shared/LGBannerCaptureSupport.h"
#import "../Shared/LGPrefAccessors.h"
#import <objc/runtime.h>

static const NSTimeInterval kFolderOpenDisplayLinkGrace = 0.18;
static const NSInteger kFolderOpenTintTag = 0xF0D0;
static void *kFolderOpenOriginalAlphaKey = &kFolderOpenOriginalAlphaKey;
static void *kFolderOpenAttachedKey = &kFolderOpenAttachedKey;
static void *kFolderOpenGlassKey = &kFolderOpenGlassKey;
static void *kFolderOpenTintKey = &kFolderOpenTintKey;
static void *kFolderOpenResanitizePendingKey = &kFolderOpenResanitizePendingKey;
static void *kFolderOpenLastLiveCaptureTimeKey = &kFolderOpenLastLiveCaptureTimeKey;
static void *kFolderOpenBackdropViewKey = &kFolderOpenBackdropViewKey;
static void *kFolderOpenLastDiagnosticKey = &kFolderOpenLastDiagnosticKey;
static void *kFolderOpenLastDiagnosticTimeKey = &kFolderOpenLastDiagnosticTimeKey;
static NSHashTable<UIView *> *sFolderOpenHosts = nil;

static BOOL isInsideOpenFolder(UIView *view) {
    static Class cls;
    if (!cls) cls = NSClassFromString(@"SBFolderBackgroundView");
    UIView *v = view.superview;
    while (v) {
        if ([v isKindOfClass:cls]) return YES;
        v = v.superview;
    }
    return NO;
}

static BOOL LGFolderOpenHasAncestorClassNamed(UIView *view, NSString *className) {
    if (!view || !className.length) return NO;
    UIView *v = view;
    while (v) {
        if ([NSStringFromClass(v.class) isEqualToString:className]) return YES;
        v = v.superview;
    }
    return NO;
}

static BOOL LGIsInsideFloatyOpenFolder(UIView *view) {
    return LGFolderOpenHasAncestorClassNamed(view, @"SBFloatyFolderView") ||
        LGFolderOpenHasAncestorClassNamed(view, @"SBFloatyFolderScrollView") ||
        LGFolderOpenHasAncestorClassNamed(view, @"SBFloatyFolderBackgroundClipView");
}

static UIView *folderOpenContainerForView(UIView *view) {
    static Class cls;
    if (!cls) cls = NSClassFromString(@"SBFolderBackgroundView");
    UIView *v = view;
    while (v) {
        if ([v isKindOfClass:cls]) return v;
        v = v.superview;
    }
    return nil;
}

static UIView *LGFolderOpenNearestAncestorClassNamed(UIView *view, NSString *className) {
    if (!view || !className.length) return nil;
    UIView *v = view;
    while (v) {
        if ([NSStringFromClass(v.class) isEqualToString:className]) return v;
        v = v.superview;
    }
    return nil;
}

static void stopFolderDisplayLink(void);
static void scheduleFolderDisplayLinkStopIfIdle(void);
static void LGFolderOpenRefreshAllHosts(void);
static void LGFolderOpenForEachMaterialHost(void (^block)(UIView *view));
static void LGRestoreFolderOpenHost(UIView *view);
static void LGDetachFolderOpenHost(UIView *view);
static void LGHandleFolderOpenMaterialView(UIView *view, BOOL updateOnly);
static BOOL LGIsPrimaryFolderOpenHost(UIView *view);
static void LGStripFolderOpenTintFiltersFromLayerTree(CALayer *layer);
static void LGFolderOpenLogHostState(UIView *host, NSString *reason);
static void LGFolderOpenLogScrollState(UIScrollView *scrollView, NSString *reason);
static void LGFolderOpenNormalizeFloatyClipView(UIView *clipView, NSString *reason);

static LGDisplayLinkState sFolderDisplayLinkState = {0};
static NSUInteger sFolderStopGeneration = 0;
LG_ENABLED_BOOL_PREF_FUNC(LGFolderOpenEnabled, "FolderOpen.Enabled", YES)
LG_FLOAT_PREF_FUNC(LGFolderOpenCornerRadius, "FolderOpen.CornerRadius", 38.0)
LG_FLOAT_PREF_FUNC(LGFolderOpenBezelWidth, "FolderOpen.BezelWidth", 38.0)
LG_FLOAT_PREF_FUNC(LGFolderOpenGlassThickness, "FolderOpen.GlassThickness", 100.0)
LG_FLOAT_PREF_FUNC(LGFolderOpenRefractionScale, "FolderOpen.RefractionScale", 1.5)
LG_FLOAT_PREF_FUNC(LGFolderOpenRefractiveIndex, "FolderOpen.RefractiveIndex", 4.0)
LG_FLOAT_PREF_FUNC(LGFolderOpenSpecularOpacity, "FolderOpen.SpecularOpacity", 0.6)
LG_FLOAT_PREF_FUNC(LGFolderOpenBlur, "FolderOpen.Blur", 15.0)
LG_FLOAT_PREF_FUNC(LGFolderOpenWallpaperScale, "FolderOpen.WallpaperScale", 0.1)
LG_FLOAT_PREF_FUNC(LGFolderOpenLightTintAlpha, "FolderOpen.LightTintAlpha", 0.1)
LG_FLOAT_PREF_FUNC(LGFolderOpenDarkTintAlpha, "FolderOpen.DarkTintAlpha", 0.0)
LG_FLOAT_PREF_FUNC(LGFolderOpenLiveCaptureFPS, "FolderOpen.LiveCaptureFPS", 22.0)

static NSHashTable<UIView *> *LGFolderOpenHostRegistry(void) {
    if (!sFolderOpenHosts) {
        sFolderOpenHosts = [NSHashTable weakObjectsHashTable];
    }
    return sFolderOpenHosts;
}

static UIColor *folderOpenTintColorForView(UIView *view) {
    return LGDefaultTintColorForViewWithOverrideKey(view, LGFolderOpenLightTintAlpha(), LGFolderOpenDarkTintAlpha(), @"FolderOpen.TintOverrideMode");
}

static BOOL LGFolderOpenFilterLooksLikeTintFilter(id filter) {
    NSString *name = nil;
    @try {
        name = [filter valueForKey:@"name"];
    } @catch (NSException *exception) {
        LGDebugLog(@"folder open filter name read failed %@ %@", exception.name, exception.reason);
        name = nil;
    }
    if (![name isKindOfClass:[NSString class]]) return NO;
    NSString *lower = name.lowercaseString;
    return ([lower containsString:@"vibrant"] ||
            [lower containsString:@"colormatrix"]);
}

static void LGStripFolderControllerBackgroundMaterialFiltersIfNeeded(UIView *view) {
    if (!view) return;
    if (![NSStringFromClass(view.superview.class) isEqualToString:@"SBFolderControllerBackgroundView"]) return;
    LGStripFolderOpenTintFiltersFromLayerTree(view.layer);
}

static NSArray *LGFolderOpenCleanedFilterArray(NSArray *filters, BOOL *didRemoveAny) {
    if (!filters.count) return filters;
    NSMutableArray *cleaned = [NSMutableArray arrayWithCapacity:filters.count];
    BOOL removed = NO;
    for (id filter in filters) {
        if (LGFolderOpenFilterLooksLikeTintFilter(filter)) {
            removed = YES;
            continue;
        }
        [cleaned addObject:filter];
    }
    if (didRemoveAny) *didRemoveAny = removed;
    return removed ? cleaned : filters;
}

static void LGStripFolderOpenTintFiltersFromLayerTree(CALayer *layer) {
    if (!layer) return;

    BOOL removedMain = NO;
    NSArray *mainFilters = LGFolderOpenCleanedFilterArray(layer.filters, &removedMain);
    if (removedMain) layer.filters = mainFilters;

    @try {
        id rawBackgroundFilters = [layer valueForKey:@"backgroundFilters"];
        if ([rawBackgroundFilters isKindOfClass:[NSArray class]]) {
            BOOL removedBg = NO;
            NSArray *cleanedBg = LGFolderOpenCleanedFilterArray((NSArray *)rawBackgroundFilters, &removedBg);
            if (removedBg) [layer setValue:cleanedBg forKey:@"backgroundFilters"];
        }
    } @catch (NSException *exception) {
        LGDebugLog(@"folder open background filter strip failed %@ %@", exception.name, exception.reason);
    }

    layer.compositingFilter = nil;

    for (CALayer *sub in layer.sublayers) {
        LGStripFolderOpenTintFiltersFromLayerTree(sub);
    }
}

static void LGStripFolderOpenMaterialFiltersIfNeeded(UIView *view) {
    if (!view) return;
    if (!isInsideOpenFolder(view)) return;
    if (!LGIsPrimaryFolderOpenHost(view)) return;
    LGStripFolderOpenTintFiltersFromLayerTree(view.layer);
}

static void LGScheduleFolderOpenResanitize(UIView *view) {
    if (!view) return;
    if (!isInsideOpenFolder(view)) return;
    if (!LGIsPrimaryFolderOpenHost(view)) return;
    if ([objc_getAssociatedObject(view, kFolderOpenResanitizePendingKey) boolValue]) return;
    objc_setAssociatedObject(view, kFolderOpenResanitizePendingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        objc_setAssociatedObject(view, kFolderOpenResanitizePendingKey, nil, OBJC_ASSOCIATION_ASSIGN);
        if (!view.window) return;
        LGStripFolderOpenMaterialFiltersIfNeeded(view);
    });
}

static void ensureFolderOpenTintOverlay(UIView *view) {
    UIView *tint = LGEnsureTintOverlayView(view,
                                           kFolderOpenTintKey,
                                           kFolderOpenTintTag,
                                           view.bounds,
                                           UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight);
    LGConfigureTintOverlayView(tint,
                               folderOpenTintColorForView(view),
                               LGFolderOpenCornerRadius(),
                               view.layer,
                               NO);
    [view bringSubviewToFront:tint];
}

static void startFolderDisplayLink(void) {
    sFolderStopGeneration++;
    NSInteger fps = LG_prefersLiveCapture(@"FolderOpen.RenderingMode")
        ? LGPreferredLiveCaptureFramesPerSecond(LGFolderOpenLiveCaptureFPS())
        : LGPreferredFramesPerSecondForKey(@"Homescreen.FPS", 1);
    LGStartDisplayLinkStateWithPreferenceKey(&sFolderDisplayLinkState,
                                             fps,
                                             @"DisplayLink.FolderOpen.Enabled",
                                             ^{
        NSInteger nextFPS = LG_prefersLiveCapture(@"FolderOpen.RenderingMode")
            ? LGPreferredLiveCaptureFramesPerSecond(LGFolderOpenLiveCaptureFPS())
            : LGPreferredFramesPerSecondForKey(@"Homescreen.FPS", 1);
        LGSetDisplayLinkStatePreferredFPS(&sFolderDisplayLinkState, nextFPS);
        if (LG_prefersLiveCapture(@"FolderOpen.RenderingMode")) {
            for (UIView *host in LGFolderOpenHostRegistry().allObjects) {
                LGHandleFolderOpenMaterialView(host, NO);
            }
        }
        else LG_updateRegisteredGlassViews(LGUpdateGroupFolderOpen);
    });
}

static void stopFolderDisplayLink(void) {
    sFolderStopGeneration++;
    LGStopDisplayLinkState(&sFolderDisplayLinkState);
}

static void scheduleFolderDisplayLinkStopIfIdle(void) {
    NSUInteger generation = ++sFolderStopGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kFolderOpenDisplayLinkGrace * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (generation != sFolderStopGeneration) return;
        if (sFolderDisplayLinkState.activeCount != 0) return;
        stopFolderDisplayLink();
    });
}

static UIView *LGPrimaryFolderOpenHostForContainer(UIView *container) {
    if (!container) return nil;
    __block UIView *bestView = nil;
    __block CGFloat bestArea = 0.0;
    Class materialCls = NSClassFromString(@"MTMaterialView");
    LGTraverseViews(container, ^(UIView *view) {
        if (view == container) return;
        if (!materialCls || ![view isKindOfClass:materialCls]) return;
        if (view.hidden || view.alpha <= 0.01f || view.layer.opacity <= 0.01f) return;
        CGSize size = view.bounds.size;
        if (size.width < 120.0 || size.height < 120.0) return;
        CGFloat area = size.width * size.height;
        if (area > bestArea) {
            bestArea = area;
            bestView = view;
        }
    });
    return bestView;
}

static BOOL LGIsPrimaryFolderOpenHost(UIView *view) {
    UIView *container = folderOpenContainerForView(view);
    if (!container) return NO;
    return LGPrimaryFolderOpenHostForContainer(container) == view;
}

static UIScrollView *LGFolderOpenFindScrollView(UIView *view) {
    UIView *container = folderOpenContainerForView(view) ?: view;
    __block UIScrollView *scrollView = nil;
    LGTraverseViews(container, ^(UIView *candidate) {
        if (scrollView) return;
        if (![candidate isKindOfClass:UIScrollView.class]) return;
        NSString *className = NSStringFromClass(candidate.class);
        if ([className containsString:@"Folder"] ||
            [className containsString:@"Icon"] ||
            [className containsString:@"Scroll"]) {
            scrollView = (UIScrollView *)candidate;
        }
    });
    return scrollView;
}

static NSString *LGFolderOpenLayerSummary(CALayer *layer) {
    if (!layer) return @"(null)";
    CALayer *presentation = layer.presentationLayer ?: layer;
    NSUInteger backgroundFilterCount = 0;
    @try {
        id rawBackgroundFilters = [layer valueForKey:@"backgroundFilters"];
        if ([rawBackgroundFilters isKindOfClass:NSArray.class])
            backgroundFilterCount = [(NSArray *)rawBackgroundFilters count];
    } @catch (__unused NSException *exception) {
        backgroundFilterCount = 0;
    }
    return [NSString stringWithFormat:@"frame=%@ bounds=%@ pres=%@ radius=%.2f masks=%d opacity=%.2f filters=%lu bgFilters=%lu mask=%d",
            NSStringFromCGRect(layer.frame),
            NSStringFromCGRect(layer.bounds),
            NSStringFromCGRect(presentation.frame),
            layer.cornerRadius,
            layer.masksToBounds ? 1 : 0,
            layer.opacity,
            (unsigned long)layer.filters.count,
            (unsigned long)backgroundFilterCount,
            layer.mask ? 1 : 0];
}

static NSString *LGFolderOpenViewSummary(UIView *view) {
    if (!view) return @"(null)";
    return [NSString stringWithFormat:@"%p %@ frame=%@ bounds=%@ alpha=%.2f hidden=%d clips=%d layer={%@}",
            view,
            NSStringFromClass(view.class),
            NSStringFromCGRect(view.frame),
            NSStringFromCGRect(view.bounds),
            view.alpha,
            view.hidden ? 1 : 0,
            view.clipsToBounds ? 1 : 0,
            LGFolderOpenLayerSummary(view.layer)];
}

static NSString *LGFolderOpenAncestorChainSummary(UIView *view) {
    if (!view) return @"(null)";
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    UIView *v = view;
    NSUInteger depth = 0;
    while (v && depth < 10) {
        [parts addObject:LGFolderOpenViewSummary(v)];
        v = v.superview;
        depth++;
    }
    return [parts componentsJoinedByString:@" <- "];
}

static UIView *LGFolderOpenAnyRegisteredHost(void) {
    for (UIView *host in LGFolderOpenHostRegistry().allObjects) {
        if (host.window) return host;
    }
    return nil;
}

static void LGFolderOpenLogHostState(UIView *host, NSString *reason) {
    if (!host) return;
    LiquidGlassView *glass = objc_getAssociatedObject(host, kFolderOpenGlassKey);
    UIView *tint = objc_getAssociatedObject(host, kFolderOpenTintKey);
    UIView *container = folderOpenContainerForView(host);
    UIScrollView *scrollView = LGFolderOpenFindScrollView(host);
    NSString *signature = [NSString stringWithFormat:@"%@|%@|%@|%@|%@|%@|%@",
                           NSStringFromCGRect(host.frame),
                           NSStringFromCGRect(host.bounds),
                           @(host.layer.cornerRadius),
                           @(host.layer.masksToBounds),
                           glass ? NSStringFromCGRect(glass.frame) : @"noglass",
                           glass ? @(glass.layer.cornerRadius) : @"noglass",
                           scrollView ? NSStringFromCGPoint(scrollView.contentOffset) : @"noscroll"];
    NSString *lastSignature = objc_getAssociatedObject(host, kFolderOpenLastDiagnosticKey);
    NSNumber *lastTimeNumber = objc_getAssociatedObject(host, kFolderOpenLastDiagnosticTimeKey);
    CFTimeInterval now = CACurrentMediaTime();
    if ([lastSignature isEqualToString:signature] &&
        lastTimeNumber &&
        now - lastTimeNumber.doubleValue < 0.35) {
        return;
    }
    objc_setAssociatedObject(host, kFolderOpenLastDiagnosticKey, signature, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(host, kFolderOpenLastDiagnosticTimeKey, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    LGDebugLog(@"folder open diag reason=%@ primary=%d host={%@} glass={%@} tint={%@} container={%@} scroll=%@ contentOffset=%@ adjustedInset=%@",
               reason ?: @"(unknown)",
               LGIsPrimaryFolderOpenHost(host) ? 1 : 0,
               LGFolderOpenViewSummary(host),
               LGFolderOpenViewSummary(glass),
               LGFolderOpenViewSummary(tint),
               LGFolderOpenViewSummary(container),
               scrollView ? NSStringFromClass(scrollView.class) : @"(none)",
               scrollView ? NSStringFromCGPoint(scrollView.contentOffset) : @"(none)",
               scrollView ? NSStringFromUIEdgeInsets(scrollView.adjustedContentInset) : @"(none)");
}

static void LGFolderOpenLogScrollState(UIScrollView *scrollView, NSString *reason) {
    if (!scrollView) return;
    UIView *container = LGFolderOpenNearestAncestorClassNamed(scrollView, @"SBFolderBackgroundView");
    UIView *host = LGPrimaryFolderOpenHostForContainer(container) ?: LGFolderOpenAnyRegisteredHost();
    UIView *clipView = LGFolderOpenNearestAncestorClassNamed(scrollView, @"SBFloatyFolderBackgroundClipView");
    UIView *floatyView = LGFolderOpenNearestAncestorClassNamed(scrollView, @"SBFloatyFolderView");
    LGDebugLog(@"folder open scroll diag reason=%@ scroll={%@} clip={%@} floaty={%@} host={%@} chain=%@",
               reason ?: @"(unknown)",
               LGFolderOpenViewSummary(scrollView),
               LGFolderOpenViewSummary(clipView),
               LGFolderOpenViewSummary(floatyView),
               LGFolderOpenViewSummary(host),
               LGFolderOpenAncestorChainSummary(scrollView));
    if (host) LGFolderOpenLogHostState(host, reason ?: @"scroll");
}

static void LGFolderOpenNormalizeFloatyClipView(UIView *clipView, NSString *reason) {
    if (!clipView || !LGFolderOpenEnabled()) return;
    if (![NSStringFromClass(clipView.class) isEqualToString:@"SBFloatyFolderBackgroundClipView"]) return;
    CGSize size = clipView.bounds.size;
    if (size.width < 120.0 || size.height < 120.0) return;

    CGFloat radius = LGFolderOpenCornerRadius();
    BOOL changed = fabs(clipView.layer.cornerRadius - radius) > 0.25 ||
        !clipView.clipsToBounds ||
        !clipView.layer.masksToBounds;
    clipView.clipsToBounds = YES;
    clipView.layer.masksToBounds = YES;
    clipView.layer.cornerRadius = radius;
    if (@available(iOS 13.0, *)) clipView.layer.cornerCurve = kCACornerCurveContinuous;

    if (changed) {
        LGDebugLog(@"folder open clip normalized reason=%@ clip={%@}",
                   reason ?: @"(unknown)",
                   LGFolderOpenViewSummary(clipView));
    }
}

static void LGRestoreFolderOpenHost(UIView *view) {
    LGRemoveAssociatedSubview(view, kFolderOpenTintKey);

    LiquidGlassView *glass = objc_getAssociatedObject(view, kFolderOpenGlassKey);
    if (glass) [glass removeFromSuperview];
    objc_setAssociatedObject(view, kFolderOpenGlassKey, nil, OBJC_ASSOCIATION_ASSIGN);
    LGRemoveLiveBackdropCaptureView(view, kFolderOpenBackdropViewKey);

    NSNumber *originalAlpha = objc_getAssociatedObject(view, kFolderOpenOriginalAlphaKey);
    if (originalAlpha) view.alpha = [originalAlpha doubleValue];
}

static void LGDetachFolderOpenHost(UIView *view) {
    LGRestoreFolderOpenHost(view);
    [LGFolderOpenHostRegistry() removeObject:view];
    objc_setAssociatedObject(view, kFolderOpenLastLiveCaptureTimeKey, nil, OBJC_ASSOCIATION_ASSIGN);
    if (![objc_getAssociatedObject(view, kFolderOpenAttachedKey) boolValue]) return;
    objc_setAssociatedObject(view, kFolderOpenAttachedKey, nil, OBJC_ASSOCIATION_ASSIGN);
    sFolderDisplayLinkState.activeCount = MAX(0, sFolderDisplayLinkState.activeCount - 1);
    LGDisplayLinkStateDidChangeActivity(&sFolderDisplayLinkState);
    if (sFolderDisplayLinkState.activeCount == 0) scheduleFolderDisplayLinkStopIfIdle();
}

static void injectIntoOpenFolder(UIView *host) {
    if (!LGFolderOpenEnabled()) {
        LGDetachFolderOpenHost(host);
        return;
    }
    if (!LGIsPrimaryFolderOpenHost(host)) {
        LGDetachFolderOpenHost(host);
        return;
    }

    if (!objc_getAssociatedObject(host, kFolderOpenOriginalAlphaKey))
        objc_setAssociatedObject(host, kFolderOpenOriginalAlphaKey, @(host.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    LiquidGlassView *glass = objc_getAssociatedObject(host, kFolderOpenGlassKey);
    BOOL hadGlass = (glass != nil);
    if (!LGShouldRefreshLiveCaptureForHost(host,
                                           @"FolderOpen.RenderingMode",
                                           kFolderOpenLastLiveCaptureTimeKey,
                                           LGFolderOpenLiveCaptureFPS(),
                                           hadGlass)) {
        glass.cornerRadius = LGFolderOpenCornerRadius();
        glass.bezelWidth = LGFolderOpenBezelWidth();
        glass.glassThickness = LGFolderOpenGlassThickness();
        glass.refractionScale = LGFolderOpenRefractionScale();
        glass.refractiveIndex = LGFolderOpenRefractiveIndex();
        glass.specularOpacity = LGFolderOpenSpecularOpacity();
        glass.blur = LGFolderOpenBlur();
        glass.wallpaperScale = LGFolderOpenWallpaperScale();
        LGStripFolderOpenMaterialFiltersIfNeeded(host);
        ensureFolderOpenTintOverlay(host);
        LGScheduleFolderOpenResanitize(host);
        [glass updateOrigin];
        LGFolderOpenLogHostState(host, @"rate-limited-update");
        return;
    }

    UIImage *snapshot = LG_getFolderSnapshot();
    if (LG_imageLooksBlack(snapshot)) snapshot = nil;
    if (!snapshot) {
        snapshot = LG_getStrictCachedContextMenuSnapshot();
        if (LG_imageLooksBlack(snapshot)) snapshot = nil;
    }
    if (!snapshot && !LG_prefersLiveCapture(@"FolderOpen.RenderingMode")) {
        NSNumber *originalAlpha = objc_getAssociatedObject(host, kFolderOpenOriginalAlphaKey);
        if (originalAlpha) host.alpha = [originalAlpha doubleValue];
        return;
    }

    if (!glass) {
        glass = [[LiquidGlassView alloc] initWithFrame:host.bounds
                                             wallpaper:snapshot
                                       wallpaperOrigin:CGPointZero];
        glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        glass.userInteractionEnabled = NO;
        glass.updateGroup = LGUpdateGroupFolderOpen;
        [host insertSubview:glass atIndex:0];
        objc_setAssociatedObject(host, kFolderOpenGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else if (!LG_prefersLiveCapture(@"FolderOpen.RenderingMode") && glass.wallpaperImage != snapshot) {
        glass.wallpaperImage = snapshot;
    }

    glass.cornerRadius = LGFolderOpenCornerRadius();
    glass.bezelWidth = LGFolderOpenBezelWidth();
    glass.glassThickness = LGFolderOpenGlassThickness();
    glass.refractionScale = LGFolderOpenRefractionScale();
    glass.refractiveIndex = LGFolderOpenRefractiveIndex();
    glass.specularOpacity = LGFolderOpenSpecularOpacity();
    glass.blur = LGFolderOpenBlur();
    glass.wallpaperScale = LGFolderOpenWallpaperScale();
    LGStripFolderOpenMaterialFiltersIfNeeded(host);
    ensureFolderOpenTintOverlay(host);
    LGScheduleFolderOpenResanitize(host);
    if (!LGApplyRenderingModeToGlassHost(host,
                                         glass,
                                         @"FolderOpen.RenderingMode",
                                         kFolderOpenBackdropViewKey,
                                         snapshot,
                                         CGPointZero)) {
        return;
    }
    if (LG_prefersLiveCapture(@"FolderOpen.RenderingMode")) {
        LGMarkLiveCaptureRefreshedForHost(host, kFolderOpenLastLiveCaptureTimeKey);
    }

    if (![objc_getAssociatedObject(host, kFolderOpenAttachedKey) boolValue]) {
        [LGFolderOpenHostRegistry() addObject:host];
        objc_setAssociatedObject(host, kFolderOpenAttachedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        sFolderDisplayLinkState.activeCount++;
        LGDisplayLinkStateDidChangeActivity(&sFolderDisplayLinkState);
    }
    startFolderDisplayLink();
    LGFolderOpenLogHostState(host, hadGlass ? @"inject-update" : @"inject-create");
}

static void LGFolderOpenForEachMaterialHost(void (^block)(UIView *view)) {
    if (!block) return;
    UIApplication *app = UIApplication.sharedApplication;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                LGTraverseViews(window, ^(UIView *view) {
                    if (![view isKindOfClass:NSClassFromString(@"MTMaterialView")]) return;
                    if (!isInsideOpenFolder(view)) return;
                    block(view);
                });
            }
        }
    } else {
        for (UIWindow *window in LGApplicationWindows(app)) {
            LGTraverseViews(window, ^(UIView *view) {
                if (![view isKindOfClass:NSClassFromString(@"MTMaterialView")]) return;
                if (!isInsideOpenFolder(view)) return;
                block(view);
            });
        }
    }
}

static void LGHandleFolderOpenMaterialView(UIView *view, BOOL updateOnly) {
    if (!view) return;
    LGStripFolderControllerBackgroundMaterialFiltersIfNeeded(view);
    if (!view.window) {
        LGDetachFolderOpenHost(view);
        return;
    }
    if (!isInsideOpenFolder(view) || !LGIsPrimaryFolderOpenHost(view) || !LGFolderOpenEnabled()) {
        LGDetachFolderOpenHost(view);
        return;
    }
    if (!updateOnly) {
        injectIntoOpenFolder(view);
        return;
    }
    LiquidGlassView *glass = objc_getAssociatedObject(view, kFolderOpenGlassKey);
    ensureFolderOpenTintOverlay(view);
    if (!glass) {
        injectIntoOpenFolder(view);
        return;
    }
    glass.cornerRadius = LGFolderOpenCornerRadius();
    glass.bezelWidth = LGFolderOpenBezelWidth();
    glass.glassThickness = LGFolderOpenGlassThickness();
    glass.refractionScale = LGFolderOpenRefractionScale();
    glass.refractiveIndex = LGFolderOpenRefractiveIndex();
    glass.specularOpacity = LGFolderOpenSpecularOpacity();
    glass.blur = LGFolderOpenBlur();
    glass.wallpaperScale = LGFolderOpenWallpaperScale();
    LGStripFolderOpenMaterialFiltersIfNeeded(view);
    [glass updateOrigin];
    LGScheduleFolderOpenResanitize(view);
    LGFolderOpenLogHostState(view, @"material-layout");
}

static void LGFolderOpenRefreshAllHosts(void) {
    LGFolderOpenForEachMaterialHost(^(UIView *view) {
        LGHandleFolderOpenMaterialView(view, NO);
    });
}

static void LGFolderOpenPrefsChanged(CFNotificationCenterRef center,
                                     void *observer,
                                     CFStringRef name,
                                     const void *object,
                                     CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!LGFolderOpenEnabled()) {
            LGFolderOpenForEachMaterialHost(^(UIView *view) {
                LGDetachFolderOpenHost(view);
            });
            stopFolderDisplayLink();
            return;
        }
        LGFolderOpenRefreshAllHosts();
    });
}

%group LGFolderOpenSpringBoard

%hook MTMaterialView

- (void)didMoveToWindow {
    %orig;
    UIView *self_ = (UIView *)self;
    LGHandleFolderOpenMaterialView(self_, NO);
}

- (void)layoutSubviews {
    %orig;
    UIView *self_ = (UIView *)self;
    LGHandleFolderOpenMaterialView(self_, YES);
}

%end

%hook SBFloatyFolderBackgroundClipView

- (void)didMoveToWindow {
    %orig;
    LGFolderOpenNormalizeFloatyClipView((UIView *)self, @"clip-window");
}

- (void)layoutSubviews {
    %orig;
    LGFolderOpenNormalizeFloatyClipView((UIView *)self, @"clip-layout");
}

%end

%hook UIScrollView

- (void)setContentOffset:(CGPoint)contentOffset {
    %orig;
    UIView *self_ = (UIView *)self;
    if (!isInsideOpenFolder(self_) && !LGIsInsideFloatyOpenFolder(self_)) return;
    LGFolderOpenNormalizeFloatyClipView(LGFolderOpenNearestAncestorClassNamed(self_, @"SBFloatyFolderBackgroundClipView"),
                                        @"scroll-content-offset");
    UIView *container = folderOpenContainerForView(self_);
    UIView *host = LGPrimaryFolderOpenHostForContainer(container);
    if (host) LGFolderOpenLogHostState(host, @"scroll-content-offset");
    LGFolderOpenLogScrollState((UIScrollView *)self_, @"scroll-content-offset");
}

- (void)setContentOffset:(CGPoint)contentOffset animated:(BOOL)animated {
    %orig;
    UIView *self_ = (UIView *)self;
    if (!isInsideOpenFolder(self_) && !LGIsInsideFloatyOpenFolder(self_)) return;
    NSString *reason = animated ? @"scroll-content-offset-animated" : @"scroll-content-offset";
    LGFolderOpenNormalizeFloatyClipView(LGFolderOpenNearestAncestorClassNamed(self_, @"SBFloatyFolderBackgroundClipView"),
                                        reason);
    UIView *container = folderOpenContainerForView(self_);
    UIView *host = LGPrimaryFolderOpenHostForContainer(container);
    if (host) LGFolderOpenLogHostState(host, reason);
    LGFolderOpenLogScrollState((UIScrollView *)self_, reason);
}

%end

%end

%ctor {
    if (!LGIsSpringBoardProcess()) return;
    LGObservePreferenceChanges(^{
        LGFolderOpenPrefsChanged(NULL, NULL, NULL, NULL, NULL);
    });
    %init(LGFolderOpenSpringBoard);
}
