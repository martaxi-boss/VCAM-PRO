#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#include <cstring>
#include <unistd.h>

namespace {

UIWindow* gProbeWindow = nil;

bool IsSpringBoard() noexcept {
    const char* process = getprogname();
    return process != nullptr &&
           std::strcmp(process, "SpringBoard") == 0;
}

void ShowProbeMarker() {
    if (gProbeWindow != nil) {
        return;
    }

    const CGRect screenBounds = UIScreen.mainScreen.bounds;
    const CGFloat horizontalInset = 16.0;
    const CGFloat height = 44.0;
    const CGFloat width =
        MIN(screenBounds.size.width - (horizontalInset * 2.0), 340.0);
    const CGFloat x = (screenBounds.size.width - width) / 2.0;
    const CGFloat y = 54.0;

    UIWindow* window =
        [[UIWindow alloc] initWithFrame:CGRectMake(x, y, width, height)];
    window.windowLevel = UIWindowLevelAlert + 1000.0;
    window.backgroundColor = UIColor.clearColor;
    window.userInteractionEnabled = NO;

    UIViewController* controller = [[UIViewController alloc] init];
    controller.view.backgroundColor = UIColor.clearColor;

    UILabel* label =
        [[UILabel alloc] initWithFrame:CGRectMake(0.0, 0.0, width, height)];
    label.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    label.backgroundColor =
        [UIColor colorWithWhite:0.08 alpha:0.92];
    label.textColor = UIColor.whiteColor;
    label.textAlignment = NSTextAlignmentCenter;
    label.font = [UIFont boldSystemFontOfSize:14.0];
    label.text = @"VCAM ROOT HIDE PROBE";
    label.accessibilityLabel = @"VCAM ROOT HIDE PROBE";

    [controller.view addSubview:label];
    window.rootViewController = controller;
    window.hidden = NO;
    gProbeWindow = window;

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC),
        dispatch_get_main_queue(),
        ^{
            gProbeWindow.hidden = YES;
            gProbeWindow = nil;
        });
}

}  // namespace

__attribute__((constructor))
static void VCAMRootHideProbeInitialize() {
    @autoreleasepool {
        if (!IsSpringBoard()) {
            return;
        }

        dispatch_async(
            dispatch_get_main_queue(),
            ^{
                ShowProbeMarker();
            });
    }
}
