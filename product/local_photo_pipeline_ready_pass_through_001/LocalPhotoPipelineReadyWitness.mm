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

int gSelectionToken = -1;
int gFlagsToken = -1;
int gEnumsToken = -1;
int gCountsToken = -1;

bool gAcceptedProof = false;
bool gBannerPresented = false;
NSInteger gPresentationAttempts = 0;
UIView* gPhotoReadyBanner = nil;
NSString* gAcceptedText = nil;

bool IsSpringBoard() noexcept {
    const char* process = getprogname();
    return process != nullptr &&
           strcmp(process, "SpringBoard") == 0;
}

NSString* YesNo(bool value) {
    return value ? @"YES" : @"NO";
}

NSString* MediaKindText(
    LocalPhotoProofMediaKind value) {
    switch (value) {
        case LocalPhotoProofMediaKind::Photo:
            return @"PHOTO";
        case LocalPhotoProofMediaKind::Video:
            return @"VIDEO";
        case LocalPhotoProofMediaKind::None:
        default:
            return @"NONE";
    }
}

NSString* PlaybackIntentText(
    LocalPhotoProofPlaybackIntent value) {
    switch (value) {
        case LocalPhotoProofPlaybackIntent::Playing:
            return @"PLAYING";
        case LocalPhotoProofPlaybackIntent::Paused:
            return @"PAUSED";
        case LocalPhotoProofPlaybackIntent::Stopped:
        default:
            return @"STOPPED";
    }
}

NSString* PlaybackStateText(
    LocalPhotoProofPlaybackState value) {
    switch (value) {
        case LocalPhotoProofPlaybackState::Empty:
            return @"EMPTY";
        case LocalPhotoProofPlaybackState::Ready:
            return @"READY";
        case LocalPhotoProofPlaybackState::Playing:
            return @"PLAYING";
        case LocalPhotoProofPlaybackState::Paused:
            return @"PAUSED";
        case LocalPhotoProofPlaybackState::Ended:
            return @"ENDED";
        case LocalPhotoProofPlaybackState::Failed:
            return @"FAILED";
        case LocalPhotoProofPlaybackState::Unknown:
        default:
            return @"UNKNOWN";
    }
}

NSString* PipelineStageText(
    LocalPhotoProofPipelineStage value) {
    switch (value) {
        case LocalPhotoProofPipelineStage::WaitingControl:
            return @"WAITING_CONTROL";
        case LocalPhotoProofPipelineStage::WaitingGeometry:
            return @"WAITING_GEOMETRY";
        case LocalPhotoProofPipelineStage::SessionAbsent:
            return @"SESSION_ABSENT";
        case LocalPhotoProofPipelineStage::PhotoSelectFailed:
            return @"PHOTO_SELECT_FAILED";
        case LocalPhotoProofPipelineStage::ProducerStartFailed:
            return @"PRODUCER_START_FAILED";
        case LocalPhotoProofPipelineStage::WaitingProducer:
            return @"WAITING_PRODUCER";
        case LocalPhotoProofPipelineStage::WaitingReadyFrame:
            return @"WAITING_READY_FRAME";
        case LocalPhotoProofPipelineStage::WaitingCallback:
            return @"WAITING_CALLBACK";
        case LocalPhotoProofPipelineStage::Ready:
            return @"READY";
        case LocalPhotoProofPipelineStage::ControlSuperseded:
            return @"CONTROL_SUPERSEDED";
        case LocalPhotoProofPipelineStage::VcamUnexpectedlyEnabled:
            return @"VCAM_UNEXPECTEDLY_ENABLED";
        case LocalPhotoProofPipelineStage::MediaStagingMismatch:
            return @"MEDIA_STAGING_MISMATCH";
        case LocalPhotoProofPipelineStage::SelectedMediaMismatch:
            return @"SELECTED_MEDIA_MISMATCH";
        default:
            return @"UNKNOWN";
    }
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
        MAX(window.safeAreaInsets.top + 6.0, 28.0);
    const CGFloat maxHeight =
        MAX(240.0, bounds.size.height - top - 12.0);
    const CGFloat bannerHeight =
        MIN(610.0, maxHeight);
    const CGFloat width =
        MAX(1.0, bounds.size.width - (horizontalInset * 2.0));

    UIView* banner =
        [[UIView alloc] initWithFrame:
            CGRectMake(horizontalInset, top, width, bannerHeight)];
    banner.backgroundColor =
        [UIColor colorWithWhite:0.10 alpha:0.98];
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
    label.textAlignment = NSTextAlignmentLeft;
    label.font =
        [UIFont monospacedSystemFontOfSize:9.2
                                   weight:UIFontWeightSemibold];
    label.numberOfLines = 0;
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.75;
    label.text = gAcceptedText;
    label.accessibilityLabel = gAcceptedText;

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
        gAcceptedText == nil) {
        return;
    }

    ++gPresentationAttempts;

    UIWindow* window = FindExistingSpringBoardWindow();
    if (window != nil) {
        AttachVisibleProof(window);
    }

    if (!gBannerPresented) {
        ScheduleVisibleRetry();
    }
}

