#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#include "IOS15ActivationParityProofState.h"

#include <dispatch/dispatch.h>
#include <notify.h>

#include <stdint.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

namespace {

int gSelectionToken = -1;
uint64_t gLastState = 0;
UIView* gBanner = nil;

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

UIWindow* FindWindow() {
    UIApplication* app =
        UIApplication.sharedApplication;
    UIWindow* fallback = nil;

    for (UIScene* scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }

        if (scene.activationState !=
                UISceneActivationStateForegroundActive &&
            scene.activationState !=
                UISceneActivationStateForegroundInactive) {
            continue;
        }

        UIWindowScene* windowScene =
            static_cast<UIWindowScene*>(
                scene);

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

    return fallback;
}

NSString* OutputText(
    IOS15ActivationOutput output) {
    switch (output) {
        case IOS15ActivationOutput::Original:
            return @"ORIGINAL";
        case IOS15ActivationOutput::BlackVirtual:
            return @"BLACK_VIRTUAL";
        case IOS15ActivationOutput::PhotoVirtual:
            return @"PHOTO_VIRTUAL";
        case IOS15ActivationOutput::None:
        default:
            return @"NONE";
    }
}

NSString* HeaderText(
    IOS15ActivationOutput output) {
    switch (output) {
        case IOS15ActivationOutput::Original:
            return @"VCAM ACTIVATION PARITY ORIGINAL PASS";
        case IOS15ActivationOutput::BlackVirtual:
            return @"VCAM ACTIVATION PARITY BLACK PASS";
        case IOS15ActivationOutput::PhotoVirtual:
            return @"VCAM ACTIVATION PARITY PHOTO PASS";
        case IOS15ActivationOutput::None:
        default:
            return @"VCAM ACTIVATION PARITY";
    }
}

void ShowBanner(
    NSString* text) {
    UIWindow* window = FindWindow();
    if (!WindowIsUsable(window) ||
        text == nil) {
        return;
    }

    [gBanner removeFromSuperview];
    gBanner = nil;

    const CGRect bounds = window.bounds;
    const CGFloat inset = 10.0;
    const CGFloat top =
        MAX(window.safeAreaInsets.top + 8.0, 34.0);
    const CGFloat width =
        MAX(1.0, bounds.size.width - inset * 2.0);
    const CGFloat height =
        MIN(360.0, MAX(230.0, bounds.size.height - top - 16.0));

    UIView* banner =
        [[UIView alloc] initWithFrame:
            CGRectMake(inset, top, width, height)];
    banner.backgroundColor =
        [UIColor colorWithWhite:0.08 alpha:0.98];
    banner.userInteractionEnabled = NO;

    UILabel* label =
        [[UILabel alloc] initWithFrame:
            CGRectInset(banner.bounds, 8.0, 8.0)];
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
        [UIFont monospacedSystemFontOfSize:10.5
                                   weight:UIFontWeightSemibold];
    label.numberOfLines = 0;
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.78;
    label.text = text;
    label.accessibilityLabel = text;

    [banner addSubview:label];
    [window addSubview:banner];
    [window bringSubviewToFront:banner];

    gBanner = banner;

    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            45 * NSEC_PER_SEC),
        dispatch_get_main_queue(),
        ^{
            [gBanner removeFromSuperview];
            gBanner = nil;
        });
}

void ValidateAndPresent(
    int proofToken) {
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
        static_cast<uint64_t>(nowValue) >
            UINT32_MAX ||
        state == gLastState ||
        !vcam_ios15_activation_parity_state_is_valid(
            state,
            selectionGeneration,
            static_cast<uint32_t>(
                nowValue))) {
        return;
    }

    gLastState = state;

    const IOS15ActivationOutput output =
        vcam_ios15_activation_parity_output(
            state);
    const uint32_t pid =
        vcam_ios15_activation_parity_pid(
            state);

    NSString* details = nil;

    if (output ==
        IOS15ActivationOutput::Original) {
        details =
            [NSString stringWithFormat:
                @"%@\n"
                 "output=%@\n"
                 "vcam-enabled=NO\n"
                 "camera-callback=EXERCISED\n"
                 "selection-generation=%llu\n"
                 "pid=%u",
                HeaderText(output),
                OutputText(output),
                static_cast<unsigned long long>(
                    selectionGeneration),
                pid];
    } else if (output ==
               IOS15ActivationOutput::BlackVirtual) {
        details =
            [NSString stringWithFormat:
                @"%@\n"
                 "output=%@\n"
                 "vcam-enabled=YES\n"
                 "virtual-source=BLACK_FALLBACK\n"
                 "virtual-buffer-non-null=YES\n"
                 "geometry-match=YES\n"
                 "camera-callback=EXERCISED\n"
                 "selection-generation=%llu\n"
                 "pid=%u",
                HeaderText(output),
                OutputText(output),
                static_cast<unsigned long long>(
                    selectionGeneration),
                pid];
    } else if (output ==
               IOS15ActivationOutput::PhotoVirtual) {
        details =
            [NSString stringWithFormat:
                @"%@\n"
                 "output=%@\n"
                 "vcam-enabled=YES\n"
                 "media-kind=PHOTO\n"
                 "virtual-source=PREPARED_MEDIA\n"
                 "virtual-buffer-non-null=YES\n"
                 "geometry-match=YES\n"
                 "camera-callback=EXERCISED\n"
                 "selection-generation=%llu\n"
                 "pid=%u",
                HeaderText(output),
                OutputText(output),
                static_cast<unsigned long long>(
                    selectionGeneration),
                pid];
    }

    if (details != nil) {
        dispatch_async(
            dispatch_get_main_queue(),
            ^{
                ShowBanner(details);
            });
    }
}

void RegisterWitness() {
    if (!IsSpringBoard()) {
        return;
    }

    int selectionToken = 0;
    if (notify_register_check(
            VCAM_IOS15_ACTIVATION_PARITY_SELECTION_STATE,
            &selectionToken) !=
        NOTIFY_STATUS_OK) {
        return;
    }
    gSelectionToken =
        selectionToken;

    int proofToken = 0;
    if (notify_register_dispatch(
            VCAM_IOS15_ACTIVATION_PARITY_NOTIFICATION,
            &proofToken,
            dispatch_get_main_queue(),
            ^(int incomingToken) {
                ValidateAndPresent(
                    incomingToken);
            }) != NOTIFY_STATUS_OK) {
        return;
    }

    ValidateAndPresent(
        proofToken);
}

}  // namespace

__attribute__((constructor))
static void VCAMProIOS15ActivationParityWitnessInitialize() {
    @autoreleasepool {
        RegisterWitness();
    }
}
