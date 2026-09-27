#include "SpringBoardControlHost.h"

#include "InternalGalleryViewController.h"
#include "ProductControlOwner.h"
#include "SpringBoardFloatingButtonGeometry.h"

#import <UIKit/UIKit.h>

#include <memory>

static dispatch_queue_t
ProductOwnerInitializationQueue();

static constexpr CGFloat
    kFloatingButtonSize = 56.0;
static constexpr CGFloat
    kFloatingButtonEdgeMargin = 10.0;

@interface VCAMProductOverlayWindow : UIWindow
@end

@implementation VCAMProductOverlayWindow

- (UIView*)hitTest:
    (CGPoint)point
         withEvent:(UIEvent*)event {
    UIView* hit =
        [super hitTest:point
             withEvent:event];

    if (hit == self.rootViewController.view) {
        return nil;
    }

    return hit;
}

@end

@interface VCAMProductOverlayController
    : UIViewController
@end

@implementation VCAMProductOverlayController {
    std::shared_ptr<
        vcam::product::ProductControlOwner>
        _owner;
    UIButton* _floatingButton;
    NSLayoutConstraint*
        _floatingButtonCenterXConstraint;
    NSLayoutConstraint*
        _floatingButtonCenterYConstraint;
    BOOL _floatingButtonPositionInitialized;
    BOOL _ownerInitializationStarted;
    BOOL _ownerReady;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor =
        [UIColor clearColor];

    _floatingButton =
        [UIButton
            buttonWithType:
                UIButtonTypeSystem];

    [_floatingButton
        setTitle:@"VCAM"
        forState:UIControlStateNormal];

    _floatingButton.backgroundColor =
        [UIColor
            colorWithWhite:0.1
                     alpha:0.9];

    [_floatingButton
        setTitleColor:
            [UIColor whiteColor]
        forState:
            UIControlStateNormal];

    _floatingButton.layer.cornerRadius =
        kFloatingButtonSize * 0.5;
    _floatingButton.translatesAutoresizingMaskIntoConstraints =
        NO;
    _floatingButton.enabled = NO;

    [_floatingButton
        addTarget:self
           action:@selector(openControl)
 forControlEvents:
     UIControlEventTouchUpInside];

    UIPanGestureRecognizer* pan =
        [[UIPanGestureRecognizer alloc]
            initWithTarget:self
                    action:
                        @selector(
                            handleFloatingButtonPan:)];

    pan.cancelsTouchesInView = YES;
    pan.delaysTouchesBegan = NO;
    pan.maximumNumberOfTouches = 1;

    [_floatingButton
        addGestureRecognizer:pan];

    [NSLayoutConstraint
        activateConstraints:@[
            [[_floatingButton
                widthAnchor]
                constraintEqualToConstant:
                    kFloatingButtonSize],
            [[_floatingButton
                heightAnchor]
                constraintEqualToConstant:
                    kFloatingButtonSize]
        ]];
}

- (UIView*)floatingButtonHostView {
    UIView* host =
        _floatingButton.superview;

    return host != nil
        ? host
        : self.view;
}

- (void)attachFloatingButtonToOverlayWindow:
    (UIWindow*)window {
    if (window == nil ||
        _floatingButton == nil) {
        return;
    }

    if (_floatingButton.superview != window) {
        if (_floatingButtonCenterXConstraint != nil ||
            _floatingButtonCenterYConstraint != nil) {
            [NSLayoutConstraint
                deactivateConstraints:@[
                    _floatingButtonCenterXConstraint,
                    _floatingButtonCenterYConstraint
                ]];
        }

        [_floatingButton
            removeFromSuperview];

        [window
            addSubview:_floatingButton];

        _floatingButtonCenterXConstraint =
            [[_floatingButton centerXAnchor]
                constraintEqualToAnchor:
                    window.leadingAnchor];

        _floatingButtonCenterYConstraint =
            [[_floatingButton centerYAnchor]
                constraintEqualToAnchor:
                    window.topAnchor];

        [NSLayoutConstraint
            activateConstraints:@[
                _floatingButtonCenterXConstraint,
                _floatingButtonCenterYConstraint
            ]];
    }

    if (!_floatingButtonPositionInitialized) {
        const UIEdgeInsets safeInsets =
            window.safeAreaInsets;

        const auto region =
            vcam::product::ui::
                MakeFloatingButtonSafeRegion(
                    {
                        window.bounds.size.width,
                        window.bounds.size.height,
                    },
                    {
                        safeInsets.top,
                        safeInsets.left,
                        safeInsets.bottom,
                        safeInsets.right,
                    },
                    {
                        kFloatingButtonSize,
                        kFloatingButtonSize,
                    },
                    kFloatingButtonEdgeMargin);

        _floatingButtonCenterXConstraint
            .constant = region.maxX;
        _floatingButtonCenterYConstraint
            .constant =
                (region.minY + region.maxY) *
                0.5;

        _floatingButtonPositionInitialized =
            YES;
    }

    [window
        bringSubviewToFront:_floatingButton];
    [window
        layoutIfNeeded];
}

