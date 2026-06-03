#import "../Shared/LGSharedSupport.h"
#import <objc/message.h>
#import <objc/runtime.h>

static void *kLGAlertOverlayKey = &kLGAlertOverlayKey;
static void *kLGAlertButtonsKey = &kLGAlertButtonsKey;

@interface UIAlertController (LGAlertPrivate)
- (void)_dismissAnimated:(BOOL)animated triggeringAction:(UIAlertAction *)action;
@end

static BOOL LGAlertsEnabled(void) {
    return LG_globalEnabled();
}

static NSString *LGAlertActionTitle(UIAlertAction *action) {
    NSString *title = action.title;
    return title.length ? title : @"";
}

static UIButton *LGAlertMakeActionButton(UIAlertAction *action, BOOL primaryCancel) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.layer.cornerRadius = 23.0;
    if (@available(iOS 13.0, *)) button.layer.cornerCurve = kCACornerCurveContinuous;
    button.layer.masksToBounds = YES;
    button.adjustsImageWhenHighlighted = NO;
    button.showsTouchWhenHighlighted = NO;
    button.titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
    [button setTitle:LGAlertActionTitle(action) forState:UIControlStateNormal];
    [button setTitle:LGAlertActionTitle(action) forState:UIControlStateHighlighted];

    BOOL destructive = (action.style == UIAlertActionStyleDestructive);
    BOOL blue = primaryCancel || (!destructive && action.style != UIAlertActionStyleCancel);
    UIColor *backgroundColor = blue ? [UIColor systemBlueColor] : [UIColor tertiarySystemFillColor];
    UIColor *titleColor = destructive ? [UIColor systemRedColor] : (blue ? [UIColor whiteColor] : [UIColor secondaryLabelColor]);
    button.backgroundColor = backgroundColor;
    [button setTitleColor:titleColor forState:UIControlStateNormal];
    [button setTitleColor:titleColor forState:UIControlStateHighlighted];
    [button setTitleColor:[titleColor colorWithAlphaComponent:0.45] forState:UIControlStateDisabled];
    button.enabled = action.enabled;
    return button;
}

static UIAlertAction *LGAlertCancelAction(NSArray<UIAlertAction *> *actions) {
    for (UIAlertAction *action in actions) {
        if (action.style == UIAlertActionStyleCancel) return action;
    }
    return nil;
}

static void LGAlertTriggerMappedAction(UIAlertController *controller, UIView *overlay, UIAlertAction *action) {
    if (!controller || !action) return;

    overlay.userInteractionEnabled = NO;
    [UIView animateWithDuration:0.12 animations:^{
        overlay.alpha = 0.0;
        overlay.transform = CGAffineTransformMakeScale(0.96, 0.96);
    }];

    controller.view.hidden = NO;
    controller.view.userInteractionEnabled = YES;
    controller.view.alpha = 0.02;

    SEL mappedDismissSelector = @selector(_dismissAnimated:triggeringAction:);
    if ([controller respondsToSelector:mappedDismissSelector]) {
        ((void (*)(id, SEL, BOOL, UIAlertAction *))objc_msgSend)(controller, mappedDismissSelector, YES, action);
        return;
    }

    [controller dismissViewControllerAnimated:YES completion:nil];
}

static BOOL LGAlertShouldReplace(UIAlertController *controller) {
    if (!LGAlertsEnabled() || !controller) return NO;
    if (controller.preferredStyle != UIAlertControllerStyleAlert) return NO;
    if (controller.textFields.count > 0) return NO;
    if (controller.actions.count == 0) return NO;
    return YES;
}

