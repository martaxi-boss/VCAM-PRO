#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#include "FirstLocalPhotoSubstitutionDiagnosticProofState.h"

#include <dispatch/dispatch.h>
#include <notify.h>

#include <stdint.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

namespace {

constexpr int64_t kVisibleDurationNanoseconds = 60 * NSEC_PER_SEC;

int gSelectionToken = -1;
int gCountsToken = -1;
int gFailCountsToken = -1;
int gObservedGeometryToken = -1;
int gTargetGeometryToken = -1;
int gSessionToken = -1;
int gLastToken = -1;

bool gPresented = false;
UIView* gContainer = nil;

bool IsSpringBoard() noexcept {
    const char* process = getprogname();
    return process != nullptr &&
           strcmp(process, "SpringBoard") == 0;
}

NSString* ClassificationText(
    FirstPhotoSubDiagnosticClassification value) {
    switch (value) {
        case FirstPhotoSubDiagnosticClassification::NoGenuineCallbackObserved:
            return @"NO_GENUINE_CALLBACK_OBSERVED";
        case FirstPhotoSubDiagnosticClassification::OriginalDisabled:
            return @"ORIGINAL_DISABLED";
        case FirstPhotoSubDiagnosticClassification::OriginalReconfigurationContended:
            return @"ORIGINAL_RECONFIGURATION_CONTENDED";
        case FirstPhotoSubDiagnosticClassification::OriginalProducerUnavailable:
            return @"ORIGINAL_PRODUCER_UNAVAILABLE";
        case FirstPhotoSubDiagnosticClassification::OriginalEmptyOrNoEligible:
            return @"ORIGINAL_EMPTY_OR_NO_ELIGIBLE";
        case FirstPhotoSubDiagnosticClassification::OriginalInvalidLease:
            return @"ORIGINAL_INVALID_LEASE";
        case FirstPhotoSubDiagnosticClassification::OriginalGeometryMismatch:
            return @"ORIGINAL_GEOMETRY_MISMATCH";
        case FirstPhotoSubDiagnosticClassification::OriginalMixedFailOpen:
            return @"ORIGINAL_MIXED_FAIL_OPEN";
        case FirstPhotoSubDiagnosticClassification::VirtualDecisionObserved:
            return @"VIRTUAL_DECISION_OBSERVED";
        case FirstPhotoSubDiagnosticClassification::None:
        default:
            return @"NONE";
    }
}

NSString* DecisionText(
    FirstPhotoSubDiagnosticDecision value) {
    switch (value) {
        case FirstPhotoSubDiagnosticDecision::Original:
            return @"ORIGINAL";
        case FirstPhotoSubDiagnosticDecision::Virtual:
            return @"VIRTUAL";
        case FirstPhotoSubDiagnosticDecision::None:
        default:
            return @"NONE";
    }
}

NSString* ReasonText(
    FirstPhotoSubDiagnosticReason value) {
    switch (value) {
        case FirstPhotoSubDiagnosticReason::Disabled:
            return @"DISABLED";
        case FirstPhotoSubDiagnosticReason::ReconfigurationContended:
            return @"RECONFIGURATION_CONTENDED";
        case FirstPhotoSubDiagnosticReason::ProducerUnavailable:
            return @"PRODUCER_UNAVAILABLE";
        case FirstPhotoSubDiagnosticReason::EmptyOrNoEligibleFrame:
            return @"EMPTY_OR_NO_ELIGIBLE";
        case FirstPhotoSubDiagnosticReason::InvalidLease:
            return @"INVALID_LEASE";
        case FirstPhotoSubDiagnosticReason::GeometryMismatch:
            return @"GEOMETRY_MISMATCH";
        case FirstPhotoSubDiagnosticReason::None:
        default:
            return @"NONE";
    }
}

NSString* PlaybackText(
    FirstPhotoSubDiagnosticPlaybackState value) {
    switch (value) {
        case FirstPhotoSubDiagnosticPlaybackState::Empty:
            return @"EMPTY";
        case FirstPhotoSubDiagnosticPlaybackState::Ready:
            return @"READY";
        case FirstPhotoSubDiagnosticPlaybackState::Playing:
            return @"PLAYING";
        case FirstPhotoSubDiagnosticPlaybackState::Paused:
            return @"PAUSED";
        case FirstPhotoSubDiagnosticPlaybackState::Ended:
            return @"ENDED";
        case FirstPhotoSubDiagnosticPlaybackState::Failed:
            return @"FAILED";
        case FirstPhotoSubDiagnosticPlaybackState::Unknown:
        default:
            return @"UNKNOWN";
    }
}

NSString* MediaKindText(
    FirstPhotoSubDiagnosticMediaKind value) {
    switch (value) {
        case FirstPhotoSubDiagnosticMediaKind::Photo:
            return @"PHOTO";
        case FirstPhotoSubDiagnosticMediaKind::Video:
            return @"VIDEO";
        case FirstPhotoSubDiagnosticMediaKind::None:
        default:
            return @"NONE";
    }
}

NSString* YesNo(bool value) {
    return value ? @"YES" : @"NO";
}

UIWindow* FindWindow() {
    UIApplication* app = UIApplication.sharedApplication;
    UIWindow* fallback = nil;

    for (UIScene* scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        if (scene.activationState != UISceneActivationStateForegroundActive &&
            scene.activationState != UISceneActivationStateForegroundInactive) {
            continue;
        }

        UIWindowScene* windowScene = static_cast<UIWindowScene*>(scene);
        for (UIWindow* window in windowScene.windows) {
            if (window.hidden ||
                window.alpha <= 0.01 ||
                window.rootViewController == nil) {
                continue;
            }
            if (window.isKeyWindow) {
                return window;
            }
            if (fallback == nil) {
                fallback = window;
            }
        }
    }

    return fallback;
}

bool ReadToken(int token, uint64_t* value) {
    return token >= 0 &&
           value != nullptr &&
           notify_get_state(token, value) == NOTIFY_STATUS_OK;
}

UILabel* MakePanel(
    CGRect frame,
    NSString* text) {
    UILabel* label =
        [[UILabel alloc] initWithFrame:frame];
    label.backgroundColor =
        [UIColor colorWithWhite:0.08 alpha:0.98];
    label.textColor = UIColor.whiteColor;
    label.font =
        [UIFont monospacedSystemFontOfSize:8.1
                                   weight:UIFontWeightSemibold];
    label.numberOfLines = 0;
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.72;
    label.textAlignment = NSTextAlignmentLeft;
    label.text = text;
    label.accessibilityLabel = text;
    label.userInteractionEnabled = NO;
    return label;
}

void Present(
    uint64_t primary,
    uint64_t selection,
    uint64_t counts,
    uint64_t failCounts,
    uint64_t observedGeometry,
    uint64_t targetGeometry,
    uint64_t session,
    uint64_t last) {
    if (gPresented) {
        return;
    }

    UIWindow* window = FindWindow();
    if (window == nil) {
        return;
    }

    const auto classification =
        vcam_first_photo_sub_diag_primary_classification(primary);
    const uint32_t pid =
        vcam_first_photo_sub_diag_primary_pid(primary);

    const uint32_t callbackCount =
        vcam_first_photo_sub_diag_callback_count(counts);
    const uint32_t decisionDelta =
        vcam_first_photo_sub_diag_decision_count_delta(counts);
    const uint32_t virtualDelta =
        vcam_first_photo_sub_diag_virtual_decision_count_delta(counts);
    const uint32_t virtualCount =
        vcam_first_photo_sub_diag_decision_virtual_count(counts);
    const uint32_t originalCount =
        vcam_first_photo_sub_diag_decision_original_count(counts);

    const uint32_t disabled =
        vcam_first_photo_sub_diag_fail_disabled(failCounts);
    const uint32_t reconfiguration =
        vcam_first_photo_sub_diag_fail_reconfiguration(failCounts);
    const uint32_t producer =
        vcam_first_photo_sub_diag_fail_producer(failCounts);
    const uint32_t empty =
        vcam_first_photo_sub_diag_fail_empty(failCounts);
    const uint32_t invalidLease =
        vcam_first_photo_sub_diag_fail_invalid_lease(failCounts);
    const uint32_t geometryMismatch =
        vcam_first_photo_sub_diag_fail_geometry(failCounts);
    const uint32_t geometryChanges =
        vcam_first_photo_sub_diag_geometry_change_count(failCounts);

    const uint32_t observedWidth =
        vcam_first_photo_sub_diag_geometry_width(observedGeometry);
    const uint32_t observedHeight =
        vcam_first_photo_sub_diag_geometry_height(observedGeometry);
    const uint32_t observedFormat =
        vcam_first_photo_sub_diag_geometry_pixel_format(observedGeometry);

    const uint32_t targetWidth =
        vcam_first_photo_sub_diag_geometry_width(targetGeometry);
    const uint32_t targetHeight =
        vcam_first_photo_sub_diag_geometry_height(targetGeometry);
    const uint32_t targetFormat =
        vcam_first_photo_sub_diag_geometry_pixel_format(targetGeometry);

    const auto playback =
        vcam_first_photo_sub_diag_playback_state(session);
    const auto selectedKind =
        vcam_first_photo_sub_diag_selected_media_kind(session);

    const auto lastDecision =
        vcam_first_photo_sub_diag_last_decision(last);
    const auto lastReason =
        vcam_first_photo_sub_diag_last_reason(last);

    NSString* panelOne =
        [NSString stringWithFormat:
            @"VCAM PHOTO SUBSTITUTION DIAGNOSTIC\n"
             "classification=%@\n"
             "selection-generation=%llu\n"
             "camera-callback-count=%u\n"
             "decision-count-delta=%u\n"
             "virtual-decision-count-delta=%u\n"
             "decision-virtual-count=%u\n"
             "decision-original-count=%u\n"
             "fail-disabled=%u\n"
             "fail-reconfiguration-contended=%u\n"
             "fail-producer-unavailable=%u\n"
             "fail-empty-or-no-eligible=%u\n"
             "fail-invalid-lease=%u\n"
             "fail-geometry-mismatch=%u\n"
             "geometry-change-count=%u\n"
             "last-decision=%@\n"
             "last-fail-open-reason=%@\n"
             "pid=%u",
            ClassificationText(classification),
            static_cast<unsigned long long>(selection),
            callbackCount,
            decisionDelta,
            virtualDelta,
            virtualCount,
            originalCount,
            disabled,
            reconfiguration,
            producer,
            empty,
            invalidLease,
            geometryMismatch,
            geometryChanges,
            DecisionText(lastDecision),
            ReasonText(lastReason),
            pid];

    NSString* panelTwo =
        [NSString stringWithFormat:
            @"VCAM PHOTO SUBSTITUTION STATE\n"
             "vcam-enabled=%@\n"
             "photo-selected=%@\n"
             "producer-healthy=%@\n"
             "session-exists=%@\n"
             "playback-state=%@\n"
             "ready-frame-count=%u\n"
             "selected-media-valid=%@\n"
             "selected-media-kind=%@\n"
             "selected-media-path-match=%@\n"
             "observed-camera-width=%u\n"
             "observed-camera-height=%u\n"
             "observed-camera-pixel-format=%u\n"
             "session-target-width=%u\n"
             "session-target-height=%u\n"
             "session-target-pixel-format=%u\n"
             "virtual-buffer-non-null=%@\n"
             "virtual-buffer-different-from-original=%@\n"
             "virtual-width-match=%@\n"
             "virtual-height-match=%@\n"
             "virtual-pixel-format-match=%@\n"
             "virtual-buffer-geometry-match=%@",
            YesNo(vcam_first_photo_sub_diag_vcam_enabled(session)),
            YesNo(vcam_first_photo_sub_diag_photo_selected(session)),
            YesNo(vcam_first_photo_sub_diag_producer_healthy(session)),
            YesNo(vcam_first_photo_sub_diag_session_exists(session)),
            PlaybackText(playback),
            vcam_first_photo_sub_diag_ready_frame_count(session),
            YesNo(vcam_first_photo_sub_diag_selected_valid(session)),
            MediaKindText(selectedKind),
            YesNo(vcam_first_photo_sub_diag_selected_path_match(session)),
            observedWidth,
            observedHeight,
            observedFormat,
            targetWidth,
            targetHeight,
            targetFormat,
            YesNo(vcam_first_photo_sub_diag_virtual_non_null(last)),
            YesNo(vcam_first_photo_sub_diag_virtual_different(last)),
            YesNo(vcam_first_photo_sub_diag_width_match(last)),
            YesNo(vcam_first_photo_sub_diag_height_match(last)),
            YesNo(vcam_first_photo_sub_diag_pixel_format_match(last)),
            YesNo(vcam_first_photo_sub_diag_geometry_match(last))];

    const CGRect bounds = window.bounds;
    const CGFloat inset = 8.0;
    const CGFloat top =
        MAX(window.safeAreaInsets.top + 4.0, 24.0);
    const CGFloat available =
        MAX(300.0, bounds.size.height - top - 12.0);
    const CGFloat gap = 6.0;
    const CGFloat half =
        (available - gap) / 2.0;
    const CGFloat width =
        MAX(1.0, bounds.size.width - (inset * 2.0));

    UIView* container =
        [[UIView alloc] initWithFrame:
            CGRectMake(inset, top, width, available)];
    container.backgroundColor = UIColor.clearColor;
    container.userInteractionEnabled = NO;
    container.autoresizingMask =
        UIViewAutoresizingFlexibleWidth |
        UIViewAutoresizingFlexibleHeight;

    UILabel* first =
        MakePanel(
            CGRectMake(0, 0, width, half),
            panelOne);
    UILabel* second =
        MakePanel(
            CGRectMake(0, half + gap, width, half),
            panelTwo);

    [container addSubview:first];
    [container addSubview:second];
    [window addSubview:container];
    [window bringSubviewToFront:container];

    gContainer = container;
    gPresented = true;

    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            kVisibleDurationNanoseconds),
        dispatch_get_main_queue(),
        ^{
            [gContainer removeFromSuperview];
            gContainer = nil;
        });
}

