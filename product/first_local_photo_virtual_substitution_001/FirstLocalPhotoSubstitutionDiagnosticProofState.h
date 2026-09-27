#pragma once

#include <stdint.h>

#define VCAM_FIRST_PHOTO_SUB_DIAGNOSTIC_VERSION \
    "0.1.0+roothide12~photosubdiag1"

#define VCAM_FIRST_PHOTO_SUB_DIAGNOSTIC_NOTIFICATION \
    "com.vcampro.gate.first-local-photo-substitution-diagnostic.001"
#define VCAM_FIRST_PHOTO_SUB_DIAGNOSTIC_SELECTION_STATE \
    "com.vcampro.gate.first-local-photo-substitution-diagnostic.001.selection"
#define VCAM_FIRST_PHOTO_SUB_DIAGNOSTIC_COUNTS_STATE \
    "com.vcampro.gate.first-local-photo-substitution-diagnostic.001.counts"
#define VCAM_FIRST_PHOTO_SUB_DIAGNOSTIC_FAIL_COUNTS_STATE \
    "com.vcampro.gate.first-local-photo-substitution-diagnostic.001.fail-counts"
#define VCAM_FIRST_PHOTO_SUB_DIAGNOSTIC_OBSERVED_GEOMETRY_STATE \
    "com.vcampro.gate.first-local-photo-substitution-diagnostic.001.observed-geometry"
#define VCAM_FIRST_PHOTO_SUB_DIAGNOSTIC_TARGET_GEOMETRY_STATE \
    "com.vcampro.gate.first-local-photo-substitution-diagnostic.001.target-geometry"
#define VCAM_FIRST_PHOTO_SUB_DIAGNOSTIC_SESSION_STATE \
    "com.vcampro.gate.first-local-photo-substitution-diagnostic.001.session"
#define VCAM_FIRST_PHOTO_SUB_DIAGNOSTIC_LAST_STATE \
    "com.vcampro.gate.first-local-photo-substitution-diagnostic.001.last"

#define VCAM_FIRST_PHOTO_SUB_DIAGNOSTIC_FRESHNESS_SECONDS 180U
#define VCAM_FIRST_PHOTO_SUB_DIAGNOSTIC_FUTURE_SKEW_SECONDS 5U

enum class FirstPhotoSubDiagnosticClassification : uint8_t {
    None = 0,
    NoGenuineCallbackObserved = 1,
    OriginalDisabled = 2,
    OriginalReconfigurationContended = 3,
    OriginalProducerUnavailable = 4,
    OriginalEmptyOrNoEligible = 5,
    OriginalInvalidLease = 6,
    OriginalGeometryMismatch = 7,
    OriginalMixedFailOpen = 8,
    VirtualDecisionObserved = 9,
};

enum class FirstPhotoSubDiagnosticDecision : uint8_t {
    None = 0,
    Original = 1,
    Virtual = 2,
};

enum class FirstPhotoSubDiagnosticReason : uint8_t {
    None = 0,
    Disabled = 1,
    ReconfigurationContended = 2,
    ProducerUnavailable = 3,
    EmptyOrNoEligibleFrame = 4,
    InvalidLease = 5,
    GeometryMismatch = 6,
};

enum class FirstPhotoSubDiagnosticMediaKind : uint8_t {
    None = 0,
    Photo = 1,
    Video = 2,
};

enum class FirstPhotoSubDiagnosticPlaybackState : uint8_t {
    Unknown = 0,
    Empty = 1,
    Ready = 2,
    Playing = 3,
    Paused = 4,
    Ended = 5,
    Failed = 6,
};

#define VCAM_FIRST_PHOTO_SUB_SESSION_VCAM_ENABLED UINT64_C(0x01)
#define VCAM_FIRST_PHOTO_SUB_SESSION_PHOTO_SELECTED UINT64_C(0x02)
#define VCAM_FIRST_PHOTO_SUB_SESSION_PRODUCER_HEALTHY UINT64_C(0x04)
#define VCAM_FIRST_PHOTO_SUB_SESSION_EXISTS UINT64_C(0x08)
#define VCAM_FIRST_PHOTO_SUB_SESSION_SELECTED_VALID UINT64_C(0x10)
#define VCAM_FIRST_PHOTO_SUB_SESSION_SELECTED_PATH_MATCH UINT64_C(0x20)

