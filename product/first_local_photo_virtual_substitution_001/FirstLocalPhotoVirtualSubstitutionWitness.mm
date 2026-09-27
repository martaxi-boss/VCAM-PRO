#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#include "FirstLocalPhotoVirtualSubstitutionProofState.h"

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

int gSelectionToken = -1;
bool gAcceptedProof = false;
bool gBannerPresented = false;
NSInteger gPresentationAttempts = 0;
UIView* gSubstitutionBanner = nil;
NSString* gAcceptedText = nil;

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

void AttachVisibleProof(UIWindow* window) {
    if (gBannerPresented ||
        !WindowIsUsable(window) ||
        gAcceptedText == nil) {
        return;
    }

    const CGRect bounds = window.bounds;
    const CGFloat horizontalInset = 10.0;
    const CGFloat top =
        MAX(window.safeAreaInsets.top + 8.0, 34.0);
    const CGFloat width =
        MAX(1.0, bounds.size.width - (horizontalInset * 2.0));
    const CGFloat height =
        MIN(360.0, MAX(220.0, bounds.size.height - top - 16.0));

    UIView* banner =
        [[UIView alloc] initWithFrame:
            CGRectMake(horizontalInset, top, width, height)];
    banner.backgroundColor =
        [UIColor colorWithRed:0.08 green:0.32 blue:0.17 alpha:0.98];
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
    label.font =
        [UIFont monospacedSystemFontOfSize:10.5
                                   weight:UIFontWeightSemibold];
    label.numberOfLines = 0;
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.78;
    label.text = gAcceptedText;
    label.accessibilityLabel = gAcceptedText;

    [banner addSubview:label];
    [window addSubview:banner];
    [window bringSubviewToFront:banner];

    gSubstitutionBanner = banner;
    gBannerPresented = true;

    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            kVisibleDurationNanoseconds),
        dispatch_get_main_queue(),
        ^{
            [gSubstitutionBanner removeFromSuperview];
            gSubstitutionBanner = nil;
        });
}

void AttemptVisibleProof();

void ScheduleRetry() {
    if (gPresentationAttempts >= kMaxPresentationAttempts ||
        gBannerPresented ||
        !gAcceptedProof) {
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
    if (!IsSpringBoard() ||
        !gAcceptedProof ||
        gAcceptedText == nil) {
        return;
    }

    ++gPresentationAttempts;

    UIWindow* window = FindExistingSpringBoardWindow();
    if (window != nil) {
        AttachVisibleProof(window);
    }

    if (!gBannerPresented) {
        ScheduleRetry();
    }
}

void ValidateProof(int proofToken) {
    uint64_t state = 0;
    uint64_t selectionGeneration = 0;

    if (notify_get_state(
            proofToken,
            &state) != NOTIFY_STATUS_OK ||
        gSelectionToken < 0 ||
        notify_get_state(
            gSelectionToken,
            &selectionGeneration) !=
            NOTIFY_STATUS_OK) {
        return;
    }

    const time_t nowValue = time(nullptr);
    if (nowValue < 0 ||
        static_cast<uint64_t>(nowValue) > UINT32_MAX ||
        !vcam_first_photo_substitution_state_is_valid_fresh(
            state,
            selectionGeneration,
            static_cast<uint32_t>(nowValue))) {
        return;
    }

    const uint32_t pid =
        vcam_first_photo_substitution_state_pid(state);

    NSString* text =
        [NSString stringWithFormat:
            @"VCAM LOCAL PHOTO VIRTUAL SUBSTITUTION PASS\n"
             "vcam-enabled=YES\n"
             "media-kind=PHOTO\n"
             "media-ready=YES\n"
             "camera-geometry-observed=YES\n"
             "camera-callback=EXERCISED\n"
             "decision=VIRTUAL\n"
             "virtual-buffer-non-null=YES\n"
             "virtual-buffer-different-from-original=YES\n"
             "geometry-match=YES\n"
             "virtual-decision-count=>0\n"
             "frame-substitution=ACTIVE\n"
             "selection-generation=%llu\n"
             "pid=%u",
            static_cast<unsigned long long>(
                selectionGeneration),
            pid];

    dispatch_async(
        dispatch_get_main_queue(),
        ^{
            if (gAcceptedProof) {
                return;
            }

            gAcceptedText = text;
            gAcceptedProof = true;
            AttemptVisibleProof();
        });
}

void RegisterWitness() {
    if (!IsSpringBoard()) {
        return;
    }

    int selectionToken = 0;
    if (notify_register_check(
            VCAM_FIRST_LOCAL_PHOTO_VIRTUAL_SUBSTITUTION_SELECTION_STATE,
            &selectionToken) != NOTIFY_STATUS_OK) {
        return;
    }
    gSelectionToken = selectionToken;

    int proofToken = 0;
    if (notify_register_dispatch(
            VCAM_FIRST_LOCAL_PHOTO_VIRTUAL_SUBSTITUTION_NOTIFICATION,
            &proofToken,
            dispatch_get_main_queue(),
            ^(int incomingToken) {
                ValidateProof(incomingToken);
            }) != NOTIFY_STATUS_OK) {
        return;
    }

    ValidateProof(proofToken);
}

}  // namespace

__attribute__((constructor))
static void VCAMProFirstLocalPhotoVirtualSubstitutionWitnessInitialize() {
    @autoreleasepool {
        if (!IsSpringBoard()) {
            return;
        }

        RegisterWitness();
    }
}
