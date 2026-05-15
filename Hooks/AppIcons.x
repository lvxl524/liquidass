#import "../LiquidGlass.h"
#import "../Shared/LGHookSupport.h"
#import "../Shared/LGBannerCaptureSupport.h"
#import "../Shared/LGPrefAccessors.h"
#import <objc/runtime.h>

static const NSInteger kAppIconTintTag = 0xA110;

static void *kAppIconRetryKey = &kAppIconRetryKey;
static void *kAppIconGlassKey = &kAppIconGlassKey;
static void *kAppIconTintKey = &kAppIconTintKey;
static void *kAppIconOverlayHostKey = &kAppIconOverlayHostKey;
static void *kAppIconLastGlassFrameKey = &kAppIconLastGlassFrameKey;
static void *kAppIconBackdropViewKey = &kAppIconBackdropViewKey;
static BOOL sAppIconProbePending = NO;
static CFTimeInterval sAppIconLastProbeTime = 0.0;

LG_ENABLED_BOOL_PREF_FUNC(LGAppIconsEnabled, "AppIcons.Enabled", NO)
LG_FLOAT_PREF_FUNC(LGAppIconCornerRadius, "AppIcons.CornerRadius", 13.5)
LG_FLOAT_PREF_FUNC(LGAppIconBezelWidth, "AppIcons.BezelWidth", 14.0)
LG_FLOAT_PREF_FUNC(LGAppIconGlassThickness, "AppIcons.GlassThickness", 80.0)
LG_FLOAT_PREF_FUNC(LGAppIconRefractionScale, "AppIcons.RefractionScale", 1.2)
LG_FLOAT_PREF_FUNC(LGAppIconRefractiveIndex, "AppIcons.RefractiveIndex", 1.0)
LG_FLOAT_PREF_FUNC(LGAppIconSpecularOpacity, "AppIcons.SpecularOpacity", 0.6)
LG_FLOAT_PREF_FUNC(LGAppIconBlur, "AppIcons.Blur", 8.0)
LG_FLOAT_PREF_FUNC(LGAppIconWallpaperScale, "AppIcons.WallpaperScale", 0.5)
LG_FLOAT_PREF_FUNC(LGAppIconLightTintAlpha, "AppIcons.LightTintAlpha", 0.1)
LG_FLOAT_PREF_FUNC(LGAppIconDarkTintAlpha, "AppIcons.DarkTintAlpha", 0.0)

static NSString *LGAppIconViewSummary(UIView *view) {
    if (!view) return @"nil";
    return [NSString stringWithFormat:@"%p %@ frame=%@ bounds=%@ alpha=%.2f hidden=%d ui=%d subviews=%lu",
            view,
            NSStringFromClass(view.class),
            NSStringFromCGRect(view.frame),
            NSStringFromCGRect(view.bounds),
            view.alpha,
            view.hidden,
            view.userInteractionEnabled,
            (unsigned long)view.subviews.count];
}