#define VCAM_FIRST_PHOTO_SUB_LAST_VIRTUAL_NON_NULL UINT64_C(0x20)
#define VCAM_FIRST_PHOTO_SUB_LAST_VIRTUAL_DIFFERENT UINT64_C(0x40)
#define VCAM_FIRST_PHOTO_SUB_LAST_WIDTH_MATCH UINT64_C(0x80)
#define VCAM_FIRST_PHOTO_SUB_LAST_HEIGHT_MATCH UINT64_C(0x100)
#define VCAM_FIRST_PHOTO_SUB_LAST_PIXEL_FORMAT_MATCH UINT64_C(0x200)
#define VCAM_FIRST_PHOTO_SUB_LAST_GEOMETRY_MATCH UINT64_C(0x400)

static inline uint64_t
vcam_first_photo_sub_diag_encode_primary(
    uint32_t timestamp,
    uint32_t pid,
    FirstPhotoSubDiagnosticClassification classification)
{
    return
        ((uint64_t)timestamp << 32) |
        ((uint64_t)(pid & UINT32_C(0x000fffff)) << 12) |
        (uint64_t)((uint8_t)classification & UINT8_C(0x0f));
}

static inline uint32_t
vcam_first_photo_sub_diag_primary_timestamp(uint64_t state)
{
    return (uint32_t)(state >> 32);
}

static inline uint32_t
vcam_first_photo_sub_diag_primary_pid(uint64_t state)
{
    return (uint32_t)((state >> 12) & UINT64_C(0x000fffff));
}

static inline FirstPhotoSubDiagnosticClassification
vcam_first_photo_sub_diag_primary_classification(uint64_t state)
{
    return (FirstPhotoSubDiagnosticClassification)(uint8_t)(
        state & UINT64_C(0x0f));
}

static inline uint64_t
vcam_first_photo_sub_diag_encode_counts(
    uint32_t callbackCount,
    uint32_t decisionCountDelta,
    uint32_t virtualDecisionCountDelta,
    uint32_t decisionVirtualCount,
    uint32_t decisionOriginalCount)
{
    return
        ((uint64_t)(callbackCount & UINT32_C(0xffff))) |
        ((uint64_t)(decisionCountDelta & UINT32_C(0xffff)) << 16) |
        ((uint64_t)(virtualDecisionCountDelta & UINT32_C(0xffff)) << 32) |
        ((uint64_t)(decisionVirtualCount & UINT32_C(0xff)) << 48) |
        ((uint64_t)(decisionOriginalCount & UINT32_C(0xff)) << 56);
}

static inline uint32_t
vcam_first_photo_sub_diag_callback_count(uint64_t state)
{
    return (uint32_t)(state & UINT64_C(0xffff));
}

static inline uint32_t
vcam_first_photo_sub_diag_decision_count_delta(uint64_t state)
{
    return (uint32_t)((state >> 16) & UINT64_C(0xffff));
}

static inline uint32_t
vcam_first_photo_sub_diag_virtual_decision_count_delta(uint64_t state)
{
    return (uint32_t)((state >> 32) & UINT64_C(0xffff));
}

static inline uint32_t
vcam_first_photo_sub_diag_decision_virtual_count(uint64_t state)
{
    return (uint32_t)((state >> 48) & UINT64_C(0xff));
}

static inline uint32_t
vcam_first_photo_sub_diag_decision_original_count(uint64_t state)
{
    return (uint32_t)((state >> 56) & UINT64_C(0xff));
}

static inline uint64_t
vcam_first_photo_sub_diag_encode_fail_counts(
    uint32_t disabled,
    uint32_t reconfigurationContended,
    uint32_t producerUnavailable,
    uint32_t emptyOrNoEligible,
    uint32_t invalidLease,
    uint32_t geometryMismatch,
    uint32_t geometryChangeCount)
{
    return
        ((uint64_t)(disabled & UINT32_C(0xff))) |
        ((uint64_t)(reconfigurationContended & UINT32_C(0xff)) << 8) |
        ((uint64_t)(producerUnavailable & UINT32_C(0xff)) << 16) |
        ((uint64_t)(emptyOrNoEligible & UINT32_C(0xff)) << 24) |
        ((uint64_t)(invalidLease & UINT32_C(0xff)) << 32) |
        ((uint64_t)(geometryMismatch & UINT32_C(0xff)) << 40) |
        ((uint64_t)(geometryChangeCount & UINT32_C(0xffff)) << 48);
}

