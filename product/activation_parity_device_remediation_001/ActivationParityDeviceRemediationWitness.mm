#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#include "ActivationParityDeviceRemediationProofState.h"

#include <dispatch/dispatch.h>
#include <notify.h>

#include <stdint.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

namespace {

int gTokens[17] = {};
bool gRegistered = false;
bool gPresented = false;
UIView* gBanner = nil;

enum TokenIndex : int {
    Selection = 0,
    PathHash,
    Control,
    ObservedGeometry,
    TargetGeometry,
    Session,
    QueueGeneration,
    QueueEpoch,
    AdapterGeneration,
    AdapterEpoch,
    Producer,
    DecisionCounts,
    FailCounts,
    LastDecision,
    LastPreparedGeometry,
    StillCounts,
    StillGeometry,
};

bool IsSpringBoard() noexcept {
    const char* process = getprogname();
    return
        process != nullptr &&
        strcmp(process, "SpringBoard") == 0;
}

NSString* YesNo(bool value) {
    return value ? @"YES" : @"NO";
}

NSString* StageText(
    ActivationParityEncodedStage stage) {
    switch (stage) {
        case ActivationParityEncodedStage::WaitingControl:
            return @"WAITING_CONTROL";
        case ActivationParityEncodedStage::StagingMismatch:
            return @"STAGING_MISMATCH";
        case ActivationParityEncodedStage::WaitingGeometry:
            return @"WAITING_GEOMETRY";
        case ActivationParityEncodedStage::SelectPhotoFailed:
            return @"SELECT_PHOTO_FAILED";
        case ActivationParityEncodedStage::ProducerStartFailed:
            return @"PRODUCER_START_FAILED";
        case ActivationParityEncodedStage::SessionAbsent:
            return @"SESSION_ABSENT";
        case ActivationParityEncodedStage::ProducerUnavailable:
            return @"PRODUCER_UNAVAILABLE";
        case ActivationParityEncodedStage::QueueEmpty:
            return @"QUEUE_EMPTY_OR_NO_ELIGIBLE";
        case ActivationParityEncodedStage::ReconfigurationContended:
            return @"RECONFIGURATION_CONTENDED";
        case ActivationParityEncodedStage::InvalidLease:
            return @"INVALID_LEASE";
        case ActivationParityEncodedStage::GeometryMismatch:
            return @"GEOMETRY_MISMATCH";
        case ActivationParityEncodedStage::BlackFallback:
            return @"BLACK_FALLBACK";
        case ActivationParityEncodedStage::PreparedMedia:
            return @"PREPARED_MEDIA";
        case ActivationParityEncodedStage::EmergencyOriginal:
            return @"EMERGENCY_ORIGINAL";
        default:
            return @"UNKNOWN";
    }
}

NSString* DecisionSourceText(uint8_t value) {
    switch (value) {
        case 1: return @"PREPARED_MEDIA";
        case 2: return @"BLACK_FALLBACK";
        default: return @"ORIGINAL";
    }
}

NSString* FailReasonText(uint8_t value) {
    switch (value) {
        case 1: return @"DISABLED";
        case 2: return @"RECONFIG_CONTENDED";
        case 3: return @"PRODUCER_UNAVAILABLE";
        case 4: return @"EMPTY_OR_NO_ELIGIBLE";
        case 5: return @"INVALID_LEASE";
        case 6: return @"GEOMETRY_MISMATCH";
        case 7: return @"BLACK_UNAVAILABLE";
        default: return @"NONE";
    }
}

NSString* PlaybackIntentText(uint8_t value) {
    switch (value) {
        case 1: return @"PLAYING";
        case 2: return @"PAUSED";
        default: return @"STOPPED";
    }
}

NSString* PlaybackStateText(uint8_t value) {
    switch (value) {
        case 0: return @"EMPTY";
        case 1: return @"READY";
        case 2: return @"PLAYING";
        case 3: return @"PAUSED";
        case 4: return @"ENDED";
        case 5: return @"FAILED";
        default: return @"UNKNOWN";
    }
}

NSString* ReaderStateText(uint8_t value) {
    switch (value) {
        case 0: return @"UNINITIALIZED";
        case 1: return @"READY";
        case 2: return @"READING";
        case 3: return @"COMPLETED";
        case 4: return @"FAILED";
        case 5: return @"CANCELLED";
        default: return @"UNKNOWN";
    }
}

NSString* GeometryText(uint64_t key) {
    if (key == 0) {
        return @"NONE";
    }

    const uint32_t width =
        (uint32_t)(key & UINT64_C(0xffff));
    const uint32_t height =
        (uint32_t)((key >> 16) & UINT64_C(0xffff));
    const uint32_t format =
        (uint32_t)(key >> 32);

    return
        [NSString stringWithFormat:
            @"%ux%u/0x%08x",
            width,
            height,
            format];
}

bool ReadToken(
    int token,
    uint64_t* state) {
    return
        token >= 0 &&
        state != nullptr &&
        notify_get_state(
            token,
            state) == NOTIFY_STATUS_OK;
}

UIWindow* FindWindow() {
    UIApplication* app =
        UIApplication.sharedApplication;

    for (UIScene* scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }

        UIWindowScene* windowScene =
            static_cast<UIWindowScene*>(scene);
        for (UIWindow* window in windowScene.windows) {
            if (!window.hidden &&
                window.alpha > 0.01 &&
                window.rootViewController != nil) {
                if (window.isKeyWindow) {
                    return window;
                }
            }
        }
    }

