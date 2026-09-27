#pragma once

#include <stdint.h>

#define VCAM_LOCAL_PHOTO_PIPELINE_READY_VERSION \
    "0.1.0+roothide10~photoready2"

#define VCAM_LOCAL_PHOTO_PIPELINE_READY_NOTIFICATION \
    "com.vcampro.gate.local-photo-pipeline-ready.remediation-a.001"
#define VCAM_LOCAL_PHOTO_PIPELINE_READY_SELECTION_STATE \
    "com.vcampro.gate.local-photo-pipeline-ready.remediation-a.001.selection"
#define VCAM_LOCAL_PHOTO_PIPELINE_READY_FLAGS_STATE \
    "com.vcampro.gate.local-photo-pipeline-ready.remediation-a.001.flags"
#define VCAM_LOCAL_PHOTO_PIPELINE_READY_ENUMS_STATE \
    "com.vcampro.gate.local-photo-pipeline-ready.remediation-a.001.enums"
#define VCAM_LOCAL_PHOTO_PIPELINE_READY_COUNTS_STATE \
    "com.vcampro.gate.local-photo-pipeline-ready.remediation-a.001.counts"

#define VCAM_LOCAL_PHOTO_PIPELINE_READY_FRESHNESS_SECONDS 180U
#define VCAM_LOCAL_PHOTO_PIPELINE_READY_FUTURE_SKEW_SECONDS 5U

enum class LocalPhotoProofResult : uint8_t {
    None = 0,
    Pass = 1,
    Diagnostic = 2,
};

enum class LocalPhotoProofMediaKind : uint8_t {
    None = 0,
    Photo = 1,
    Video = 2,
};

enum class LocalPhotoProofPlaybackIntent : uint8_t {
    Stopped = 0,
    Playing = 1,
    Paused = 2,
};

enum class LocalPhotoProofPlaybackState : uint8_t {
    Unknown = 0,
    Empty = 1,
    Ready = 2,
    Playing = 3,
    Paused = 4,
    Ended = 5,
    Failed = 6,
};

enum class LocalPhotoProofPipelineStage : uint8_t {
    WaitingControl = 0,
    WaitingGeometry = 1,
    SessionAbsent = 2,
    PhotoSelectFailed = 3,
    ProducerStartFailed = 4,
    WaitingProducer = 5,
    WaitingReadyFrame = 6,
    WaitingCallback = 7,
    Ready = 8,
    ControlSuperseded = 9,
    VcamUnexpectedlyEnabled = 10,
    MediaStagingMismatch = 11,
    SelectedMediaMismatch = 12,
};

#define VCAM_LOCAL_PHOTO_FLAG_VCAM_ENABLED UINT64_C(0x0001)
#define VCAM_LOCAL_PHOTO_FLAG_HAS_MEDIA UINT64_C(0x0002)
#define VCAM_LOCAL_PHOTO_FLAG_MEDIA_STAGED UINT64_C(0x0004)
#define VCAM_LOCAL_PHOTO_FLAG_CONTROL_OBSERVED UINT64_C(0x0008)
#define VCAM_LOCAL_PHOTO_FLAG_GEOMETRY_OBSERVED UINT64_C(0x0010)
#define VCAM_LOCAL_PHOTO_FLAG_SESSION_EXISTS UINT64_C(0x0020)
#define VCAM_LOCAL_PHOTO_FLAG_SELECTED_MEDIA_VALID UINT64_C(0x0040)
#define VCAM_LOCAL_PHOTO_FLAG_SELECTED_PATH_MATCH UINT64_C(0x0080)
#define VCAM_LOCAL_PHOTO_FLAG_PRODUCER_READY UINT64_C(0x0100)
#define VCAM_LOCAL_PHOTO_FLAG_CALLBACK_EXERCISED UINT64_C(0x0200)
#define VCAM_LOCAL_PHOTO_FLAG_DECISION_ORIGINAL UINT64_C(0x0400)
#define VCAM_LOCAL_PHOTO_FLAG_ORIGINAL_RETURNED UINT64_C(0x0800)
#define VCAM_LOCAL_PHOTO_FLAG_DISABLED_REASON UINT64_C(0x1000)
#define VCAM_LOCAL_PHOTO_FLAG_SUBSTITUTION_INACTIVE UINT64_C(0x2000)
#define VCAM_LOCAL_PHOTO_FLAG_ORIGINAL_NON_NULL UINT64_C(0x4000)

