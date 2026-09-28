#pragma once

#include <stdint.h>

#define VCAM_ACTIVATION_PARITY_REMEDIATION_VERSION     "0.1.0+roothide14~activationremed1"

#define VCAM_ACTIVATION_PARITY_REMEDIATION_NOTIFICATION     "com.vcampro.gate.activation-parity-remediation.001"
#define VCAM_ACTIVATION_PARITY_REMEDIATION_SELECTION_STATE     "com.vcampro.gate.activation-parity-remediation.001.selection"
#define VCAM_ACTIVATION_PARITY_REMEDIATION_PATH_HASH_STATE     "com.vcampro.gate.activation-parity-remediation.001.path-hash"
#define VCAM_ACTIVATION_PARITY_REMEDIATION_CONTROL_STATE     "com.vcampro.gate.activation-parity-remediation.001.control"
#define VCAM_ACTIVATION_PARITY_REMEDIATION_OBSERVED_GEOMETRY_STATE     "com.vcampro.gate.activation-parity-remediation.001.observed-geometry"
#define VCAM_ACTIVATION_PARITY_REMEDIATION_TARGET_GEOMETRY_STATE     "com.vcampro.gate.activation-parity-remediation.001.target-geometry"
#define VCAM_ACTIVATION_PARITY_REMEDIATION_SESSION_STATE     "com.vcampro.gate.activation-parity-remediation.001.session"
#define VCAM_ACTIVATION_PARITY_REMEDIATION_QUEUE_GENERATION_STATE     "com.vcampro.gate.activation-parity-remediation.001.queue-generation"
#define VCAM_ACTIVATION_PARITY_REMEDIATION_QUEUE_EPOCH_STATE     "com.vcampro.gate.activation-parity-remediation.001.queue-epoch"
#define VCAM_ACTIVATION_PARITY_REMEDIATION_ADAPTER_GENERATION_STATE     "com.vcampro.gate.activation-parity-remediation.001.adapter-generation"
#define VCAM_ACTIVATION_PARITY_REMEDIATION_ADAPTER_EPOCH_STATE     "com.vcampro.gate.activation-parity-remediation.001.adapter-epoch"
#define VCAM_ACTIVATION_PARITY_REMEDIATION_PRODUCER_STATE     "com.vcampro.gate.activation-parity-remediation.001.producer"
#define VCAM_ACTIVATION_PARITY_REMEDIATION_DECISION_COUNTS_STATE     "com.vcampro.gate.activation-parity-remediation.001.decision-counts"
#define VCAM_ACTIVATION_PARITY_REMEDIATION_FAIL_COUNTS_STATE     "com.vcampro.gate.activation-parity-remediation.001.fail-counts"
#define VCAM_ACTIVATION_PARITY_REMEDIATION_LAST_DECISION_STATE     "com.vcampro.gate.activation-parity-remediation.001.last-decision"
#define VCAM_ACTIVATION_PARITY_REMEDIATION_LAST_PREPARED_GEOMETRY_STATE     "com.vcampro.gate.activation-parity-remediation.001.last-prepared-geometry"
#define VCAM_ACTIVATION_PARITY_REMEDIATION_STILL_COUNTS_STATE     "com.vcampro.gate.activation-parity-remediation.001.still-counts"
#define VCAM_ACTIVATION_PARITY_REMEDIATION_STILL_GEOMETRY_STATE     "com.vcampro.gate.activation-parity-remediation.001.still-geometry"

#define VCAM_ACTIVATION_PARITY_REMEDIATION_FRESHNESS_SECONDS 180U
#define VCAM_ACTIVATION_PARITY_REMEDIATION_FUTURE_SKEW_SECONDS 5U

#define VCAM_ACTIVATION_CONTROL_ENABLED UINT64_C(0x001)
#define VCAM_ACTIVATION_CONTROL_PHOTO UINT64_C(0x002)
#define VCAM_ACTIVATION_CONTROL_HAS_MEDIA UINT64_C(0x004)
#define VCAM_ACTIVATION_CONTROL_STAGED UINT64_C(0x008)
#define VCAM_ACTIVATION_CONTROL_OBSERVED UINT64_C(0x010)
#define VCAM_ACTIVATION_CONTROL_SELECT_ATTEMPTED UINT64_C(0x020)
#define VCAM_ACTIVATION_CONTROL_SELECT_RESULT UINT64_C(0x040)
#define VCAM_ACTIVATION_CONTROL_START_ATTEMPTED UINT64_C(0x080)
#define VCAM_ACTIVATION_CONTROL_START_RESULT UINT64_C(0x100)
#define VCAM_ACTIVATION_CONTROL_SESSION_INSTALLED UINT64_C(0x200)
#define VCAM_ACTIVATION_CONTROL_QUEUE_BOUND UINT64_C(0x400)

