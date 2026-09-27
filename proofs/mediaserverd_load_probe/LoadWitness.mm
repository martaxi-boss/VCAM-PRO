#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#include "DarwinProofState.h"

#include <dispatch/dispatch.h>
#include <notify.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

namespace {

NSString* const kWitnessDirectory =
    @"/var/mobile/Library/VCAMProMediaserverdProbe";
NSString* const kWitnessPath =
    @"/var/mobile/Library/VCAMProMediaserverdProbe/witness-proof.txt";

constexpr NSInteger kMaxPresentationAttempts = 60;
constexpr int64_t kRetryIntervalNanoseconds =
    NSEC_PER_SEC;
constexpr int64_t kVisibleDurationNanoseconds =
    60 * NSEC_PER_SEC;

uint64_t gAcceptedState = 0;
bool gAcceptedProof = false;
bool gBannerPresented = false;
NSInteger gPresentationAttempts = 0;
UIView* gWitnessBanner = nil;

bool IsSpringBoard() noexcept {
    const char* process = getprogname();

    return
        process != nullptr &&
        strcmp(
            process,
            "SpringBoard") == 0;
}

bool WindowIsUsable(
    UIWindow* window) {
    return
        window != nil &&
        !window.hidden &&
        window.alpha > 0.01 &&
        window.rootViewController != nil &&
        window.bounds.size.width > 1.0 &&
        window.bounds.size.height > 1.0;
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

void WriteWitnessProof(
    uint64_t state) {
    const uint32_t timestamp =
        vcam_pro_load_state_timestamp(state);
    const uint32_t pid =
        vcam_pro_load_state_pid(state);

    NSFileManager* manager =
        [NSFileManager defaultManager];

    NSError* directoryError = nil;
    if (![manager
            createDirectoryAtPath:
                kWitnessDirectory
      withIntermediateDirectories:YES
                       attributes:nil
                            error:
                                &directoryError]) {
        return;
    }

    NSDate* date =
        [NSDate
            dateWithTimeIntervalSince1970:
                (NSTimeInterval)timestamp];

    NSISO8601DateFormatter* formatter =
        [[NSISO8601DateFormatter alloc]
            init];

    NSString* timestampText =
        [formatter stringFromDate:date];

    if (timestampText == nil) {
        timestampText =
            [NSString
                stringWithFormat:
                    @"%u",
                    timestamp];
    }

    NSString* contents =
        [NSString
            stringWithFormat:
                @"VCAM MEDIASERVERD LOAD PASS\n"
                 "version=%s\n"
                 "source=darwin-notify-state\n"
                 "timestamp=%@\n"
                 "process=mediaserverd\n"
                 "pid=%u\n"
                 "constructor=PASS\n"
                 "witness=SpringBoard\n",
                VCAM_PRO_LOAD_PROBE_VERSION,
                timestampText,
                pid];

    (void)[contents
        writeToFile:kWitnessPath
         atomically:YES
           encoding:NSUTF8StringEncoding
              error:nil];
}

void AttachVisibleWitness(
    UIWindow* window,
    uint64_t state) {
    if (gBannerPresented ||
        !WindowIsUsable(window)) {
        return;
    }

    const uint32_t pid =
        vcam_pro_load_state_pid(state);

    const CGRect bounds =
        window.bounds;
    const CGFloat horizontalInset = 12.0;
    const CGFloat bannerHeight = 132.0;
    const CGFloat width =
        MAX(
            1.0,
            bounds.size.width -
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

    const CGRect labelFrame =
        CGRectMake(
            8.0,
            8.0,
            MAX(
                1.0,
                banner.bounds.size.width -
                    16.0),
            MAX(
                1.0,
                banner.bounds.size.height -
                    16.0));

    UILabel* label =
        [[UILabel alloc]
            initWithFrame:
                labelFrame];

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
        [UIFont boldSystemFontOfSize:15.0];
    label.numberOfLines = 5;
    label.text =
        [NSString
            stringWithFormat:
                @"VCAM MEDIASERVERD LOAD PASS\n"
                 "%s\n"
                 "process=mediaserverd\n"
                 "constructor=PASS\n"
                 "pid=%u",
                VCAM_PRO_LOAD_PROBE_VERSION,
                pid];

    label.accessibilityLabel =
        @"VCAM MEDIASERVERD LOAD PASS "
         "process mediaserverd "
         "constructor PASS";

    [banner addSubview:label];
    [window addSubview:banner];
    [window bringSubviewToFront:banner];

    gWitnessBanner = banner;
    gBannerPresented = true;

    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            kVisibleDurationNanoseconds),
        dispatch_get_main_queue(),
        ^{
            [gWitnessBanner
                removeFromSuperview];
            gWitnessBanner = nil;
        });
}

void AttemptVisibleWitness();

void ScheduleVisibleRetry() {
    if (gPresentationAttempts >=
        kMaxPresentationAttempts ||
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
            AttemptVisibleWitness();
        });
}

void AttemptVisibleWitness() {
    if (!IsSpringBoard() ||
        !gAcceptedProof ||
        gAcceptedState == 0) {
        return;
    }

    ++gPresentationAttempts;

    UIWindow* window =
        FindExistingSpringBoardWindow();

    if (window != nil) {
        AttachVisibleWitness(
            window,
            gAcceptedState);
    }

    if (!gBannerPresented) {
        ScheduleVisibleRetry();
    }
}

void AcceptFreshState(
    uint64_t state) {
    if (gAcceptedProof) {
        return;
    }

    gAcceptedProof = true;
    gAcceptedState = state;

    WriteWitnessProof(state);

    dispatch_async(
        dispatch_get_main_queue(),
        ^{
            AttemptVisibleWitness();
        });
}

void ValidateTokenState(
    int token) {
    uint64_t state = 0;

    if (notify_get_state(
            token,
            &state) !=
        NOTIFY_STATUS_OK) {
        return;
    }

    const time_t nowValue =
        time(NULL);

    if (nowValue < 0 ||
        (uint64_t)nowValue >
            UINT32_MAX) {
        return;
    }

    const uint32_t now =
        (uint32_t)nowValue;

    if (!vcam_pro_load_state_is_fresh(
            state,
            now)) {
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
            VCAM_PRO_LOAD_PROBE_NOTIFICATION,
            &token,
            dispatch_get_main_queue(),
            ^(int incomingToken) {
                ValidateTokenState(
                    incomingToken);
            });

    if (status !=
        NOTIFY_STATUS_OK) {
        return;
    }

    ValidateTokenState(token);
}

}  // namespace

__attribute__((constructor))
static void
VCAMProLoadWitnessInitialize() {
    @autoreleasepool {
        if (!IsSpringBoard()) {
            return;
        }

        RegisterWitness();
    }
}