static inline uint32_t vcam_first_photo_sub_diag_fail_disabled(uint64_t state)
{ return (uint32_t)(state & UINT64_C(0xff)); }
static inline uint32_t vcam_first_photo_sub_diag_fail_reconfiguration(uint64_t state)
{ return (uint32_t)((state >> 8) & UINT64_C(0xff)); }
static inline uint32_t vcam_first_photo_sub_diag_fail_producer(uint64_t state)
{ return (uint32_t)((state >> 16) & UINT64_C(0xff)); }
static inline uint32_t vcam_first_photo_sub_diag_fail_empty(uint64_t state)
{ return (uint32_t)((state >> 24) & UINT64_C(0xff)); }
static inline uint32_t vcam_first_photo_sub_diag_fail_invalid_lease(uint64_t state)
{ return (uint32_t)((state >> 32) & UINT64_C(0xff)); }
static inline uint32_t vcam_first_photo_sub_diag_fail_geometry(uint64_t state)
{ return (uint32_t)((state >> 40) & UINT64_C(0xff)); }
static inline uint32_t vcam_first_photo_sub_diag_geometry_change_count(uint64_t state)
{ return (uint32_t)((state >> 48) & UINT64_C(0xffff)); }

static inline uint64_t
vcam_first_photo_sub_diag_encode_geometry(
    uint32_t width,
    uint32_t height,
    uint32_t pixelFormat)
{
    return
        ((uint64_t)(width & UINT32_C(0xffff))) |
        ((uint64_t)(height & UINT32_C(0xffff)) << 16) |
        ((uint64_t)pixelFormat << 32);
}

static inline uint32_t vcam_first_photo_sub_diag_geometry_width(uint64_t state)
{ return (uint32_t)(state & UINT64_C(0xffff)); }
static inline uint32_t vcam_first_photo_sub_diag_geometry_height(uint64_t state)
{ return (uint32_t)((state >> 16) & UINT64_C(0xffff)); }
static inline uint32_t vcam_first_photo_sub_diag_geometry_pixel_format(uint64_t state)
{ return (uint32_t)(state >> 32); }

static inline uint64_t
vcam_first_photo_sub_diag_encode_session(
    uint32_t readyFrameCount,
    bool vcamEnabled,
    bool photoSelected,
    bool producerHealthy,
    bool sessionExists,
    bool selectedMediaValid,
    bool selectedMediaPathMatch,
    FirstPhotoSubDiagnosticPlaybackState playbackState,
    FirstPhotoSubDiagnosticMediaKind selectedMediaKind)
{
    uint64_t state = (uint64_t)readyFrameCount;
    if (vcamEnabled) state |= VCAM_FIRST_PHOTO_SUB_SESSION_VCAM_ENABLED << 32;
    if (photoSelected) state |= VCAM_FIRST_PHOTO_SUB_SESSION_PHOTO_SELECTED << 32;
    if (producerHealthy) state |= VCAM_FIRST_PHOTO_SUB_SESSION_PRODUCER_HEALTHY << 32;
    if (sessionExists) state |= VCAM_FIRST_PHOTO_SUB_SESSION_EXISTS << 32;
    if (selectedMediaValid) state |= VCAM_FIRST_PHOTO_SUB_SESSION_SELECTED_VALID << 32;
    if (selectedMediaPathMatch) state |= VCAM_FIRST_PHOTO_SUB_SESSION_SELECTED_PATH_MATCH << 32;
    state |= ((uint64_t)((uint8_t)playbackState & UINT8_C(0x07))) << 40;
    state |= ((uint64_t)((uint8_t)selectedMediaKind & UINT8_C(0x03))) << 43;
    return state;
}

static inline uint32_t vcam_first_photo_sub_diag_ready_frame_count(uint64_t state)
{ return (uint32_t)(state & UINT64_C(0xffffffff)); }
static inline int vcam_first_photo_sub_diag_vcam_enabled(uint64_t state)
{ return (state & (VCAM_FIRST_PHOTO_SUB_SESSION_VCAM_ENABLED << 32)) != 0; }
static inline int vcam_first_photo_sub_diag_photo_selected(uint64_t state)
{ return (state & (VCAM_FIRST_PHOTO_SUB_SESSION_PHOTO_SELECTED << 32)) != 0; }
static inline int vcam_first_photo_sub_diag_producer_healthy(uint64_t state)
{ return (state & (VCAM_FIRST_PHOTO_SUB_SESSION_PRODUCER_HEALTHY << 32)) != 0; }
static inline int vcam_first_photo_sub_diag_session_exists(uint64_t state)
{ return (state & (VCAM_FIRST_PHOTO_SUB_SESSION_EXISTS << 32)) != 0; }
static inline int vcam_first_photo_sub_diag_selected_valid(uint64_t state)
{ return (state & (VCAM_FIRST_PHOTO_SUB_SESSION_SELECTED_VALID << 32)) != 0; }
static inline int vcam_first_photo_sub_diag_selected_path_match(uint64_t state)
{ return (state & (VCAM_FIRST_PHOTO_SUB_SESSION_SELECTED_PATH_MATCH << 32)) != 0; }
static inline FirstPhotoSubDiagnosticPlaybackState
vcam_first_photo_sub_diag_playback_state(uint64_t state)
{
    return (FirstPhotoSubDiagnosticPlaybackState)(uint8_t)((state >> 40) & UINT64_C(0x07));
}
static inline FirstPhotoSubDiagnosticMediaKind
vcam_first_photo_sub_diag_selected_media_kind(uint64_t state)
{
    return (FirstPhotoSubDiagnosticMediaKind)(uint8_t)((state >> 43) & UINT64_C(0x03));
}

