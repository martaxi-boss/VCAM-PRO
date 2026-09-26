#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#include <cstring>
#include <unistd.h>

namespace {

NSString* const kProbeVersion = @"0.1.0~probe3";
NSString* const kProofDirectory =
    @"/var/mobile/Library/VCAMProRootHideProbe";
NSString* const kProofPath =
    @"/var/mobile/Library/VCAMProRootHideProbe/load-proof.txt";

constexpr NSInteger kMaxPresentationAttempts = 60;
constexpr int64_t kRetryIntervalNanoseconds =
    NSEC_PER_SEC;
constexpr int64_t kVisibleDurationNanoseconds =
    60 * NSEC_PER_SEC;
constexpr int64_t kAlertDurationNanoseconds =
    15 * NSEC_PER_SEC;

UIView* gProbeBanner = nil;
UIAlertController* gProbeAlert = nil;
NSInteger gPresentationAttempts = 0;
bool gBannerPresented = false;
bool gFallbackPresented = false;
bool gAlertPresentationInFlight = false;

bool IsSpringBoard() noexcept {
    const char* process = getprogname();
    return process != nullptr &&
           std::strcmp(process, "SpringBoard") == 0;
}

NSString* ProcessIdentity() {
    const char* process = getprogname();
    if (process == nullptr) {
        return @"unknown";
    }

    NSString* value =
        [NSString stringWithUTF8String:process];
    return value != nil
        ? value
        : @"unknown";
}

void WritePersistentLoadProof() {
    NSFileManager* manager =
        [NSFileManager defaultManager];

    NSError* directoryError = nil;
    if (![manager
            createDirectoryAtPath:kProofDirectory
      withIntermediateDirectories:YES
                       attributes:nil
                            error:&directoryError]) {
        NSLog(
            @"[VCAM ROOT HIDE PROBE] unable to create proof directory: %@",
            directoryError);
        return;
    }

    NSISO8601DateFormatter* formatter =
        [[NSISO8601DateFormatter alloc] init];
    NSString* timestamp =
        [formatter stringFromDate:[NSDate date]];

    NSString* contents =
        [NSString
            stringWithFormat:
                @"VCAM ROOT HIDE PROBE\n"
                 "version=%@\n"
                 "timestamp=%@\n"
                 "process=%@\n"
                 "pid=%d\n"
                 "constructor=PASS\n",
                kProbeVersion,
                (timestamp != nil
                    ? timestamp
                    : @"unknown"),
                ProcessIdentity(),
                static_cast<int>(getpid())];

    NSError* writeError = nil;
    if (![contents
            writeToFile:kProofPath
             atomically:YES
               encoding:NSUTF8StringEncoding
                  error:&writeError]) {
        NSLog(
            @"[VCAM ROOT HIDE PROBE] unable to write proof marker: %@",
            writeError);
        return;
    }

    NSLog(
        @"[VCAM ROOT HIDE PROBE] persistent constructor proof written: %@",
        kProofPath);
}

bool WindowIsUsable(
    UIWindow* window) {
    return
        window != nil &&
        !window.hidden &&
        window.alpha > 0.01 &&
        window.rootViewController != nil &&
        CGRectGetWidth(window.bounds) > 1.0 &&
        CGRectGetHeight(window.bounds) > 1.0;
}

UIWindow* FindExistingSpringBoardWindow() {
    UIApplication* application =
        UIApplication.sharedApplication;

    UIWindow* fallback = nil;

    for (UIScene* scene in
         application.connectedScenes) {
        if (![scene
                isKindOfClass:
                    [UIWindowScene class]]) {
            continue;
        }

        if (scene.activationState !=
                UISceneActivationStateForegroundActive &&
            scene.activationState !=
                UISceneActivationStateForegroundInactive) {
            continue;
        }

        UIWindowScene* windowScene =
            static_cast<UIWindowScene*>(scene);

        for (UIWindow* window in
             windowScene.windows) {
            if (!WindowIsUsable(window)) {
                continue;
            }

            if (window.isKeyWindow) {
                return window;
            }

            if (fallback == nil ||
                window.windowLevel <
                    fallback.windowLevel) {
                fallback = window;
            }
        }
    }

    if (fallback != nil) {
        return fallback;
    }

    id<UIApplicationDelegate> delegate =
        application.delegate;

    if (delegate != nil &&
        [delegate
            respondsToSelector:
                @selector(window)]) {
        UIWindow* delegateWindow =
            delegate.window;

        if (WindowIsUsable(
                delegateWindow)) {
            return delegateWindow;
        }
    }

    return nil;
}

UIViewController* TopViewController(
    UIViewController* controller) {
    UIViewController* current =
        controller;

    for (NSInteger depth = 0;
         current != nil && depth < 16;
         ++depth) {
        UIViewController* presented =
            current.presentedViewController;

        if (presented != nil &&
            !presented.isBeingDismissed) {
            current = presented;
            continue;
        }

        if ([current
                isKindOfClass:
                    [UINavigationController
                        class]]) {
            UIViewController* visible =
                static_cast<
                    UINavigationController*>(
                        current)
                    .visibleViewController;
            if (visible != nil &&
                visible != current) {
                current = visible;
                continue;
            }
        }

        if ([current
                isKindOfClass:
                    [UITabBarController class]]) {
            UIViewController* selected =
                static_cast<
                    UITabBarController*>(
                        current)
                    .selectedViewController;
            if (selected != nil &&
                selected != current) {
                current = selected;
                continue;
            }
        }

        if ([current
                isKindOfClass:
                    [UISplitViewController
                        class]]) {
            NSArray<UIViewController*>*
                children =
                    static_cast<
                        UISplitViewController*>(
                            current)
                        .viewControllers;

            UIViewController* last =
                children.lastObject;
            if (last != nil &&
                last != current) {
                current = last;
                continue;
            }
        }

        break;
    }

    return current;
}

void AttachVisibleBanner(
    UIWindow* window) {
    if (gBannerPresented ||
        !WindowIsUsable(window)) {
        return;
    }

    const CGRect bounds =
        window.bounds;
    const CGFloat horizontalInset = 12.0;
    const CGFloat bannerHeight = 88.0;
    const CGFloat width =
        MAX(
            1.0,
            CGRectGetWidth(bounds) -
                (horizontalInset * 2.0));
    const CGFloat top =
        MAX(
            window.safeAreaInsets.top +
                8.0,
            36.0);

    UIView* banner =
        [[UIView alloc]
            initWithFrame:
                CGRectMake(
                    horizontalInset,
                    top,
                    width,
                    bannerHeight)];

    banner.backgroundColor =
        [UIColor
            colorWithRed:0.56
                   green:0.0
                    blue:0.68
                   alpha:0.98];
    banner.userInteractionEnabled = NO;
    banner.autoresizingMask =
        UIViewAutoresizingFlexibleWidth |
        UIViewAutoresizingFlexibleBottomMargin;

    UILabel* label =
        [[UILabel alloc]
            initWithFrame:
                CGRectInset(
                    banner.bounds,
                    8.0,
                    8.0)];
    label.autoresizingMask =
        UIViewAutoresizingFlexibleWidth |
        UIViewAutoresizingFlexibleHeight;
    label.backgroundColor =
        UIColor.clearColor;
    label.textColor =
        UIColor.whiteColor;
    label.textAlignment =
        NSTextAlignmentCenter;
    label.font =
        [UIFont boldSystemFontOfSize:16.0];
    label.numberOfLines = 3;
    label.text =
        [NSString
            stringWithFormat:
                @"VCAM ROOT HIDE PROBE\n"
                 "SPRINGBOARD CONSTRUCTOR PASS\n"
                 "%@",
                kProbeVersion];
    label.accessibilityLabel =
        @"VCAM ROOT HIDE PROBE "
         "SPRINGBOARD CONSTRUCTOR PASS";

    [banner addSubview:label];
    [window addSubview:banner];
    [window bringSubviewToFront:banner];

    gProbeBanner = banner;
    gBannerPresented = true;

    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            kVisibleDurationNanoseconds),
        dispatch_get_main_queue(),
        ^{
            [gProbeBanner
                removeFromSuperview];
            gProbeBanner = nil;
        });
}

