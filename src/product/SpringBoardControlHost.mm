#include "SpringBoardControlHost.h"

#include "InternalGalleryViewController.h"
#include "ProductControlOwner.h"

#import <UIKit/UIKit.h>

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
    vcam::product::ProductControlOwner _owner;
    UIButton* _floatingButton;
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
        28.0;
    _floatingButton.translatesAutoresizingMaskIntoConstraints =
        NO;

    [_floatingButton
        addTarget:self
           action:@selector(openControl)
 forControlEvents:
     UIControlEventTouchUpInside];

    [self.view
        addSubview:_floatingButton];

    [NSLayoutConstraint
        activateConstraints:@[
            [_floatingButton
                widthAnchor
                constraintEqualToConstant:
                    56.0],
            [_floatingButton
                heightAnchor
                constraintEqualToConstant:
                    56.0],
            [_floatingButton
                trailingAnchor
                constraintEqualToAnchor:
                    self.view
                        .safeAreaLayoutGuide
                        .trailingAnchor
                constant:-18.0],
            [_floatingButton
                centerYAnchor
                constraintEqualToAnchor:
                    self.view.centerYAnchor]
        ]];
}

- (void)openControl {
    VCAMInternalGalleryViewController*
        control =
        [[VCAMInternalGalleryViewController alloc]
            initWithProductControlOwner:
                &_owner];

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