static inline uint64_t
vcam_local_photo_pipeline_ready_encode_event(
    uint32_t timestamp,
    uint32_t pid,
    LocalPhotoProofResult result,
    LocalPhotoProofPipelineStage stage)
{
    return
        ((uint64_t)timestamp << 32) |
        ((uint64_t)(pid & UINT32_C(0x000fffff)) << 12) |
        ((uint64_t)((uint8_t)stage & UINT8_C(0x3f)) << 2) |
        (uint64_t)((uint8_t)result & UINT8_C(0x03));
}

static inline uint32_t
vcam_local_photo_pipeline_ready_event_timestamp(
    uint64_t state)
{
    return (uint32_t)(state >> 32);
}

static inline uint32_t
vcam_local_photo_pipeline_ready_event_pid(
    uint64_t state)
{
    return (uint32_t)((state >> 12) & UINT64_C(0x000fffff));
}

static inline LocalPhotoProofResult
vcam_local_photo_pipeline_ready_event_result(
    uint64_t state)
{
    return (LocalPhotoProofResult)(uint8_t)(state & UINT64_C(0x03));
}

static inline LocalPhotoProofPipelineStage
vcam_local_photo_pipeline_ready_event_stage(
    uint64_t state)
{
    return (LocalPhotoProofPipelineStage)(uint8_t)((state >> 2) & UINT64_C(0x3f));
}

static inline uint64_t
vcam_local_photo_pipeline_ready_encode_enums(
    LocalPhotoProofMediaKind mediaKind,
    LocalPhotoProofMediaKind selectedMediaKind,
    LocalPhotoProofPlaybackIntent playbackIntent,
    LocalPhotoProofPlaybackState playbackState)
{
    return
        ((uint64_t)((uint8_t)mediaKind & UINT8_C(0x03))) |
        ((uint64_t)((uint8_t)selectedMediaKind & UINT8_C(0x03)) << 2) |
        ((uint64_t)((uint8_t)playbackIntent & UINT8_C(0x03)) << 4) |
        ((uint64_t)((uint8_t)playbackState & UINT8_C(0x07)) << 6);
}

static inline LocalPhotoProofMediaKind
vcam_local_photo_pipeline_ready_media_kind(
    uint64_t state)
{
    return (LocalPhotoProofMediaKind)(uint8_t)(state & UINT64_C(0x03));
}

static inline LocalPhotoProofMediaKind
vcam_local_photo_pipeline_ready_selected_media_kind(
    uint64_t state)
{
    return (LocalPhotoProofMediaKind)(uint8_t)((state >> 2) & UINT64_C(0x03));
}

static inline LocalPhotoProofPlaybackIntent
vcam_local_photo_pipeline_ready_playback_intent(
    uint64_t state)
{
    return (LocalPhotoProofPlaybackIntent)(uint8_t)((state >> 4) & UINT64_C(0x03));
}

static inline LocalPhotoProofPlaybackState
vcam_local_photo_pipeline_ready_playback_state(
    uint64_t state)
{
    return (LocalPhotoProofPlaybackState)(uint8_t)((state >> 6) & UINT64_C(0x07));
}

static inline uint64_t
vcam_local_photo_pipeline_ready_encode_counts(
    uint64_t readyFrameCount,
    uint64_t virtualDecisionCount)
{
    const uint64_t ready =
        readyFrameCount > UINT32_MAX ? UINT32_MAX : readyFrameCount;
    const uint64_t virtualCount =
        virtualDecisionCount > UINT32_MAX ? UINT32_MAX : virtualDecisionCount;

    return
        (virtualCount << 32) |
        ready;
}