- (void)raiseFloatingButtonAboveOverlayContent {
    UIWindow* window =
        [self floatingButtonHostView].window;

    if (window == nil &&
        [_floatingButton.superview
            isKindOfClass:[UIWindow class]]) {
        window =
            (UIWindow*)_floatingButton
                .superview;
    }

    if (window != nil) {
        [window
            bringSubviewToFront:
                _floatingButton];
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    if (_floatingButtonCenterXConstraint ==
            nil ||
        _floatingButtonCenterYConstraint ==
            nil) {
        return;
    }

    const CGPoint current =
        CGPointMake(
            _floatingButtonCenterXConstraint
                .constant,
            _floatingButtonCenterYConstraint
                .constant);

    const CGPoint bounded =
        [self
            clampedFloatingButtonCenter:
                current];

    _floatingButtonCenterXConstraint
        .constant = bounded.x;
    _floatingButtonCenterYConstraint
        .constant = bounded.y;

    [self
        raiseFloatingButtonAboveOverlayContent];
}

- (CGPoint)clampedFloatingButtonCenter:
    (CGPoint)point {
    UIView* host =
        [self floatingButtonHostView];

    const UIEdgeInsets safeInsets =
        host.safeAreaInsets;

    const auto bounded =
        vcam::product::ui::
            ClampFloatingButtonCenter(
                {
                    point.x,
                    point.y,
                },
                {
                    host.bounds.size.width,
                    host.bounds.size.height,
                },
                {
                    safeInsets.top,
                    safeInsets.left,
                    safeInsets.bottom,
                    safeInsets.right,
                },
                {
                    kFloatingButtonSize,
                    kFloatingButtonSize,
                },
                kFloatingButtonEdgeMargin);

    return CGPointMake(
        bounded.x,
        bounded.y);
}

- (CGPoint)movedFloatingButtonCenterByTranslation:
    (CGPoint)translation {
    UIView* host =
        [self floatingButtonHostView];

    const UIEdgeInsets safeInsets =
        host.safeAreaInsets;

    const auto moved =
        vcam::product::ui::
            MoveFloatingButtonByTranslation(
                {
                    _floatingButtonCenterXConstraint
                        .constant,
                    _floatingButtonCenterYConstraint
                        .constant,
                },
                {
                    translation.x,
                    translation.y,
                },
                {
                    host.bounds.size.width,
                    host.bounds.size.height,
                },
                {
                    safeInsets.top,
                    safeInsets.left,
                    safeInsets.bottom,
                    safeInsets.right,
                },
                {
                    kFloatingButtonSize,
                    kFloatingButtonSize,
                },
                kFloatingButtonEdgeMargin);

    return CGPointMake(
        moved.x,
        moved.y);
}

- (void)setFloatingButtonCenter:
    (CGPoint)center {
    _floatingButtonCenterXConstraint
        .constant = center.x;
    _floatingButtonCenterYConstraint
        .constant = center.y;

    [[self floatingButtonHostView]
        layoutIfNeeded];
}

- (void)handleFloatingButtonPan:
    (UIPanGestureRecognizer*)gesture {
    NSAssert(
        [NSThread isMainThread],
        @"VCAM floating control drag must remain on the main thread.");

    UIView* host =
        [self floatingButtonHostView];

    if (_floatingButtonCenterXConstraint ==
            nil ||
        _floatingButtonCenterYConstraint ==
            nil) {
        return;
    }

    switch (gesture.state) {
        case UIGestureRecognizerStateBegan: {
            const CGPoint current =
                CGPointMake(
                    _floatingButtonCenterXConstraint
                        .constant,
                    _floatingButtonCenterYConstraint
                        .constant);

            [self
                setFloatingButtonCenter:
                    [self
                        clampedFloatingButtonCenter:
                            current]];

            [gesture
                setTranslation:CGPointZero
                       inView:host];
            break;
        }

        case UIGestureRecognizerStateChanged:
        case UIGestureRecognizerStateEnded: {
            const CGPoint translation =
                [gesture
                    translationInView:host];

            [self
                setFloatingButtonCenter:
                    [self
                        movedFloatingButtonCenterByTranslation:
                            translation]];

            [gesture
                setTranslation:CGPointZero
                       inView:host];
            break;
        }

        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            const CGPoint current =
                CGPointMake(
                    _floatingButtonCenterXConstraint
                        .constant,
                    _floatingButtonCenterYConstraint
                        .constant);

            [self
                setFloatingButtonCenter:
                    [self
                        clampedFloatingButtonCenter:
                            current]];

            [gesture
                setTranslation:CGPointZero
                       inView:host];
            break;
        }

        default:
            break;
    }

    [self
        raiseFloatingButtonAboveOverlayContent];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self startProductOwnerInitializationIfNeeded];
}