#define VCAM_ACTIVATION_SESSION_EXISTS UINT64_C(0x001)
#define VCAM_ACTIVATION_SESSION_SELECTED_VALID UINT64_C(0x002)
#define VCAM_ACTIVATION_SESSION_SELECTED_PHOTO UINT64_C(0x004)
#define VCAM_ACTIVATION_SESSION_PATH_MATCH UINT64_C(0x008)
#define VCAM_ACTIVATION_SESSION_PRODUCER_HEALTHY UINT64_C(0x010)
#define VCAM_ACTIVATION_SESSION_GEOMETRY_OBSERVED UINT64_C(0x020)

enum class ActivationParityEncodedStage : uint8_t {
    WaitingControl = 0,
    StagingMismatch = 1,
    WaitingGeometry = 2,
    SelectPhotoFailed = 3,
    ProducerStartFailed = 4,
    SessionAbsent = 5,
    ProducerUnavailable = 6,
    QueueEmpty = 7,
    ReconfigurationContended = 8,
    InvalidLease = 9,
    GeometryMismatch = 10,
    BlackFallback = 11,
    PreparedMedia = 12,
    EmergencyOriginal = 13,
};

static inline uint64_t
vcam_activation_remediation_encode_primary(
    uint32_t timestamp,
    uint32_t pid,
    ActivationParityEncodedStage stage)
{
    return
        ((uint64_t)timestamp << 32) |
        ((uint64_t)(pid & UINT32_C(0x000fffff)) << 12) |
        (uint64_t)((uint8_t)stage & UINT8_C(0x0f));
}

static inline uint32_t
vcam_activation_remediation_primary_timestamp(uint64_t state)
{ return (uint32_t)(state >> 32); }

static inline uint32_t
vcam_activation_remediation_primary_pid(uint64_t state)
{ return (uint32_t)((state >> 12) & UINT64_C(0x000fffff)); }

static inline ActivationParityEncodedStage
vcam_activation_remediation_primary_stage(uint64_t state)
{
    return (ActivationParityEncodedStage)(uint8_t)(
        state & UINT64_C(0x0f));
}

static inline uint64_t
vcam_activation_remediation_encode_session(
    uint32_t readyCount,
    uint32_t replacementCount,
    uint8_t playbackIntent,
    uint8_t playbackState,
    uint8_t readerState,
    uint8_t readerError,
    uint64_t flags)
{
    return
        (uint64_t)(readyCount & UINT32_C(0xffff)) |
        ((uint64_t)(replacementCount & UINT32_C(0xff)) << 16) |
        ((uint64_t)(playbackIntent & UINT8_C(0x03)) << 24) |
        ((uint64_t)(playbackState & UINT8_C(0x07)) << 26) |
        ((uint64_t)(readerState & UINT8_C(0x07)) << 29) |
        ((uint64_t)(readerError & UINT8_C(0x07)) << 32) |
        ((flags & UINT64_C(0x3f)) << 40);
}

static inline uint32_t
vcam_activation_remediation_ready_count(uint64_t state)
{ return (uint32_t)(state & UINT64_C(0xffff)); }

static inline uint32_t
vcam_activation_remediation_replacement_count(uint64_t state)
{ return (uint32_t)((state >> 16) & UINT64_C(0xff)); }

static inline uint8_t
vcam_activation_remediation_playback_intent(uint64_t state)
{ return (uint8_t)((state >> 24) & UINT64_C(0x03)); }

static inline uint8_t
vcam_activation_remediation_playback_state(uint64_t state)
{ return (uint8_t)((state >> 26) & UINT64_C(0x07)); }

static inline uint8_t
vcam_activation_remediation_reader_state(uint64_t state)
{ return (uint8_t)((state >> 29) & UINT64_C(0x07)); }