static NSString *LGAppIconAncestorChain(UIView *view) {
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

static NSString *LGAppIconSiblingClasses(UIView *view) {
    UIView *parent = view.superview;
    if (!parent) return @"";
    NSMutableArray<NSString *> *classes = [NSMutableArray array];
    NSUInteger count = 0;
    for (UIView *sibling in parent.subviews) {
        [classes addObject:[NSString stringWithFormat:@"%@%@",
                            sibling == view ? @"*" : @"",
                            NSStringFromClass(sibling.class)]];
        count++;
        if (count >= 18) {
            [classes addObject:@"..."];
            break;
        }
    }
    return [classes componentsJoinedByString:@","];
}

static BOOL LGAppIconSubtreeContainsWidgetContent(UIView *root) {
    if (!root) return NO;
    __block BOOL found = NO;
    LGTraverseViews(root, ^(UIView *view) {
        if (found || view == root) return;
        NSString *className = NSStringFromClass(view.class);
        if ([className isEqualToString:@"SBHWidgetContainerView"] ||
            [className isEqualToString:@"BSUIScrollView"] ||
            [className containsString:@"Widget"] ||
            [className hasPrefix:@"WG"]) {
            found = YES;
        }
    });
    return found;
}

static UIView *LGAppIconNearestAncestorNamed(UIView *view, NSString *className, NSInteger maxDepth) {
    UIView *ancestor = view.superview;
    NSInteger depth = 0;
    while (ancestor && depth < maxDepth) {
        if ([NSStringFromClass(ancestor.class) isEqualToString:className]) return ancestor;
        ancestor = ancestor.superview;
        depth++;
    }
    return nil;
}

static NSString *LGAppIconClassificationFailureReason(UIView *view) {
    if (!view.window) return @"no-window";
    if (![NSStringFromClass(view.class) isEqualToString:@"SBIconImageView"]) return @"not-SBIconImageView";
    if (LGResponderChainContainsClassNamed(view, @"SBFolderViewController")) return @"folder-responder";
    if (LGResponderChainContainsClassNamed(view, @"SBAppLibraryViewController")) return @"app-library-responder";
    if (LGResponderChainContainsClassNamed(view, @"SBHWidgetStackViewController")) return @"widget-stack-responder";
    if (LGHasAncestorClassNamed(view, @"SBHWidgetContainerView")) return @"widget-container-ancestor";
    if (LGHasAncestorClassNamed(view, @"BSUIScrollView")) return @"bsui-scroll-ancestor";
    if (LGHasAncestorClassNamed(view, @"SBFloatyFolderView")) return @"floaty-folder-ancestor";
    if (LGHasAncestorClassNamed(view, @"SBFloatyFolderScrollView")) return @"floaty-folder-scroll-ancestor";

    UIView *iconView = LGAppIconNearestAncestorNamed(view, @"SBIconView", 6);
    if (!iconView) return @"no-icon-view";
    if (LGResponderChainContainsClassNamed(iconView, @"SBHWidgetStackViewController")) return @"icon-widget-stack-responder";
    if (LGAppIconSubtreeContainsWidgetContent(iconView)) return @"icon-widget-subtree";

    UIView *iconListView = iconView.superview;
    if (!iconListView) return @"no-icon-list";
    NSString *iconListClass = NSStringFromClass(iconListView.class);
    BOOL regularList = [iconListClass isEqualToString:@"SBIconListView"];
    BOOL floatingDockList = [iconListClass isEqualToString:@"SBFloatingDockIconListView"];
    if (!regularList && !floatingDockList) {
        return [NSString stringWithFormat:@"icon-list=%@", NSStringFromClass(iconListView.class)];
    }
    if (regularList &&
        !LGHasAncestorClassNamed(iconListView, @"SBRootFolderView") &&
        !LGHasAncestorClassNamed(iconListView, @"SBFloatingDockView")) {
        return @"regular-list-not-root-or-dock";
    }
    if (floatingDockList && !LGHasAncestorClassNamed(iconListView, @"SBFloatingDockView")) {
        return @"floating-list-not-dock";
    }
    return nil;
}

static BOOL LGIsHomescreenIconImageView(UIView *view) {
    return LGAppIconClassificationFailureReason(view) == nil;
}

static void LGScheduleAppIconHierarchyProbe(NSString *reason) {
    if (!LG_prefBool(@"DebugLogging.Enabled", NO)) return;
    CFTimeInterval now = CACurrentMediaTime();
    if (sAppIconProbePending || (now - sAppIconLastProbeTime) < 1.0) return;
    sAppIconProbePending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        sAppIconProbePending = NO;
        sAppIconLastProbeTime = CACurrentMediaTime();

        __block UIWindow *homeWindow = nil;
        Class homeWindowClass = NSClassFromString(@"SBHomeScreenWindow");
        if (@available(iOS 13.0, *)) {
            for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                if (![scene isKindOfClass:[UIWindowScene class]]) continue;
                for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                    if ([window isKindOfClass:homeWindowClass]) {
                        homeWindow = window;
                        break;
                    }
                }
                if (homeWindow) break;
            }
        }
        if (!homeWindow) {
            for (UIWindow *window in UIApplication.sharedApplication.windows) {
                if ([window isKindOfClass:homeWindowClass]) {
                    homeWindow = window;
                    break;
                }
            }
        }
        if (!homeWindow) {
            LGDebugLog(@"appicons probe reason=%@ no SBHomeScreenWindow", reason ?: @"unknown");
            return;
        }

        __block NSUInteger total = 0;
        __block NSUInteger accepted = 0;
        __block NSMutableDictionary<NSString *, NSNumber *> *failures = [NSMutableDictionary dictionary];
        LGTraverseViews(homeWindow, ^(UIView *view) {
            if (![NSStringFromClass(view.class) isEqualToString:@"SBIconImageView"]) return;
            total++;
            NSString *failure = LGAppIconClassificationFailureReason(view);
            if (!failure) accepted++;
            else failures[failure] = @([failures[failure] unsignedIntegerValue] + 1);

            LGDebugLog(@"appicons probe item accepted=%d failure=%@ view=%@ parent=%@ grandparent=%@ chain=%@ parentSiblings=%@ grandparentSiblings=%@",
                       failure == nil,
                       failure ?: @"",
                       LGAppIconViewSummary(view),
                       LGAppIconViewSummary(view.superview),
                       LGAppIconViewSummary(view.superview.superview),
                       LGAppIconAncestorChain(view),
                       LGAppIconSiblingClasses(view),
                       LGAppIconSiblingClasses(view.superview.superview));
        });
        LGDebugLog(@"appicons probe summary reason=%@ window=%@ total=%lu accepted=%lu failures=%@",
                   reason ?: @"unknown",
                   LGAppIconViewSummary(homeWindow),
                   (unsigned long)total,
                   (unsigned long)accepted,
                   failures);
    });
}

