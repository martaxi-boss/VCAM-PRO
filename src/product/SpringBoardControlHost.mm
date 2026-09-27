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
    CGPoint _floatingButtonDragStartCenter;
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

    [self.view
        addSubview:_floatingButton];

    _floatingButtonCenterXConstraint =
        [[_floatingButton centerXAnchor]
            constraintEqualToAnchor:
                self.view.leadingAnchor];

    _floatingButtonCenterYConstraint =
        [[_floatingButton centerYAnchor]
            constraintEqualToAnchor:
                self.view.topAnchor];

    [NSLayoutConstraint
        activateConstraints:@[
            [[_floatingButton
                widthAnchor]
                constraintEqualToConstant:
                    kFloatingButtonSize],
            [[_floatingButton
                heightAnchor]
                constraintEqualToConstant:
                    kFloatingButtonSize],
            _floatingButtonCenterXConstraint,
            _floatingButtonCenterYConstraint
        ]];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    CGPoint desired;

    if (!_floatingButtonPositionInitialized) {
        const UIEdgeInsets safeInsets =
            self.view.safeAreaInsets;

        const auto region =
            vcam::product::ui::
                MakeFloatingButtonSafeRegion(
                    {
                        self.view.bounds.size.width,
                        self.view.bounds.size.height,
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

        desired = CGPointMake(
            region.maxX,
            (region.minY + region.maxY) * 0.5);

        _floatingButtonPositionInitialized =
            YES;
    } else {
        desired = CGPointMake(
            _floatingButtonCenterXConstraint
                .constant,
            _floatingButtonCenterYConstraint
                .constant);
    }

    const CGPoint bounded =
        [self
            clampedFloatingButtonCenter:
                desired];

    _floatingButtonCenterXConstraint
        .constant = bounded.x;
    _floatingButtonCenterYConstraint
        .constant = bounded.y;
}

- (CGPoint)clampedFloatingButtonCenter:
    (CGPoint)point {
    const UIEdgeInsets safeInsets =
        self.view.safeAreaInsets;

    const auto bounded =
        vcam::product::ui::
            ClampFloatingButtonCenter(
                {
                    point.x,
                    point.y,
                },
                {
                    self.view.bounds.size.width,
                    self.view.bounds.size.height,
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

- (CGPoint)snappedFloatingButtonCenter:
    (CGPoint)point {
    const UIEdgeInsets safeInsets =
        self.view.safeAreaInsets;

    const auto snapped =
        vcam::product::ui::
            SnapFloatingButtonCenterToNearestEdge(
                {
                    point.x,
                    point.y,
                },
                {
                    self.view.bounds.size.width,
                    self.view.bounds.size.height,
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
        snapped.x,
        snapped.y);
}

- (void)setFloatingButtonCenter:
    (CGPoint)center
                     animated:
    (BOOL)animated {
    if (!animated) {
        _floatingButtonCenterXConstraint
            .constant = center.x;
        _floatingButtonCenterYConstraint
            .constant = center.y;
        [self.view layoutIfNeeded];
        return;
    }

    [self.view layoutIfNeeded];

    [UIView
        animateWithDuration:0.2
                 animations:^{
                     self
                         ->_floatingButtonCenterXConstraint
                         .constant = center.x;
                     self
                         ->_floatingButtonCenterYConstraint
                         .constant = center.y;
                     [self.view
                         layoutIfNeeded];
                 }];
}

- (void)handleFloatingButtonPan:
    (UIPanGestureRecognizer*)gesture {
    NSAssert(
        [NSThread isMainThread],
        @"VCAM floating control drag must remain on the main thread.");

    switch (gesture.state) {
        case UIGestureRecognizerStateBegan: {
            [self.view layoutIfNeeded];

            _floatingButtonDragStartCenter =
                CGPointMake(
                    _floatingButtonCenterXConstraint
                        .constant,
                    _floatingButtonCenterYConstraint
                        .constant);

            [gesture
                setTranslation:CGPointZero
                       inView:self.view];
            break;
        }

        case UIGestureRecognizerStateChanged: {
            const CGPoint translation =
                [gesture
                    translationInView:
                        self.view];

            const CGPoint desired =
                CGPointMake(
                    _floatingButtonDragStartCenter.x +
                        translation.x,
                    _floatingButtonDragStartCenter.y +
                        translation.y);

            [self
                setFloatingButtonCenter:
                    [self
                        clampedFloatingButtonCenter:
                            desired]
                                 animated:NO];
            break;
        }

        case UIGestureRecognizerStateEnded: {
            const CGPoint translation =
                [gesture
                    translationInView:
                        self.view];

            const CGPoint desired =
                CGPointMake(
                    _floatingButtonDragStartCenter.x +
                        translation.x,
                    _floatingButtonDragStartCenter.y +
                        translation.y);

            const CGPoint snapped =
                [self
                    snappedFloatingButtonCenter:
                        desired];

            [self
                setFloatingButtonCenter:
                    snapped
                                 animated:YES];
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
                            current]
                                 animated:NO];
            break;
        }

        default:
            break;
    }
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
                   completion:nil];
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
            window.hidden = NO;

            gOverlayWindow = window;
        });
}

}  // namespace vcam::product