    id<UIApplicationDelegate> delegate =
        app.delegate;
    if (delegate != nil &&
        [delegate respondsToSelector:@selector(window)]) {
        return delegate.window;
    }

    return nil;
}

void PresentText(NSString* text) {
    if (gPresented || text == nil) {
        return;
    }

    UIWindow* window = FindWindow();
    if (window == nil) {
        dispatch_after(
            dispatch_time(
                DISPATCH_TIME_NOW,
                NSEC_PER_SEC),
            dispatch_get_main_queue(),
            ^{
                PresentText(text);
            });
        return;
    }

    const CGFloat inset = 8.0;
    const CGFloat top =
        MAX(window.safeAreaInsets.top + 4.0, 22.0);
    const CGFloat height =
        MIN(
            window.bounds.size.height - top - 8.0,
            690.0);

    UIView* banner =
        [[UIView alloc] initWithFrame:
            CGRectMake(
                inset,
                top,
                window.bounds.size.width -
                    inset * 2.0,
                height)];
    banner.backgroundColor =
        [UIColor colorWithWhite:0.06 alpha:0.98];
    banner.userInteractionEnabled = NO;
    banner.autoresizingMask =
        UIViewAutoresizingFlexibleWidth |
        UIViewAutoresizingFlexibleBottomMargin;

    UILabel* label =
        [[UILabel alloc] initWithFrame:
            CGRectInset(banner.bounds, 7.0, 7.0)];
    label.backgroundColor = UIColor.clearColor;
    label.textColor = UIColor.whiteColor;
    label.font =
        [UIFont monospacedSystemFontOfSize:8.0
                                   weight:UIFontWeightMedium];
    label.numberOfLines = 0;
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.72;
    label.text = text;
    label.accessibilityLabel = text;
    label.autoresizingMask =
        UIViewAutoresizingFlexibleWidth |
        UIViewAutoresizingFlexibleHeight;

    [banner addSubview:label];
    [window addSubview:banner];
    [window bringSubviewToFront:banner];

    gBanner = banner;
    gPresented = true;

    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            90 * NSEC_PER_SEC),
        dispatch_get_main_queue(),
        ^{
            [gBanner removeFromSuperview];
            gBanner = nil;
        });
}

