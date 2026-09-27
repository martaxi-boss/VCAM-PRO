#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#include "RealCameraCallbackPassThroughProofState.h"

#include <dispatch/dispatch.h>
#include <notify.h>

#include <stdint.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

namespace {

constexpr NSInteger kMaxPresentationAttempts = 60;
constexpr int64_t kRetryIntervalNanoseconds = NSEC_PER_SEC;
constexpr int64_t kVisibleDurationNanoseconds = 60 * NSEC_PER_SEC;

uint64_t gAcceptedState = 0;
bool gAcceptedProof = false;
bool gBannerPresented = false;
NSInteger gPresentationAttempts = 0;
UIView* gCallbackBanner = nil;

bool IsSpringBoard() noexcept {
    const char* process = getprogname();
    return process != nullptr &&
           strcmp(process, "SpringBoard") == 0;
}

bool WindowIsUsable(UIWindow* window) {
    return window != nil &&
           !window.hidden &&
           window.alpha > 0.01 &&
           window.rootViewController != nil &&
           window.bounds.size.width > 1.0 &&
           window.bounds.size.height > 1.0;
}

UIWindow* FindExistingSpringBoardWindow() {
    UIApplication* application = UIApplication.sharedApplication;
    UIWindow* fallback = nil;

    for (UIScene* scene in application.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        if (scene.activationState != UISceneActivationStateForegroundActive &&
            scene.activationState != UISceneActivationStateForegroundInactive) {
            continue;
        }

        UIWindowScene* windowScene = static_cast<UIWindowScene*>(scene);
        for (UIWindow* window in windowScene.windows) {
            if (!WindowIsUsable(window)) {
                continue;
            }
            if (window.isKeyWindow) {
                return window;
            }
            if (fallback == nil ||
                window.windowLevel < fallback.windowLevel) {
                fallback = window;
            }
        }
    }

    if (fallback != nil) {
        return fallback;
    }

    id<UIApplicationDelegate> delegate = application.delegate;
    if (delegate != nil &&
        [delegate respondsToSelector:@selector(window)]) {
        UIWindow* delegateWindow = delegate.window;
        if (WindowIsUsable(delegateWindow)) {
            return delegateWindow;
        }
    }

    return nil;
}

void AttachVisibleProof(UIWindow* window, uint64_t state) {
    if (gBannerPresented || !WindowIsUsable(window)) {
        return;
    }

    const uint32_t pid =
        vcam_real_camera_callback_passthrough_state_pid(state);

    const CGRect bounds = window.bounds;
    const CGFloat horizontalInset = 12.0;
    const CGFloat bannerHeight = 232.0;
    const CGFloat width =
        MAX(1.0, bounds.size.width - (horizontalInset * 2.0));
    const CGFloat top =
        MAX(window.safeAreaInsets.top + 8.0, 36.0);

    UIView* banner =
        [[UIView alloc] initWithFrame:
            CGRectMake(horizontalInset, top, width, bannerHeight)];
    banner.backgroundColor =
        [UIColor colorWithRed:0.08 green:0.36 blue:0.22 alpha:0.98];
    banner.userInteractionEnabled = NO;
    banner.autoresizingMask =
        UIViewAutoresizingFlexibleWidth |
        UIViewAutoresizingFlexibleBottomMargin;

    UILabel* label =
        [[UILabel alloc] initWithFrame:
            CGRectInset(banner.bounds, 8.0, 8.0)];
    label.autoresizingMask =
        UIViewAutoresizingFlexibleWidth |
        UIViewAutoresizingFlexibleHeight;
    label.backgroundColor = UIColor.clearColor;
    label.textColor = UIColor.whiteColor;
    label.textAlignment = NSTextAlignmentCenter;
    label.font = [UIFont boldSystemFontOfSize:12.0];
    label.numberOfLines = 9;
    label.text =
        [NSString stringWithFormat:
            @"VCAM REAL CAMERA CALLBACK PASS\n"
             "callback=EXERCISED\n"
             "vcam-enabled=NO\n"
             "media-selected=NO\n"
             "decision=ORIGINAL\n"
             "original-buffer-returned=YES\n"
             "frame-substitution=INACTIVE\n"
             "virtual-decision-count=0\n"
             "pid=%u",
            pid];

    label.accessibilityLabel =
        @"VCAM REAL CAMERA CALLBACK PASS "
         "callback EXERCISED "
         "vcam enabled NO "
         "media selected NO "
         "decision ORIGINAL "
         "original buffer returned YES "
         "frame substitution INACTIVE "
         "virtual decision count zero";

    [banner addSubview:label];
    [window addSubview:banner];
    [window bringSubviewToFront:banner];

    gCallbackBanner = banner;
    gBannerPresented = true;

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,
                      kVisibleDurationNanoseconds),
        dispatch_get_main_queue(),
        ^{
            [gCallbackBanner removeFromSuperview];
            gCallbackBanner = nil;
        });
}

void AttemptVisibleProof();

void ScheduleVisibleRetry() {
    if (gPresentationAttempts >= kMaxPresentationAttempts ||
        gBannerPresented ||
        !gAcceptedProof) {
        return;
    }

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,
                      kRetryIntervalNanoseconds),
        dispatch_get_main_queue(),
        ^{
            AttemptVisibleProof();
        });
}

void AttemptVisibleProof() {
    if (!IsSpringBoard() ||
        !gAcceptedProof ||
        gAcceptedState == 0) {
        return;
    }

    ++gPresentationAttempts;

    UIWindow* window = FindExistingSpringBoardWindow();
    if (window != nil) {
        AttachVisibleProof(window, gAcceptedState);
    }

    if (!gBannerPresented) {
        ScheduleVisibleRetry();
    }
}

void AcceptFreshState(uint64_t state) {
    if (gAcceptedProof) {
        return;
    }

    gAcceptedState = state;
    gAcceptedProof = true;
    AttemptVisibleProof();
}

void ValidateTokenState(int token) {
    uint64_t state = 0;
    if (notify_get_state(token, &state) != NOTIFY_STATUS_OK) {
        return;
    }

    const time_t nowValue = time(nullptr);
    if (nowValue < 0 ||
        static_cast<uint64_t>(nowValue) > UINT32_MAX) {
        return;
    }

    if (!vcam_real_camera_callback_passthrough_state_is_valid_fresh(
            state,
            static_cast<uint32_t>(nowValue))) {
        return;
    }

    dispatch_async(
        dispatch_get_main_queue(),
        ^{
            AcceptFreshState(state);
        });
}

void RegisterWitness() {
    if (!IsSpringBoard()) {
        return;
    }

    int token = 0;
    const uint32_t status =
        notify_register_dispatch(
            VCAM_REAL_CAMERA_CALLBACK_PASSTHROUGH_NOTIFICATION,
            &token,
            dispatch_get_main_queue(),
            ^(int incomingToken) {
                ValidateTokenState(incomingToken);
            });

    if (status != NOTIFY_STATUS_OK) {
        return;
    }

    ValidateTokenState(token);
}

}  // namespace

__attribute__((constructor))
static void VCAMProRealCameraCallbackPassThroughWitnessInitialize() {
    @autoreleasepool {
        if (!IsSpringBoard()) {
            return;
        }

        RegisterWitness();
    }
}
