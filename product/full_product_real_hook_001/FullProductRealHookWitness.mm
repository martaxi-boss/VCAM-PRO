#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#include "FullProductRealHookProofState.h"

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
UIView* gRealHookBanner = nil;

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
        vcam_full_product_real_hook_state_pid(state);

    const CGRect bounds = window.bounds;
    const CGFloat horizontalInset = 12.0;
    const CGFloat bannerHeight = 224.0;
    const CGFloat width =
        MAX(1.0, bounds.size.width - (horizontalInset * 2.0));
    const CGFloat top =
        MAX(window.safeAreaInsets.top + 8.0, 36.0);

    UIView* banner =
        [[UIView alloc] initWithFrame:
            CGRectMake(horizontalInset, top, width, bannerHeight)];
    banner.backgroundColor =
        [UIColor colorWithRed:0.56 green:0.0 blue:0.68 alpha:0.98];
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
    label.font = [UIFont boldSystemFontOfSize:12.5];
    label.numberOfLines = 8;
    label.text =
        [NSString stringWithFormat:
            @"VCAM REAL HOOK INSTALL PASS\n"
             "runtime.start=PASS\n"
             "real-reference-hook-install=PASS\n"
             "original-trampoline=NON_NULL\n"
             "callback=NOT_EXERCISED\n"
             "frame-substitution=INACTIVE\n"
             "pid=%u\n"
             "gate/version=%s",
            pid,
            VCAM_FULL_PRODUCT_REAL_HOOK_VERSION];

    label.accessibilityLabel =
        @"VCAM REAL HOOK INSTALL PASS "
         "runtime start PASS "
         "real reference hook install PASS "
         "original trampoline NON NULL "
         "callback NOT EXERCISED "
         "frame substitution INACTIVE";

    [banner addSubview:label];
    [window addSubview:banner];
    [window bringSubviewToFront:banner];

    gRealHookBanner = banner;
    gBannerPresented = true;

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,
                      kVisibleDurationNanoseconds),
        dispatch_get_main_queue(),
        ^{
            [gRealHookBanner removeFromSuperview];
            gRealHookBanner = nil;
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

    if (!vcam_full_product_real_hook_state_is_valid_fresh(
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
            VCAM_FULL_PRODUCT_REAL_HOOK_NOTIFICATION,
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
static void VCAMProFullProductRealHookWitnessInitialize() {
    @autoreleasepool {
        if (!IsSpringBoard()) {
            return;
        }

        RegisterWitness();
    }
}