bool ReadStateToken(
    int token,
    uint64_t* state) {
    return
        token >= 0 &&
        state != nullptr &&
        notify_get_state(
            token,
            state) == NOTIFY_STATUS_OK;
}

void ValidateTokenState(int eventToken) {
    uint64_t eventState = 0;
    uint64_t selectionGeneration = 0;
    uint64_t flags = 0;
    uint64_t enumsState = 0;
    uint64_t countsState = 0;

    if (!ReadStateToken(eventToken, &eventState) ||
        !ReadStateToken(gSelectionToken, &selectionGeneration) ||
        !ReadStateToken(gFlagsToken, &flags) ||
        !ReadStateToken(gEnumsToken, &enumsState) ||
        !ReadStateToken(gCountsToken, &countsState)) {
        return;
    }

    const time_t nowValue = time(nullptr);
    if (nowValue < 0 ||
        static_cast<uint64_t>(nowValue) > UINT32_MAX ||
        !vcam_local_photo_pipeline_ready_event_is_valid_fresh(
            eventState,
            static_cast<uint32_t>(nowValue)) ||
        selectionGeneration == UINT64_C(0)) {
        return;
    }

    const LocalPhotoProofResult result =
        vcam_local_photo_pipeline_ready_event_result(eventState);
    const LocalPhotoProofPipelineStage stage =
        vcam_local_photo_pipeline_ready_event_stage(eventState);

    if (result == LocalPhotoProofResult::Pass &&
        !vcam_local_photo_pipeline_ready_structured_pass_is_valid(
            eventState,
            selectionGeneration,
            flags,
            enumsState,
            countsState)) {
        return;
    }

    const uint32_t pid =
        vcam_local_photo_pipeline_ready_event_pid(eventState);
    const LocalPhotoProofMediaKind mediaKind =
        vcam_local_photo_pipeline_ready_media_kind(enumsState);
    const LocalPhotoProofMediaKind selectedMediaKind =
        vcam_local_photo_pipeline_ready_selected_media_kind(enumsState);
    const LocalPhotoProofPlaybackIntent playbackIntent =
        vcam_local_photo_pipeline_ready_playback_intent(enumsState);
    const LocalPhotoProofPlaybackState playbackState =
        vcam_local_photo_pipeline_ready_playback_state(enumsState);
    const uint32_t readyFrameCount =
        vcam_local_photo_pipeline_ready_ready_frame_count(countsState);
    const uint32_t virtualDecisionCount =
        vcam_local_photo_pipeline_ready_virtual_decision_count(countsState);

    const bool vcamEnabled =
        (flags & VCAM_LOCAL_PHOTO_FLAG_VCAM_ENABLED) != 0;
    const bool mediaStaged =
        (flags & VCAM_LOCAL_PHOTO_FLAG_MEDIA_STAGED) != 0;
    const bool controlObserved =
        (flags & VCAM_LOCAL_PHOTO_FLAG_CONTROL_OBSERVED) != 0;
    const bool geometryObserved =
        (flags & VCAM_LOCAL_PHOTO_FLAG_GEOMETRY_OBSERVED) != 0;
    const bool sessionExists =
        (flags & VCAM_LOCAL_PHOTO_FLAG_SESSION_EXISTS) != 0;
    const bool selectedValid =
        (flags & VCAM_LOCAL_PHOTO_FLAG_SELECTED_MEDIA_VALID) != 0;
    const bool selectedPathMatch =
        (flags & VCAM_LOCAL_PHOTO_FLAG_SELECTED_PATH_MATCH) != 0;
    const bool producerReady =
        (flags & VCAM_LOCAL_PHOTO_FLAG_PRODUCER_READY) != 0;
    const bool callbackExercised =
        (flags & VCAM_LOCAL_PHOTO_FLAG_CALLBACK_EXERCISED) != 0;
    const bool decisionOriginal =
        (flags & VCAM_LOCAL_PHOTO_FLAG_DECISION_ORIGINAL) != 0;
    const bool originalReturned =
        (flags & VCAM_LOCAL_PHOTO_FLAG_ORIGINAL_RETURNED) != 0;
    const bool substitutionInactive =
        (flags & VCAM_LOCAL_PHOTO_FLAG_SUBSTITUTION_INACTIVE) != 0;

    NSString* header =
        result == LocalPhotoProofResult::Pass
            ? @"VCAM LOCAL PHOTO PIPELINE READY PASS"
            : @"VCAM LOCAL PHOTO PIPELINE DIAGNOSTIC";

    NSString* text =
        [NSString stringWithFormat:
            @"%@\n"
             "vcam-enabled=%@\n"
             "media-kind=%@\n"
             "selection-generation=%llu\n"
             "media-staged=%@\n"
             "control-state-observed=%@\n"
             "camera-geometry-observed=%@\n"
             "session-exists=%@\n"
             "selected-media-valid=%@\n"
             "selected-media-kind=%@\n"
             "selected-media-path-match=%@\n"
             "playback-intent=%@\n"
             "playback-state=%@\n"
             "producer-ready=%@\n"
             "ready-frame-count=%u\n"
             "camera-callback-exercised=%@\n"
             "decision-original=%@\n"
             "original-buffer-returned=%@\n"
             "virtual-decision-count=%u\n"
             "frame-substitution-inactive=%@\n"
             "pipeline-stage=%@\n"
             "pid=%u",
            header,
            YesNo(vcamEnabled),
            MediaKindText(mediaKind),
            static_cast<unsigned long long>(selectionGeneration),
            YesNo(mediaStaged),
            YesNo(controlObserved),
            YesNo(geometryObserved),
            YesNo(sessionExists),
            YesNo(selectedValid),
            MediaKindText(selectedMediaKind),
            YesNo(selectedPathMatch),
            PlaybackIntentText(playbackIntent),
            PlaybackStateText(playbackState),
            YesNo(producerReady),
            readyFrameCount,
            YesNo(callbackExercised),
            YesNo(decisionOriginal),
            YesNo(originalReturned),
            virtualDecisionCount,
            YesNo(substitutionInactive),
            PipelineStageText(stage),
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

bool RegisterStateToken(
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

void RegisterWitness() {
    if (!IsSpringBoard() ||
        !RegisterStateToken(
            VCAM_LOCAL_PHOTO_PIPELINE_READY_SELECTION_STATE,
            &gSelectionToken) ||
        !RegisterStateToken(
            VCAM_LOCAL_PHOTO_PIPELINE_READY_FLAGS_STATE,
            &gFlagsToken) ||
        !RegisterStateToken(
            VCAM_LOCAL_PHOTO_PIPELINE_READY_ENUMS_STATE,
            &gEnumsToken) ||
        !RegisterStateToken(
            VCAM_LOCAL_PHOTO_PIPELINE_READY_COUNTS_STATE,
            &gCountsToken)) {
        return;
    }

    int eventToken = 0;
    const uint32_t status =
        notify_register_dispatch(
            VCAM_LOCAL_PHOTO_PIPELINE_READY_NOTIFICATION,
            &eventToken,
            dispatch_get_main_queue(),
            ^(int incomingToken) {
                ValidateTokenState(incomingToken);
            });

    if (status != NOTIFY_STATUS_OK) {
        return;
    }

    ValidateTokenState(eventToken);
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