static UIView *LGAppIconHostView(UIView *view) {
    UIView *host = objc_getAssociatedObject(view, kAppIconOverlayHostKey);
    if (host) return host;
    UIView *parent = view.superview;
    return parent ?: view;
}

static CGRect LGAppIconGlassFrameInHost(UIView *iconView, UIView *host) {
    if (!iconView || !host) return CGRectZero;
    return [iconView convertRect:iconView.bounds toView:host];
}

static UIColor *appIconTintColorForView(UIView *view) {
    return LGDefaultTintColorForViewWithOverrideKey(view, LGAppIconLightTintAlpha(), LGAppIconDarkTintAlpha(), @"AppIcons.TintOverrideMode");
}

static void removeAppIconOverlays(UIView *view) {
    UIView *host = LGAppIconHostView(view);
    LGRemoveAssociatedSubview(host, kAppIconTintKey);
    if (view.superview && view.superview != host) {
        LGRemoveAssociatedSubview(view.superview, kAppIconTintKey);
    }

    LiquidGlassView *glass = objc_getAssociatedObject(host, kAppIconGlassKey);
    if (glass) [glass removeFromSuperview];
    objc_setAssociatedObject(host, kAppIconGlassKey, nil, OBJC_ASSOCIATION_ASSIGN);

    LGRemoveLiveBackdropCaptureView(host, kAppIconBackdropViewKey);
    UIView *overlayHost = objc_getAssociatedObject(view, kAppIconOverlayHostKey);
    if (overlayHost) [overlayHost removeFromSuperview];
    objc_setAssociatedObject(view, kAppIconOverlayHostKey, nil, OBJC_ASSOCIATION_ASSIGN);
}