static inline uint64_t
vcam_first_photo_sub_diag_encode_last(
    FirstPhotoSubDiagnosticDecision decision,
    FirstPhotoSubDiagnosticReason reason,
    bool virtualBufferNonNull,
    bool virtualBufferDifferent,
    bool widthMatch,
    bool heightMatch,
    bool pixelFormatMatch,
    bool geometryMatch)
{
    uint64_t state =
        (uint64_t)((uint8_t)decision & UINT8_C(0x03)) |
        ((uint64_t)((uint8_t)reason & UINT8_C(0x07)) << 2);
    if (virtualBufferNonNull) state |= VCAM_FIRST_PHOTO_SUB_LAST_VIRTUAL_NON_NULL;
    if (virtualBufferDifferent) state |= VCAM_FIRST_PHOTO_SUB_LAST_VIRTUAL_DIFFERENT;
    if (widthMatch) state |= VCAM_FIRST_PHOTO_SUB_LAST_WIDTH_MATCH;
    if (heightMatch) state |= VCAM_FIRST_PHOTO_SUB_LAST_HEIGHT_MATCH;
    if (pixelFormatMatch) state |= VCAM_FIRST_PHOTO_SUB_LAST_PIXEL_FORMAT_MATCH;
    if (geometryMatch) state |= VCAM_FIRST_PHOTO_SUB_LAST_GEOMETRY_MATCH;
    return state;
}

static inline FirstPhotoSubDiagnosticDecision
vcam_first_photo_sub_diag_last_decision(uint64_t state)
{
    return (FirstPhotoSubDiagnosticDecision)(uint8_t)(state & UINT64_C(0x03));
}
static inline FirstPhotoSubDiagnosticReason
vcam_first_photo_sub_diag_last_reason(uint64_t state)
{
    return (FirstPhotoSubDiagnosticReason)(uint8_t)((state >> 2) & UINT64_C(0x07));
}
static inline int vcam_first_photo_sub_diag_virtual_non_null(uint64_t state)
{ return (state & VCAM_FIRST_PHOTO_SUB_LAST_VIRTUAL_NON_NULL) != 0; }
static inline int vcam_first_photo_sub_diag_virtual_different(uint64_t state)
{ return (state & VCAM_FIRST_PHOTO_SUB_LAST_VIRTUAL_DIFFERENT) != 0; }
static inline int vcam_first_photo_sub_diag_width_match(uint64_t state)
{ return (state & VCAM_FIRST_PHOTO_SUB_LAST_WIDTH_MATCH) != 0; }
static inline int vcam_first_photo_sub_diag_height_match(uint64_t state)
{ return (state & VCAM_FIRST_PHOTO_SUB_LAST_HEIGHT_MATCH) != 0; }
static inline int vcam_first_photo_sub_diag_pixel_format_match(uint64_t state)
{ return (state & VCAM_FIRST_PHOTO_SUB_LAST_PIXEL_FORMAT_MATCH) != 0; }
static inline int vcam_first_photo_sub_diag_geometry_match(uint64_t state)
{ return (state & VCAM_FIRST_PHOTO_SUB_LAST_GEOMETRY_MATCH) != 0; }

static inline int
vcam_first_photo_sub_diag_primary_is_valid_fresh(
    uint64_t primaryState,
    uint64_t selectionGeneration,
    uint32_t now)
{
    const uint32_t timestamp =
        vcam_first_photo_sub_diag_primary_timestamp(primaryState);
    const uint32_t pid =
        vcam_first_photo_sub_diag_primary_pid(primaryState);
    const FirstPhotoSubDiagnosticClassification classification =
        vcam_first_photo_sub_diag_primary_classification(primaryState);

    if (timestamp == 0U ||
        pid == 0U ||
        selectionGeneration == UINT64_C(0) ||
        classification == FirstPhotoSubDiagnosticClassification::None) {
        return 0;
    }

    if (timestamp > now) {
        return
            (timestamp - now) <=
            VCAM_FIRST_PHOTO_SUB_DIAGNOSTIC_FUTURE_SKEW_SECONDS;
    }

    return
        (now - timestamp) <=
        VCAM_FIRST_PHOTO_SUB_DIAGNOSTIC_FRESHNESS_SECONDS;
}
