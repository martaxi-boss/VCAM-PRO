#include "ControlledPreviewHost.h"

#include "ControlledPreviewView.h"
#include "ControlledRuntime.h"

#import <UIKit/UIKit.h>

@interface VCAMControlledPreviewWindow : UIWindow
@end

@implementation VCAMControlledPreviewWindow

- (UIView*)hitTest:
    (CGPoint)point
         withEvent:(UIEvent*)event {
    (void)point;
    (void)event;
    return nil;
}

@end

@interface VCAMControlledPreviewController
    : UIViewController
@end

@implementation VCAMControlledPreviewController {
    vcam::controlled::ControlledRuntime
        _runtime;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor =
        [UIColor clearColor];

    (void)_runtime.start();

    VCAMControlledPreviewView* preview =
        [[VCAMControlledPreviewView alloc]
            initWithRuntime:
                &_runtime];

    preview.translatesAutoresizingMaskIntoConstraints =
        NO;

    [self.view addSubview:preview];

    [NSLayoutConstraint
        activateConstraints:@[
            [preview.widthAnchor
                constraintEqualToConstant:
                    240.0],
            [preview.heightAnchor
                constraintEqualToConstant:
                    135.0],
            [preview.leadingAnchor
                constraintEqualToAnchor:
                    self.view
                        .safeAreaLayoutGuide
                        .leadingAnchor
                constant:18.0],
            [preview.bottomAnchor
                constraintEqualToAnchor:
                    self.view
                        .safeAreaLayoutGuide
                        .bottomAnchor
                constant:-18.0]
        ]];
}

@end

static VCAMControlledPreviewWindow*
    gControlledPreviewWindow = nil;

namespace vcam::controlled {

void StartControlledPreviewHost() {
    dispatch_async(
        dispatch_get_main_queue(),
        ^{
            if (gControlledPreviewWindow !=
                nil) {
                return;
            }

            VCAMControlledPreviewController*
                root =
                [[VCAMControlledPreviewController
                    alloc]
                    init];

            VCAMControlledPreviewWindow*
                window =
                [[VCAMControlledPreviewWindow
                    alloc]
                    initWithFrame:
                        UIScreen
                            .mainScreen
                            .bounds];

            window.rootViewController =
                root;
            window.windowLevel =
                UIWindowLevelAlert + 4.0;
            window.backgroundColor =
                [UIColor clearColor];
            window.userInteractionEnabled =
                NO;
            window.hidden = NO;

            gControlledPreviewWindow =
                window;
        });
}

}  // namespace vcam::controlled