- (void)startProductOwnerInitializationIfNeeded {
    NSAssert(
        [NSThread isMainThread],
        @"VCAM owner readiness must be managed on the main thread.");

    if (_ownerInitializationStarted ||
        _ownerReady) {
        return;
    }

    _ownerInitializationStarted = YES;

    __weak VCAMProductOverlayController*
        weakSelf = self;

    dispatch_async(
        ProductOwnerInitializationQueue(),
        ^{
            @autoreleasepool {
                auto owner =
                    std::make_shared<
                        vcam::product::
                            ProductControlOwner>();

                dispatch_async(
                    dispatch_get_main_queue(),
                    ^{
                        VCAMProductOverlayController*
                            strongSelf =
                                weakSelf;

                        if (strongSelf == nil) {
                            return;
                        }

                        strongSelf->_owner =
                            owner;
                        strongSelf->_ownerReady =
                            YES;
                        strongSelf
                            ->_floatingButton
                            .enabled = YES;
                    });
            }
        });
}

- (void)openControl {
    NSAssert(
        [NSThread isMainThread],
        @"VCAM control presentation must occur on the main thread.");

    if (!_ownerReady ||
        !_owner) {
        return;
    }

    auto owner = _owner;

    VCAMInternalGalleryViewController*
        control =
        [[VCAMInternalGalleryViewController alloc]
            initWithProductControlOwner:
                owner.get()];

    UINavigationController* navigation =
        [[UINavigationController alloc]
            initWithRootViewController:
                control];

    navigation.modalPresentationStyle =
        UIModalPresentationFormSheet;

    [self
        presentViewController:navigation
                     animated:YES
                   completion:^{
                       [self
                           raiseFloatingButtonAboveOverlayContent];
                   }];
}

@end

static VCAMProductOverlayWindow*
    gOverlayWindow = nil;

static dispatch_queue_t
ProductOwnerInitializationQueue() {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;

    dispatch_once(
        &onceToken,
        ^{
            queue =
                dispatch_queue_create(
                    "com.vcampro.product-owner-storage-init",
                    DISPATCH_QUEUE_SERIAL);
        });

    return queue;
}

namespace vcam::product {

void StartSpringBoardControlHost() {
    dispatch_async(
        dispatch_get_main_queue(),
        ^{
            if (gOverlayWindow != nil) {
                return;
            }

            VCAMProductOverlayController*
                root =
                [[VCAMProductOverlayController alloc]
                    init];

            VCAMProductOverlayWindow*
                window =
                [[VCAMProductOverlayWindow alloc]
                    initWithFrame:
                        UIScreen
                            .mainScreen
                            .bounds];

            window.rootViewController =
                root;
            window.windowLevel =
                UIWindowLevelAlert + 5.0;
            window.backgroundColor =
                [UIColor clearColor];
            [root loadViewIfNeeded];

            window.hidden = NO;

            [root
                attachFloatingButtonToOverlayWindow:
                    window];

            gOverlayWindow = window;
        });
}

}  // namespace vcam::product