bool RegisterCheck(
    const char* name,
    int* token) {
    if (name == nullptr ||
        token == nullptr) {
        return false;
    }

    int value = 0;
    if (notify_register_check(
            name,
            &value) != NOTIFY_STATUS_OK) {
        return false;
    }

    *token = value;
    return true;
}

void ValidatePrimary(int primaryToken) {
    uint64_t primary = 0;
    uint64_t selection = 0;
    uint64_t counts = 0;
    uint64_t failCounts = 0;
    uint64_t observedGeometry = 0;
    uint64_t targetGeometry = 0;
    uint64_t session = 0;
    uint64_t last = 0;

    if (!ReadToken(primaryToken, &primary) ||
        !ReadToken(gSelectionToken, &selection) ||
        !ReadToken(gCountsToken, &counts) ||
        !ReadToken(gFailCountsToken, &failCounts) ||
        !ReadToken(gObservedGeometryToken, &observedGeometry) ||
        !ReadToken(gTargetGeometryToken, &targetGeometry) ||
        !ReadToken(gSessionToken, &session) ||
        !ReadToken(gLastToken, &last)) {
        return;
    }

    const time_t nowValue = time(nullptr);
    if (nowValue < 0 ||
        static_cast<uint64_t>(nowValue) > UINT32_MAX ||
        !vcam_first_photo_sub_diag_primary_is_valid_fresh(
            primary,
            selection,
            static_cast<uint32_t>(nowValue))) {
        return;
    }

    dispatch_async(
        dispatch_get_main_queue(),
        ^{
            Present(
                primary,
                selection,
                counts,
                failCounts,
                observedGeometry,
                targetGeometry,
                session,
                last);
        });
}