void ValidateAndPresent(int primaryToken) {
    uint64_t primary = 0;
    uint64_t states[17] = {};

    if (!ReadToken(primaryToken, &primary)) {
        return;
    }

    for (int i = 0; i < 17; ++i) {
        if (!ReadToken(
                gTokens[i],
                &states[i])) {
            return;
        }
    }

    const time_t nowValue = time(nullptr);
    if (nowValue < 0 ||
        static_cast<uint64_t>(nowValue) > UINT32_MAX ||
        !vcam_activation_remediation_primary_is_valid_fresh(
            primary,
            states[Selection],
            static_cast<uint32_t>(nowValue))) {
        return;
    }

    const uint64_t control = states[Control];
    const uint64_t session = states[Session];
    const uint64_t producer = states[Producer];
    const uint64_t decisionCounts = states[DecisionCounts];
    const uint64_t failCounts = states[FailCounts];
    const uint64_t lastDecision = states[LastDecision];
    const uint64_t stillCounts = states[StillCounts];

    const uint32_t callbacks =
        (uint32_t)(decisionCounts & UINT64_C(0xffff));
    const uint32_t prepared =
        (uint32_t)((decisionCounts >> 16) & UINT64_C(0xffff));
    const uint32_t black =
        (uint32_t)((decisionCounts >> 32) & UINT64_C(0xffff));
    const uint32_t original =
        (uint32_t)((decisionCounts >> 48) & UINT64_C(0xffff));

    const uint32_t failReconfig =
        (uint32_t)(failCounts & UINT64_C(0x0fff));
    const uint32_t failProducer =
        (uint32_t)((failCounts >> 12) & UINT64_C(0x0fff));
    const uint32_t failEmpty =
        (uint32_t)((failCounts >> 24) & UINT64_C(0x0fff));
    const uint32_t failLease =
        (uint32_t)((failCounts >> 36) & UINT64_C(0x0fff));
    const uint32_t failGeometry =
        (uint32_t)((failCounts >> 48) & UINT64_C(0x0fff));

    const uint8_t lastSource =
        (uint8_t)(lastDecision & UINT64_C(0x03));
    const uint8_t lastReason =
        (uint8_t)((lastDecision >> 2) & UINT64_C(0x0f));

    const uint32_t stillTotal =
        (uint32_t)(stillCounts & UINT64_C(0xff));
    const uint32_t stillPresent =
        (uint32_t)((stillCounts >> 8) & UINT64_C(0xff));
    const uint32_t stillAbsent =
        (uint32_t)((stillCounts >> 16) & UINT64_C(0xff));
    const uint32_t stillPrepared =
        (uint32_t)((stillCounts >> 24) & UINT64_C(0xff));
    const uint32_t stillBlack =
        (uint32_t)((stillCounts >> 32) & UINT64_C(0xff));
    const uint32_t stillOriginal =
        (uint32_t)((stillCounts >> 40) & UINT64_C(0xff));
    const uint32_t commitSuccess =
        (uint32_t)((stillCounts >> 48) & UINT64_C(0xff));
    const uint32_t commitFailure =
        (uint32_t)((stillCounts >> 56) & UINT64_C(0xff));

    const uint64_t sessionFlags =
        vcam_activation_remediation_session_flags(
            session);

    NSString* text =
        [NSString stringWithFormat:
            @"VCAM ACTIVATION PARITY REMEDIATION DIAGNOSTIC\n"
             "stage=%@ pid=%u\n"
             "selection-generation=%llu path-hash=0x%016llx\n"
             "enabled=%@ photo=%@ has-media=%@ staged=%@ control-observed=%@\n"
             "select-attempted=%@ select-result=%@ start-attempted=%@ start-result=%@\n"
             "session-installed=%@ replacements=%u queue-bound=%@\n"
             "observed-geometry=%@ target-geometry=%@\n"
             "session-exists=%@ selected-valid=%@ selected-photo=%@ path-match=%@\n"
             "playback-intent=%@ playback-state=%@ producer-healthy=%@\n"
             "reader-state=%@ reader-error=%u frame-sequence=%llu ready-queue=%u\n"
             "queue-gen=%llu queue-epoch=%llu adapter-gen=%llu adapter-epoch=%llu\n"
             "callbacks=%u prepared=%u black=%u original=%u\n"
             "fail: reconfig=%u producer=%u empty=%u lease=%u geometry=%u\n"
             "last-source=%@ last-fail=%@\n"
             "last-prepared-geometry=%@\n"
             "hook-total=%u still-key-present=%u absent=%u\n"
             "still-source: prepared=%u black=%u original=%u\n"
             "inplace-commit: success=%u failure=%u still-geometry=%@",
            StageText(
                vcam_activation_remediation_primary_stage(primary)),
            vcam_activation_remediation_primary_pid(primary),
            static_cast<unsigned long long>(states[Selection]),
            static_cast<unsigned long long>(states[PathHash]),
            YesNo((control & VCAM_ACTIVATION_CONTROL_ENABLED) != 0),
            YesNo((control & VCAM_ACTIVATION_CONTROL_PHOTO) != 0),
            YesNo((control & VCAM_ACTIVATION_CONTROL_HAS_MEDIA) != 0),
            YesNo((control & VCAM_ACTIVATION_CONTROL_STAGED) != 0),
            YesNo((control & VCAM_ACTIVATION_CONTROL_OBSERVED) != 0),
            YesNo((control & VCAM_ACTIVATION_CONTROL_SELECT_ATTEMPTED) != 0),
            YesNo((control & VCAM_ACTIVATION_CONTROL_SELECT_RESULT) != 0),
            YesNo(vcam_activation_remediation_start_attempted(producer)),
            YesNo(vcam_activation_remediation_start_result(producer)),
            YesNo((control & VCAM_ACTIVATION_CONTROL_SESSION_INSTALLED) != 0),
            vcam_activation_remediation_replacement_count(session),
            YesNo((control & VCAM_ACTIVATION_CONTROL_QUEUE_BOUND) != 0),
            GeometryText(states[ObservedGeometry]),
            GeometryText(states[TargetGeometry]),
            YesNo((sessionFlags & VCAM_ACTIVATION_SESSION_EXISTS) != 0),
            YesNo((sessionFlags & VCAM_ACTIVATION_SESSION_SELECTED_VALID) != 0),
            YesNo((sessionFlags & VCAM_ACTIVATION_SESSION_SELECTED_PHOTO) != 0),
            YesNo((sessionFlags & VCAM_ACTIVATION_SESSION_PATH_MATCH) != 0),
            PlaybackIntentText(
                vcam_activation_remediation_playback_intent(session)),
            PlaybackStateText(
                vcam_activation_remediation_playback_state(session)),
            YesNo((sessionFlags & VCAM_ACTIVATION_SESSION_PRODUCER_HEALTHY) != 0),
            ReaderStateText(
                vcam_activation_remediation_reader_state(session)),
            vcam_activation_remediation_reader_error(session),
            static_cast<unsigned long long>(
                vcam_activation_remediation_frame_sequence_count(producer)),
            vcam_activation_remediation_ready_count(session),
            static_cast<unsigned long long>(states[QueueGeneration]),
            static_cast<unsigned long long>(states[QueueEpoch]),
            static_cast<unsigned long long>(states[AdapterGeneration]),
            static_cast<unsigned long long>(states[AdapterEpoch]),
            callbacks,
            prepared,
            black,
            original,
            failReconfig,
            failProducer,
            failEmpty,
            failLease,
            failGeometry,
            DecisionSourceText(lastSource),
            FailReasonText(lastReason),
            GeometryText(states[LastPreparedGeometry]),
            stillTotal,
            stillPresent,
            stillAbsent,
            stillPrepared,
            stillBlack,
            stillOriginal,
            commitSuccess,
            commitFailure,
            GeometryText(states[StillGeometry])];

    PresentText(text);
}