static inline uint8_t
vcam_activation_remediation_reader_error(uint64_t state)
{ return (uint8_t)((state >> 32) & UINT64_C(0x07)); }

static inline uint64_t
vcam_activation_remediation_session_flags(uint64_t state)
{ return (state >> 40) & UINT64_C(0x3f); }

static inline uint64_t
vcam_activation_remediation_encode_producer(
    uint64_t frameSequenceCount,
    bool startAttempted,
    bool startResult)
{
    uint64_t value =
        frameSequenceCount & UINT64_C(0x00ffffffffffffff);
    if (startAttempted) value |= UINT64_C(1) << 62;
    if (startResult) value |= UINT64_C(1) << 63;
    return value;
}

static inline uint64_t
vcam_activation_remediation_frame_sequence_count(uint64_t state)
{ return state & UINT64_C(0x00ffffffffffffff); }

static inline int
vcam_activation_remediation_start_attempted(uint64_t state)
{ return (state & (UINT64_C(1) << 62)) != 0; }

static inline int
vcam_activation_remediation_start_result(uint64_t state)
{ return (state & (UINT64_C(1) << 63)) != 0; }

static inline uint64_t
vcam_activation_remediation_encode_decision_counts(
    uint32_t callbacks,
    uint32_t prepared,
    uint32_t black,
    uint32_t original)
{
    return
        (uint64_t)(callbacks & UINT32_C(0xffff)) |
        ((uint64_t)(prepared & UINT32_C(0xffff)) << 16) |
        ((uint64_t)(black & UINT32_C(0xffff)) << 32) |
        ((uint64_t)(original & UINT32_C(0xffff)) << 48);
}

static inline uint64_t
vcam_activation_remediation_encode_fail_counts(
    uint32_t reconfiguration,
    uint32_t producer,
    uint32_t empty,
    uint32_t invalidLease,
    uint32_t geometryMismatch)
{
    return
        (uint64_t)(reconfiguration & UINT32_C(0x0fff)) |
        ((uint64_t)(producer & UINT32_C(0x0fff)) << 12) |
        ((uint64_t)(empty & UINT32_C(0x0fff)) << 24) |
        ((uint64_t)(invalidLease & UINT32_C(0x0fff)) << 36) |
        ((uint64_t)(geometryMismatch & UINT32_C(0x0fff)) << 48);
}

static inline uint64_t
vcam_activation_remediation_encode_last_decision(
    uint8_t source,
    uint8_t reason)
{
    return
        (uint64_t)(source & UINT8_C(0x03)) |
        ((uint64_t)(reason & UINT8_C(0x0f)) << 2);
}

static inline uint64_t
vcam_activation_remediation_encode_still_counts(
    uint32_t total,
    uint32_t stillPresent,
    uint32_t stillAbsent,
    uint32_t prepared,
    uint32_t black,
    uint32_t original,
    uint32_t commitSuccess,
    uint32_t commitFailure)
{
    return
        (uint64_t)(total & UINT32_C(0xff)) |
        ((uint64_t)(stillPresent & UINT32_C(0xff)) << 8) |
        ((uint64_t)(stillAbsent & UINT32_C(0xff)) << 16) |
        ((uint64_t)(prepared & UINT32_C(0xff)) << 24) |
        ((uint64_t)(black & UINT32_C(0xff)) << 32) |
        ((uint64_t)(original & UINT32_C(0xff)) << 40) |
        ((uint64_t)(commitSuccess & UINT32_C(0xff)) << 48) |
        ((uint64_t)(commitFailure & UINT32_C(0xff)) << 56);
}

static inline int
vcam_activation_remediation_primary_is_valid_fresh(
    uint64_t primary,
    uint64_t selectionGeneration,
    uint32_t now)
{
    const uint32_t timestamp =
        vcam_activation_remediation_primary_timestamp(primary);
    const uint32_t pid =
        vcam_activation_remediation_primary_pid(primary);

    if (timestamp == 0U ||
        pid == 0U ||
        selectionGeneration == UINT64_C(0)) {
        return 0;
    }

    if (timestamp > now) {
        return
            (timestamp - now) <=
            VCAM_ACTIVATION_PARITY_REMEDIATION_FUTURE_SKEW_SECONDS;
    }

    return
        (now - timestamp) <=
        VCAM_ACTIVATION_PARITY_REMEDIATION_FRESHNESS_SECONDS;
}