static inline uint32_t
vcam_local_photo_pipeline_ready_ready_frame_count(
    uint64_t state)
{
    return (uint32_t)(state & UINT64_C(0xffffffff));
}

static inline uint32_t
vcam_local_photo_pipeline_ready_virtual_decision_count(
    uint64_t state)
{
    return (uint32_t)(state >> 32);
}

static inline int
vcam_local_photo_pipeline_ready_event_is_valid_fresh(
    uint64_t eventState,
    uint32_t now)
{
    const uint32_t timestamp =
        vcam_local_photo_pipeline_ready_event_timestamp(eventState);
    const uint32_t pid =
        vcam_local_photo_pipeline_ready_event_pid(eventState);
    const LocalPhotoProofResult result =
        vcam_local_photo_pipeline_ready_event_result(eventState);

    if (timestamp == 0U ||
        pid == 0U ||
        (result != LocalPhotoProofResult::Pass &&
         result != LocalPhotoProofResult::Diagnostic)) {
        return 0;
    }

    if (timestamp > now) {
        return
            (timestamp - now) <=
            VCAM_LOCAL_PHOTO_PIPELINE_READY_FUTURE_SKEW_SECONDS;
    }

    return
        (now - timestamp) <=
        VCAM_LOCAL_PHOTO_PIPELINE_READY_FRESHNESS_SECONDS;
}

static inline int
vcam_local_photo_pipeline_ready_structured_pass_is_valid(
    uint64_t eventState,
    uint64_t selectionGeneration,
    uint64_t flags,
    uint64_t enumsState,
    uint64_t countsState)
{
    const uint64_t required =
        VCAM_LOCAL_PHOTO_FLAG_HAS_MEDIA |
        VCAM_LOCAL_PHOTO_FLAG_MEDIA_STAGED |
        VCAM_LOCAL_PHOTO_FLAG_CONTROL_OBSERVED |
        VCAM_LOCAL_PHOTO_FLAG_GEOMETRY_OBSERVED |
        VCAM_LOCAL_PHOTO_FLAG_SESSION_EXISTS |
        VCAM_LOCAL_PHOTO_FLAG_SELECTED_MEDIA_VALID |
        VCAM_LOCAL_PHOTO_FLAG_SELECTED_PATH_MATCH |
        VCAM_LOCAL_PHOTO_FLAG_PRODUCER_READY |
        VCAM_LOCAL_PHOTO_FLAG_CALLBACK_EXERCISED |
        VCAM_LOCAL_PHOTO_FLAG_DECISION_ORIGINAL |
        VCAM_LOCAL_PHOTO_FLAG_ORIGINAL_RETURNED |
        VCAM_LOCAL_PHOTO_FLAG_DISABLED_REASON |
        VCAM_LOCAL_PHOTO_FLAG_SUBSTITUTION_INACTIVE |
        VCAM_LOCAL_PHOTO_FLAG_ORIGINAL_NON_NULL;

    if (vcam_local_photo_pipeline_ready_event_result(eventState) !=
            LocalPhotoProofResult::Pass ||
        vcam_local_photo_pipeline_ready_event_stage(eventState) !=
            LocalPhotoProofPipelineStage::Ready ||
        selectionGeneration == UINT64_C(0) ||
        (flags & VCAM_LOCAL_PHOTO_FLAG_VCAM_ENABLED) != 0 ||
        (flags & required) != required) {
        return 0;
    }

    return
        vcam_local_photo_pipeline_ready_media_kind(enumsState) ==
            LocalPhotoProofMediaKind::Photo &&
        vcam_local_photo_pipeline_ready_selected_media_kind(enumsState) ==
            LocalPhotoProofMediaKind::Photo &&
        vcam_local_photo_pipeline_ready_playback_intent(enumsState) ==
            LocalPhotoProofPlaybackIntent::Playing &&
        vcam_local_photo_pipeline_ready_playback_state(enumsState) ==
            LocalPhotoProofPlaybackState::Playing &&
        vcam_local_photo_pipeline_ready_ready_frame_count(countsState) > 0 &&
        vcam_local_photo_pipeline_ready_virtual_decision_count(countsState) == 0;
}