void RegisterWitness() {
    if (!IsSpringBoard() ||
        !RegisterCheck(
            VCAM_FIRST_PHOTO_SUB_DIAGNOSTIC_SELECTION_STATE,
            &gSelectionToken) ||
        !RegisterCheck(
            VCAM_FIRST_PHOTO_SUB_DIAGNOSTIC_COUNTS_STATE,
            &gCountsToken) ||
        !RegisterCheck(
            VCAM_FIRST_PHOTO_SUB_DIAGNOSTIC_FAIL_COUNTS_STATE,
            &gFailCountsToken) ||
        !RegisterCheck(
            VCAM_FIRST_PHOTO_SUB_DIAGNOSTIC_OBSERVED_GEOMETRY_STATE,
            &gObservedGeometryToken) ||
        !RegisterCheck(
            VCAM_FIRST_PHOTO_SUB_DIAGNOSTIC_TARGET_GEOMETRY_STATE,
            &gTargetGeometryToken) ||
        !RegisterCheck(
            VCAM_FIRST_PHOTO_SUB_DIAGNOSTIC_SESSION_STATE,
            &gSessionToken) ||
        !RegisterCheck(
            VCAM_FIRST_PHOTO_SUB_DIAGNOSTIC_LAST_STATE,
            &gLastToken)) {
        return;
    }

    int primaryToken = 0;
    if (notify_register_dispatch(
            VCAM_FIRST_PHOTO_SUB_DIAGNOSTIC_NOTIFICATION,
            &primaryToken,
            dispatch_get_main_queue(),
            ^(int incomingToken) {
                ValidatePrimary(incomingToken);
            }) != NOTIFY_STATUS_OK) {
        return;
    }

    ValidatePrimary(primaryToken);
}

}  // namespace

__attribute__((constructor))
static void VCAMProFirstLocalPhotoSubstitutionDiagnosticWitnessInitialize() {
    @autoreleasepool {
        if (!IsSpringBoard()) {
            return;
        }

        RegisterWitness();
    }
}