void PresentControllerFallback(
    UIWindow* window) {
    if (gFallbackPresented ||
        gAlertPresentationInFlight ||
        !WindowIsUsable(window)) {
        return;
    }

    UIViewController* presenter =
        TopViewController(
            window.rootViewController);

    if (presenter == nil ||
        presenter.view.window == nil ||
        presenter.isBeingDismissed) {
        return;
    }

    UIAlertController* alert =
        [UIAlertController
            alertControllerWithTitle:
                @"VCAM ROOT HIDE PROBE"
            message:
                [NSString
                    stringWithFormat:
                        @"SPRINGBOARD CONSTRUCTOR PASS\n%@",
                        kProbeVersion]
            preferredStyle:
                UIAlertControllerStyleAlert];

    [alert
        addAction:
            [UIAlertAction
                actionWithTitle:@"OK"
                style:
                    UIAlertActionStyleDefault
                handler:^(
                    UIAlertAction* action) {
                    (void)action;
                    gProbeAlert = nil;
                }]];

    gProbeAlert = alert;
    gAlertPresentationInFlight = true;

    [presenter
        presentViewController:alert
                     animated:YES
                   completion:^{
                       gAlertPresentationInFlight =
                           false;
                       gFallbackPresented = true;

                       dispatch_after(
                           dispatch_time(
                               DISPATCH_TIME_NOW,
                               kAlertDurationNanoseconds),
                           dispatch_get_main_queue(),
                           ^{
                               UIAlertController*
                                   current =
                                       gProbeAlert;

                               if (current != nil &&
                                   current
                                       .presentingViewController !=
                                           nil) {
                                   [current
                                       dismissViewControllerAnimated:YES
                                                          completion:nil];
                               }

                               gProbeAlert = nil;
                           });
                   }];

    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            2 * NSEC_PER_SEC),
        dispatch_get_main_queue(),
        ^{
            if (!gFallbackPresented &&
                gProbeAlert != nil &&
                gProbeAlert
                    .presentingViewController ==
                        nil) {
                gProbeAlert = nil;
                gAlertPresentationInFlight =
                    false;
            }
        });
}

void AttemptVisibleProof();

void ScheduleVisibleRetry() {
    if (gPresentationAttempts >=
        kMaxPresentationAttempts) {
        return;
    }

    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            kRetryIntervalNanoseconds),
        dispatch_get_main_queue(),
        ^{
            AttemptVisibleProof();
        });
}

void AttemptVisibleProof() {
    if (!IsSpringBoard()) {
        return;
    }

    ++gPresentationAttempts;

    UIWindow* window =
        FindExistingSpringBoardWindow();

    if (window != nil) {
        AttachVisibleBanner(window);
        PresentControllerFallback(window);
    }

    if (gBannerPresented &&
        gFallbackPresented) {
        return;
    }

    ScheduleVisibleRetry();
}

void ScheduleVisibleLoadProof() {
    dispatch_async(
        dispatch_get_main_queue(),
        ^{
            AttemptVisibleProof();
        });
}

}  // namespace

__attribute__((constructor))
static void VCAMRootHideProbeInitialize() {
    @autoreleasepool {
        if (!IsSpringBoard()) {
            return;
        }

        WritePersistentLoadProof();
        ScheduleVisibleLoadProof();
    }
}
