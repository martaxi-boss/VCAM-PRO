#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#include "LocalPhotoPipelineReadyProofState.h"

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
UIView* gPhotoReadyBanner = nil;

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
        vcam_local_photo_pipeline_ready_state_pid(state);

    const CGRect bounds = window.bounds;
    const CGFloat horizontalInset = 12.0;
    const CGFloat bannerHeight = 278.0;
    const CGFloat width =
        MAX(1.0, bounds.size.width - (horizontalInset * 2.0));
    const CGFloat top =
        MAX(window.safeAreaInsets.top + 8.0, 36.0);

    UIView* banner =
        [[UIView alloc] initWithFrame:
            CGRectMake(horizontalInset, top, width, bannerHeight)];
    banner.backgroundColor =
        [UIColor colorWithRed:0.16 green:0.18 blue:0.21 alpha:0.98];
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
    label.font = [UIFont boldSystemFontOfSize:11.5];
    label.numberOfLines = 14;
    label.text =
        [NSString stringWithFormat:
            @"VCAM LOCAL PHOTO PIPELINE READY PASS\n"
             "vcam-enabled=NO\n"
             "media-kind=PHOTO\n"
             "media-staged=YES\n"
             "control-state-observed=YES\n"
             "camera-geometry-observed=YES\n"
             "producer-ready=YES\n"
             "ready-frame-count=>0\n"
             "camera-callback=EXERCISED\n"
             "decision=ORIGINAL\n"
             "original-buffer-returned=YES\n"
             "frame-substitution=INACTIVE\n"
             "virtual-decision-count=0\n"
             "pid=%u",
            pid];

    label.accessibilityLabel =
        @"VCAM LOCAL PHOTO PIPELINE READY PASS "
         "vcam enabled NO "
         "media kind PHOTO "
         "media staged YES "
         "control state observed YES "
         "camera geometry observed YES "
         "producer ready YES "
         "ready frame count greater than zero "
         "camera callback EXERCISED "
         "decision ORIGINAL "
         "original buffer returned YES "
         "frame substitution INACTIVE "
         "virtual decision count zero";

    [banner addSubview:label];
    [window addSubview:banner];
    [window bringSubviewToFront:banner];

    gPhotoReadyBanner = banner;
    gBannerPresented = true;

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,
                      kVisibleDurationNanoseconds),
        dispatch_get_main_queue(),
        ^{
            [gPhotoReadyBanner removeFromSuperview];
            gPhotoReadyBanner = nil;
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

    if (!vcam_local_photo_pipeline_ready_state_is_valid_fresh(
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
            VCAM_LOCAL_PHOTO_PIPELINE_READY_NOTIFICATION,
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
static void VCAMProLocalPhotoPipelineReadyWitnessInitialize() {
    @autoreleasepool {
        if (!IsSpringBoard()) {
            return;
        }

        RegisterWitness();
    }
}