static void ensureAppIconTintOverlay(UIView *view) {
    UIView *host = objc_getAssociatedObject(view, kAppIconOverlayHostKey);
    if (!host) return;
    CGRect frame = host.bounds;
    UIView *tint = LGEnsureTintOverlayView(host,
                                           kAppIconTintKey,
                                           kAppIconTintTag,
                                           frame,
                                           UIViewAutoresizingNone);
    LGConfigureTintOverlayView(tint,
                               appIconTintColorForView(view),
                               LGAppIconCornerRadius(),
                               nil,
                               NO);
    if (@available(iOS 13.0, *)) {
        tint.layer.cornerCurve = kCACornerCurveContinuous;
    }
    LiquidGlassView *glass = objc_getAssociatedObject(host, kAppIconGlassKey);
    if (glass) [host insertSubview:tint aboveSubview:glass];
    else [host bringSubviewToFront:tint];
}

static void injectIntoAppIcon(UIView *view) {
    CFTimeInterval profileStart = LGProfileBegin();
    if (!LGAppIconsEnabled()) {
        removeAppIconOverlays(view);
        LGProfileEnd(@"app_icons.inject", profileStart);
        return;
    }

    UIView *parentHost = view.superview ?: view;
    CGRect frameInParent = LGAppIconGlassFrameInHost(view, parentHost);
    if (CGRectIsEmpty(frameInParent)) {
        LGProfileEnd(@"app_icons.inject", profileStart);
        return;
    }
    LGRemoveAssociatedSubview(parentHost, kAppIconTintKey);
    UIView *host = objc_getAssociatedObject(view, kAppIconOverlayHostKey);
    if (!host) {
        host = [[UIView alloc] initWithFrame:frameInParent];
        host.userInteractionEnabled = NO;
        host.backgroundColor = UIColor.clearColor;
        host.clipsToBounds = NO;
        [parentHost insertSubview:host belowSubview:view];
        objc_setAssociatedObject(view, kAppIconOverlayHostKey, host, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        host.frame = frameInParent;
        if (host.superview != parentHost) {
            [host removeFromSuperview];
            [parentHost insertSubview:host belowSubview:view];
        }
    }

    CGRect frame = host.bounds;

    LiquidGlassView *glass = objc_getAssociatedObject(host, kAppIconGlassKey);
    CGPoint wallpaperOrigin = CGPointZero;
    UIImage *wallpaper = LG_getHomescreenSnapshot(&wallpaperOrigin);
    if (!wallpaper && !LG_prefersLiveCapture(@"AppIcons.RenderingMode")) {
        if ([objc_getAssociatedObject(host, kAppIconRetryKey) boolValue]) return;
        objc_setAssociatedObject(host, kAppIconRetryKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            objc_setAssociatedObject(host, kAppIconRetryKey, nil, OBJC_ASSOCIATION_ASSIGN);
            injectIntoAppIcon(view);
        });
        LGProfileEnd(@"app_icons.inject", profileStart);
        return;
    }

    if (!glass) {
        glass = [[LiquidGlassView alloc] initWithFrame:frame
                                             wallpaper:wallpaper
                                       wallpaperOrigin:wallpaperOrigin];
        glass.cornerRadius = LGAppIconCornerRadius();
        glass.bezelWidth = LGAppIconBezelWidth();
        glass.glassThickness = LGAppIconGlassThickness();
        glass.refractionScale = LGAppIconRefractionScale();
        glass.refractiveIndex = LGAppIconRefractiveIndex();
        glass.specularOpacity = LGAppIconSpecularOpacity();
        glass.blur = LGAppIconBlur();
        glass.wallpaperScale = LGAppIconWallpaperScale();
        glass.updateGroup = LGUpdateGroupAppIcons;
        [host insertSubview:glass atIndex:0];
        objc_setAssociatedObject(host, kAppIconGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    glass.frame = frame;
    glass.cornerRadius = LGAppIconCornerRadius();
    glass.bezelWidth = LGAppIconBezelWidth();
    glass.glassThickness = LGAppIconGlassThickness();
    glass.refractionScale = LGAppIconRefractionScale();
    glass.refractiveIndex = LGAppIconRefractiveIndex();
    glass.specularOpacity = LGAppIconSpecularOpacity();
    glass.blur = LGAppIconBlur();
    glass.wallpaperScale = LGAppIconWallpaperScale();
    if (!LGApplyRenderingModeToGlassHost(host,
                                         glass,
                                         @"AppIcons.RenderingMode",
                                         kAppIconBackdropViewKey,
                                         wallpaper,
                                         wallpaperOrigin)) {
        objc_setAssociatedObject(host, kAppIconRetryKey, nil, OBJC_ASSOCIATION_ASSIGN);
        LGProfileEnd(@"app_icons.inject", profileStart);
        return;
    }
    objc_setAssociatedObject(host, kAppIconLastGlassFrameKey,
                             [NSValue valueWithCGRect:frame],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ensureAppIconTintOverlay(view);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (view.window) ensureAppIconTintOverlay(view);
    });
    objc_setAssociatedObject(host, kAppIconRetryKey, nil, OBJC_ASSOCIATION_ASSIGN);
    LGProfileEnd(@"app_icons.inject", profileStart);
}

%hook SBIconImageView

- (void)didMoveToWindow {
    %orig;
    UIView *self_ = (UIView *)self;
    LGScheduleAppIconHierarchyProbe(@"icon-didMoveToWindow");
    if (!self_.window) {
        removeAppIconOverlays(self_);
        return;
    }
    if (!LGIsHomescreenIconImageView(self_)) {
        removeAppIconOverlays(self_);
        return;
    }
    injectIntoAppIcon(self_);
}

- (void)layoutSubviews {
    %orig;
    UIView *self_ = (UIView *)self;
    LGScheduleAppIconHierarchyProbe(@"icon-layout");
    if (!LGIsHomescreenIconImageView(self_)) {
        removeAppIconOverlays(self_);
        return;
    }
    if (!LGAppIconsEnabled()) {
        removeAppIconOverlays(self_);
        return;
    }
    UIView *host = objc_getAssociatedObject(self_, kAppIconOverlayHostKey);
    if (!host) {
        injectIntoAppIcon(self_);
        return;
    }
    LiquidGlassView *glass = objc_getAssociatedObject(host, kAppIconGlassKey);
    if (!glass) {
        injectIntoAppIcon(self_);
        return;
    }
    CGRect frame = host.bounds;
    if (CGRectIsEmpty(frame)) return;
    ensureAppIconTintOverlay(self_);
    glass.frame = frame;
    glass.cornerRadius = LGAppIconCornerRadius();
    glass.bezelWidth = LGAppIconBezelWidth();
    glass.glassThickness = LGAppIconGlassThickness();
    glass.refractionScale = LGAppIconRefractionScale();
    glass.refractiveIndex = LGAppIconRefractiveIndex();
    glass.specularOpacity = LGAppIconSpecularOpacity();
    glass.blur = LGAppIconBlur();
    glass.wallpaperScale = LGAppIconWallpaperScale();
    CGRect lastFrame = [objc_getAssociatedObject(host, kAppIconLastGlassFrameKey) CGRectValue];
    if (!CGRectEqualToRect(lastFrame, frame)) {
        [glass updateOrigin];
        objc_setAssociatedObject(host, kAppIconLastGlassFrameKey,
                                 [NSValue valueWithCGRect:frame],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

%end

%hook SBHomeScreenWindow

- (void)didMoveToWindow {
    %orig;
    LGScheduleAppIconHierarchyProbe(@"home-window-didMoveToWindow");
}

- (void)layoutSubviews {
    %orig;
    LGScheduleAppIconHierarchyProbe(@"home-window-layout");
}

%end

%hook SBIconScrollView

- (void)setContentOffset:(CGPoint)offset {
    %orig;
    LGScheduleAppIconHierarchyProbe(@"icon-scroll-offset");
    LG_updateRegisteredGlassViews(LGUpdateGroupAppIcons);
}

- (void)setContentOffset:(CGPoint)offset animated:(BOOL)animated {
    %orig;
    LGScheduleAppIconHierarchyProbe(@"icon-scroll-offset-animated");
    LG_updateRegisteredGlassViews(LGUpdateGroupAppIcons);
}

%end