bool RegisterToken(
    const char* name,
    int* token) {
    return
        notify_register_check(
            name,
            token) == NOTIFY_STATUS_OK;
}

void RegisterWitness() {
    const char* names[17] = {
        VCAM_ACTIVATION_PARITY_REMEDIATION_SELECTION_STATE,
        VCAM_ACTIVATION_PARITY_REMEDIATION_PATH_HASH_STATE,
        VCAM_ACTIVATION_PARITY_REMEDIATION_CONTROL_STATE,
        VCAM_ACTIVATION_PARITY_REMEDIATION_OBSERVED_GEOMETRY_STATE,
        VCAM_ACTIVATION_PARITY_REMEDIATION_TARGET_GEOMETRY_STATE,
        VCAM_ACTIVATION_PARITY_REMEDIATION_SESSION_STATE,
        VCAM_ACTIVATION_PARITY_REMEDIATION_QUEUE_GENERATION_STATE,
        VCAM_ACTIVATION_PARITY_REMEDIATION_QUEUE_EPOCH_STATE,
        VCAM_ACTIVATION_PARITY_REMEDIATION_ADAPTER_GENERATION_STATE,
        VCAM_ACTIVATION_PARITY_REMEDIATION_ADAPTER_EPOCH_STATE,
        VCAM_ACTIVATION_PARITY_REMEDIATION_PRODUCER_STATE,
        VCAM_ACTIVATION_PARITY_REMEDIATION_DECISION_COUNTS_STATE,
        VCAM_ACTIVATION_PARITY_REMEDIATION_FAIL_COUNTS_STATE,
        VCAM_ACTIVATION_PARITY_REMEDIATION_LAST_DECISION_STATE,
        VCAM_ACTIVATION_PARITY_REMEDIATION_LAST_PREPARED_GEOMETRY_STATE,
        VCAM_ACTIVATION_PARITY_REMEDIATION_STILL_COUNTS_STATE,
        VCAM_ACTIVATION_PARITY_REMEDIATION_STILL_GEOMETRY_STATE,
    };

    for (int i = 0; i < 17; ++i) {
        if (!RegisterToken(
                names[i],
                &gTokens[i])) {
            return;
        }
    }

    int primaryToken = 0;
    if (notify_register_dispatch(
            VCAM_ACTIVATION_PARITY_REMEDIATION_NOTIFICATION,
            &primaryToken,
            dispatch_get_main_queue(),
            ^(int token) {
                ValidateAndPresent(token);
            }) != NOTIFY_STATUS_OK) {
        return;
    }

    gRegistered = true;
    ValidateAndPresent(primaryToken);
}

}  // namespace

__attribute__((constructor))
static void VCAMActivationParityRemediationWitnessInitialize() {
    @autoreleasepool {
        if (IsSpringBoard() &&
            !gRegistered) {
            RegisterWitness();
        }
    }
}