static void LGAlertInstallReplacement(UIAlertController *controller) {
    if (!LGAlertShouldReplace(controller)) return;
    if (objc_getAssociatedObject(controller, kLGAlertOverlayKey)) return;

    UIView *hostView = controller.view.superview ?: controller.view.window;
    if (!hostView) return;

    controller.view.hidden = NO;
    controller.view.alpha = 0.02;
    controller.view.userInteractionEnabled = YES;

    UIView *overlay = [[UIView alloc] initWithFrame:hostView.bounds];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = UIColor.clearColor;
    overlay.alpha = 0.0;
    overlay.transform = CGAffineTransformMakeScale(0.96, 0.96);
    objc_setAssociatedObject(controller, kLGAlertOverlayKey, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIVisualEffectView *panel = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    panel.layer.cornerRadius = 32.0;
    if (@available(iOS 13.0, *)) panel.layer.cornerCurve = kCACornerCurveContinuous;
    panel.layer.masksToBounds = YES;

    UIStackView *contentStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    contentStack.translatesAutoresizingMaskIntoConstraints = NO;
    contentStack.axis = UILayoutConstraintAxisVertical;
    contentStack.spacing = 10.0;

    if (controller.title.length) {
        UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        titleLabel.text = controller.title;
        titleLabel.font = [UIFont systemFontOfSize:24.0 weight:UIFontWeightBold];
        titleLabel.textColor = [UIColor labelColor];
        titleLabel.textAlignment = NSTextAlignmentLeft;
        titleLabel.numberOfLines = 0;
        [contentStack addArrangedSubview:titleLabel];
    }

    if (controller.message.length) {
        UILabel *messageLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        messageLabel.text = controller.message;
        messageLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightMedium];
        messageLabel.textColor = [UIColor secondaryLabelColor];
        messageLabel.textAlignment = NSTextAlignmentLeft;
        messageLabel.numberOfLines = 0;
        [contentStack addArrangedSubview:messageLabel];
    }

    NSArray<UIAlertAction *> *actions = controller.actions;
    UIAlertAction *cancelAction = LGAlertCancelAction(actions);
    BOOL twoButtonCancelPrimary = actions.count == 2 && cancelAction != nil;
    NSMutableArray<UIButton *> *buttons = [NSMutableArray arrayWithCapacity:actions.count];
    for (UIAlertAction *action in actions) {
        [buttons addObject:LGAlertMakeActionButton(action, twoButtonCancelPrimary && action == cancelAction)];
    }

    UIStackView *buttonStack = [[UIStackView alloc] initWithArrangedSubviews:buttons];
    buttonStack.translatesAutoresizingMaskIntoConstraints = NO;
    buttonStack.axis = actions.count <= 2 ? UILayoutConstraintAxisHorizontal : UILayoutConstraintAxisVertical;
    buttonStack.spacing = 12.0;
    buttonStack.distribution = UIStackViewDistributionFillEqually;

    [overlay addSubview:panel];
    [panel.contentView addSubview:contentStack];
    [panel.contentView addSubview:buttonStack];
    [hostView addSubview:overlay];

    NSMutableArray<NSLayoutConstraint *> *constraints = [NSMutableArray arrayWithArray:@[
        [panel.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
        [panel.centerYAnchor constraintEqualToAnchor:overlay.centerYAnchor],
        [panel.widthAnchor constraintEqualToConstant:320.0],
        [panel.leadingAnchor constraintGreaterThanOrEqualToAnchor:overlay.leadingAnchor constant:24.0],
        [panel.trailingAnchor constraintLessThanOrEqualToAnchor:overlay.trailingAnchor constant:-24.0],
        [contentStack.topAnchor constraintEqualToAnchor:panel.contentView.topAnchor constant:28.0],
        [contentStack.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:24.0],
        [contentStack.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-24.0],
        [buttonStack.topAnchor constraintEqualToAnchor:contentStack.bottomAnchor constant:24.0],
        [buttonStack.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:16.0],
        [buttonStack.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-16.0],
        [buttonStack.bottomAnchor constraintEqualToAnchor:panel.contentView.bottomAnchor constant:-16.0],
    ]];
    for (UIButton *button in buttons) {
        [constraints addObject:[button.heightAnchor constraintEqualToConstant:46.0]];
    }
    [NSLayoutConstraint activateConstraints:constraints];
    objc_setAssociatedObject(controller, kLGAlertButtonsKey, buttons, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    __weak UIAlertController *weakController = controller;
    __weak UIView *weakOverlay = overlay;
    for (NSUInteger i = 0; i < buttons.count; i++) {
        UIButton *button = buttons[i];
        UIAlertAction *action = actions[i];
        [button addAction:[UIAction actionWithHandler:^(__unused UIAction *uiAction) {
            UIAlertController *strongController = weakController;
            UIView *strongOverlay = weakOverlay;
            if (!strongController || !strongOverlay) return;
            LGAlertTriggerMappedAction(strongController, strongOverlay, action);
        }] forControlEvents:UIControlEventTouchUpInside];
    }

    [UIView animateWithDuration:0.22 animations:^{
        overlay.alpha = 1.0;
        overlay.transform = CGAffineTransformIdentity;
    }];
}

static void LGAlertRemoveReplacement(UIAlertController *controller) {
    UIView *overlay = objc_getAssociatedObject(controller, kLGAlertOverlayKey);
    [overlay removeFromSuperview];
    objc_setAssociatedObject(controller, kLGAlertOverlayKey, nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(controller, kLGAlertButtonsKey, nil, OBJC_ASSOCIATION_ASSIGN);
}

%group LGAlertsSpringBoard

%hook UIAlertController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    LGAlertInstallReplacement((UIAlertController *)self);
}

- (void)viewDidLayoutSubviews {
    %orig;
    LGAlertInstallReplacement((UIAlertController *)self);
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    LGAlertRemoveReplacement((UIAlertController *)self);
}

%end

%end

%ctor {
    if (!LGIsSpringBoardProcess()) return;
    %init(LGAlertsSpringBoard);
}
