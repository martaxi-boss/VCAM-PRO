#include "ActivationParityDeviceRemediationProof.h"
#include "ActivationParityDeviceRemediationProofState.h"

#include <dispatch/dispatch.h>
#include <notify.h>
#include <time.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cstdint>

namespace vcam::product::proof {

namespace {

std::atomic<std::uint64_t> gActiveGeneration{0};

std::atomic<std::uint32_t> gDecisionCallbacks{0};
std::atomic<std::uint32_t> gPreparedDecisions{0};
std::atomic<std::uint32_t> gBlackDecisions{0};
std::atomic<std::uint32_t> gOriginalDecisions{0};

std::atomic<std::uint32_t> gFailReconfiguration{0};
std::atomic<std::uint32_t> gFailProducer{0};
std::atomic<std::uint32_t> gFailEmpty{0};
std::atomic<std::uint32_t> gFailInvalidLease{0};
std::atomic<std::uint32_t> gFailGeometry{0};

std::atomic<std::uint32_t> gLastSource{0};
std::atomic<std::uint32_t> gLastReason{0};
std::atomic<std::uint64_t> gLastOriginalGeometry{0};
std::atomic<std::uint64_t> gLastPreparedGeometry{0};

std::atomic<std::uint32_t> gHookTotal{0};
std::atomic<std::uint32_t> gStillPresent{0};
std::atomic<std::uint32_t> gStillAbsent{0};
std::atomic<std::uint32_t> gStillPrepared{0};
std::atomic<std::uint32_t> gStillBlack{0};
std::atomic<std::uint32_t> gStillOriginal{0};
std::atomic<std::uint32_t> gCommitSuccess{0};
std::atomic<std::uint32_t> gCommitFailure{0};
std::atomic<std::uint64_t> gStillGeometry{0};

int gPrimaryToken = -1;
int gSelectionToken = -1;
int gPathHashToken = -1;
int gControlToken = -1;
int gObservedGeometryToken = -1;
int gTargetGeometryToken = -1;
int gSessionToken = -1;
int gQueueGenerationToken = -1;
int gQueueEpochToken = -1;
int gAdapterGenerationToken = -1;
int gAdapterEpochToken = -1;
int gProducerToken = -1;
int gDecisionCountsToken = -1;
int gFailCountsToken = -1;
int gLastDecisionToken = -1;
int gLastPreparedGeometryToken = -1;
int gStillCountsToken = -1;
int gStillGeometryToken = -1;

template <typename T>
void SaturatingIncrement(
    std::atomic<T>& value) noexcept {
    T current =
        value.load(
            std::memory_order_acquire);

    while (current !=
           std::numeric_limits<T>::max()) {
        if (value.compare_exchange_weak(
                current,
                static_cast<T>(current + 1),
                std::memory_order_acq_rel,
                std::memory_order_acquire)) {
            return;
        }
    }
}

std::uint64_t GeometryKey(
    CVPixelBufferRef buffer) noexcept {
    if (buffer == nullptr) {
        return 0;
    }

    const std::size_t width =
        CVPixelBufferGetWidth(buffer);
    const std::size_t height =
        CVPixelBufferGetHeight(buffer);
    const OSType format =
        CVPixelBufferGetPixelFormatType(
            buffer);

    if (width > 0xffffU ||
        height > 0xffffU) {
        return 0;
    }

    return
        static_cast<std::uint64_t>(width) |
        (static_cast<std::uint64_t>(height) << 16U) |
        (static_cast<std::uint64_t>(format) << 32U);
}

bool RegisterStateToken(
    const char* name,
    int* token) noexcept {
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

void CancelToken(
    int* token) noexcept {
    if (token != nullptr &&
        *token >= 0) {
        (void)notify_cancel(*token);
        *token = -1;
    }
}

void ResetCounters() noexcept {
    gDecisionCallbacks.store(0, std::memory_order_release);
    gPreparedDecisions.store(0, std::memory_order_release);
    gBlackDecisions.store(0, std::memory_order_release);
    gOriginalDecisions.store(0, std::memory_order_release);

    gFailReconfiguration.store(0, std::memory_order_release);
    gFailProducer.store(0, std::memory_order_release);
    gFailEmpty.store(0, std::memory_order_release);
    gFailInvalidLease.store(0, std::memory_order_release);
    gFailGeometry.store(0, std::memory_order_release);

    gLastSource.store(
        static_cast<std::uint32_t>(
            CameraDecisionSource::Original),
        std::memory_order_release);
    gLastReason.store(
        static_cast<std::uint32_t>(
            CameraFailOpenReason::None),
        std::memory_order_release);
    gLastOriginalGeometry.store(0, std::memory_order_release);
    gLastPreparedGeometry.store(0, std::memory_order_release);

    gHookTotal.store(0, std::memory_order_release);
    gStillPresent.store(0, std::memory_order_release);
    gStillAbsent.store(0, std::memory_order_release);
    gStillPrepared.store(0, std::memory_order_release);
    gStillBlack.store(0, std::memory_order_release);
    gStillOriginal.store(0, std::memory_order_release);
    gCommitSuccess.store(0, std::memory_order_release);
    gCommitFailure.store(0, std::memory_order_release);
    gStillGeometry.store(0, std::memory_order_release);
}

void ClearTransport() noexcept {
    int* tokens[] = {
        &gPrimaryToken,
        &gSelectionToken,
        &gPathHashToken,
        &gControlToken,
        &gObservedGeometryToken,
        &gTargetGeometryToken,
        &gSessionToken,
        &gQueueGenerationToken,
        &gQueueEpochToken,
        &gAdapterGenerationToken,
        &gAdapterEpochToken,
        &gProducerToken,
        &gDecisionCountsToken,
        &gFailCountsToken,
        &gLastDecisionToken,
        &gLastPreparedGeometryToken,
        &gStillCountsToken,
        &gStillGeometryToken,
    };

    for (int* token : tokens) {
        if (*token >= 0) {
            (void)notify_set_state(
                *token,
                UINT64_C(0));
        }
    }
}

ActivationParityEncodedStage EncodedStage(
    ActivationParityPhotoStage stage) noexcept {
    return
        static_cast<ActivationParityEncodedStage>(
            static_cast<std::uint8_t>(stage));
}

}  // namespace

void ResetActivationParityDeviceRemediationProof() noexcept {
    gActiveGeneration.store(0, std::memory_order_release);
    ResetCounters();

    int* tokens[] = {
        &gPrimaryToken,
        &gSelectionToken,
        &gPathHashToken,
        &gControlToken,
        &gObservedGeometryToken,
        &gTargetGeometryToken,
        &gSessionToken,
        &gQueueGenerationToken,
        &gQueueEpochToken,
        &gAdapterGenerationToken,
        &gAdapterEpochToken,
        &gProducerToken,
        &gDecisionCountsToken,
        &gFailCountsToken,
        &gLastDecisionToken,
        &gLastPreparedGeometryToken,
        &gStillCountsToken,
        &gStillGeometryToken,
    };
    for (int* token : tokens) {
        CancelToken(token);
    }

    const struct {
        const char* name;
        int* token;
    } registrations[] = {
        {VCAM_ACTIVATION_PARITY_REMEDIATION_NOTIFICATION, &gPrimaryToken},
        {VCAM_ACTIVATION_PARITY_REMEDIATION_SELECTION_STATE, &gSelectionToken},
        {VCAM_ACTIVATION_PARITY_REMEDIATION_PATH_HASH_STATE, &gPathHashToken},
        {VCAM_ACTIVATION_PARITY_REMEDIATION_CONTROL_STATE, &gControlToken},
        {VCAM_ACTIVATION_PARITY_REMEDIATION_OBSERVED_GEOMETRY_STATE, &gObservedGeometryToken},
        {VCAM_ACTIVATION_PARITY_REMEDIATION_TARGET_GEOMETRY_STATE, &gTargetGeometryToken},
        {VCAM_ACTIVATION_PARITY_REMEDIATION_SESSION_STATE, &gSessionToken},
        {VCAM_ACTIVATION_PARITY_REMEDIATION_QUEUE_GENERATION_STATE, &gQueueGenerationToken},
        {VCAM_ACTIVATION_PARITY_REMEDIATION_QUEUE_EPOCH_STATE, &gQueueEpochToken},
        {VCAM_ACTIVATION_PARITY_REMEDIATION_ADAPTER_GENERATION_STATE, &gAdapterGenerationToken},
        {VCAM_ACTIVATION_PARITY_REMEDIATION_ADAPTER_EPOCH_STATE, &gAdapterEpochToken},
        {VCAM_ACTIVATION_PARITY_REMEDIATION_PRODUCER_STATE, &gProducerToken},
        {VCAM_ACTIVATION_PARITY_REMEDIATION_DECISION_COUNTS_STATE, &gDecisionCountsToken},
        {VCAM_ACTIVATION_PARITY_REMEDIATION_FAIL_COUNTS_STATE, &gFailCountsToken},
        {VCAM_ACTIVATION_PARITY_REMEDIATION_LAST_DECISION_STATE, &gLastDecisionToken},
        {VCAM_ACTIVATION_PARITY_REMEDIATION_LAST_PREPARED_GEOMETRY_STATE, &gLastPreparedGeometryToken},
        {VCAM_ACTIVATION_PARITY_REMEDIATION_STILL_COUNTS_STATE, &gStillCountsToken},
        {VCAM_ACTIVATION_PARITY_REMEDIATION_STILL_GEOMETRY_STATE, &gStillGeometryToken},
    };

    for (const auto& registration : registrations) {
        if (!RegisterStateToken(
                registration.name,
                registration.token)) {
            return;
        }
    }

    ClearTransport();
}

void BeginActivationParityPhotoGeneration(
    std::uint64_t selectionGeneration) noexcept {
    const std::uint64_t previous =
        gActiveGeneration.exchange(
            selectionGeneration,
            std::memory_order_acq_rel);

    if (previous == selectionGeneration) {
        return;
    }

    ResetCounters();
    ClearTransport();
}

void ObserveActivationParityCameraDecision(
    std::uint64_t selectionGeneration,
    const CameraDecision& decision,
    CVPixelBufferRef original) noexcept {
    if (selectionGeneration == 0 ||
        gActiveGeneration.load(
            std::memory_order_acquire) !=
            selectionGeneration) {
        return;
    }

    SaturatingIncrement(
        gDecisionCallbacks);

    switch (decision.source) {
        case CameraDecisionSource::PreparedMedia:
            SaturatingIncrement(
                gPreparedDecisions);
            if (decision.pixelBuffer != nullptr) {
                gLastPreparedGeometry.store(
                    GeometryKey(
                        decision.pixelBuffer),
                    std::memory_order_release);
            }
            break;
        case CameraDecisionSource::BlackFallback:
            SaturatingIncrement(
                gBlackDecisions);
            break;
        case CameraDecisionSource::Original:
        default:
            SaturatingIncrement(
                gOriginalDecisions);
            break;
    }

    switch (decision.mediaFailureReason) {
        case CameraFailOpenReason::ReconfigurationContended:
            SaturatingIncrement(
                gFailReconfiguration);
            break;
        case CameraFailOpenReason::ProducerUnavailable:
            SaturatingIncrement(
                gFailProducer);
            break;
        case CameraFailOpenReason::EmptyOrNoEligibleFrame:
            SaturatingIncrement(
                gFailEmpty);
            break;
        case CameraFailOpenReason::InvalidLease:
            SaturatingIncrement(
                gFailInvalidLease);
            break;
        case CameraFailOpenReason::GeometryMismatch:
            SaturatingIncrement(
                gFailGeometry);
            break;
        default:
            break;
    }

    gLastSource.store(
        static_cast<std::uint32_t>(
            decision.source),
        std::memory_order_release);
    gLastReason.store(
        static_cast<std::uint32_t>(
            decision.mediaFailureReason),
        std::memory_order_release);
    gLastOriginalGeometry.store(
        GeometryKey(original),
        std::memory_order_release);
}

void ObserveActivationParityHook(
    const ActivationParityHookObservation& observation) noexcept {
    SaturatingIncrement(gHookTotal);

    if (observation.stillImageKeyPresent) {
        SaturatingIncrement(
            gStillPresent);

        switch (observation.source) {
            case CameraDecisionSource::PreparedMedia:
                SaturatingIncrement(
                    gStillPrepared);
                break;
            case CameraDecisionSource::BlackFallback:
                SaturatingIncrement(
                    gStillBlack);
                break;
            case CameraDecisionSource::Original:
            default:
                SaturatingIncrement(
                    gStillOriginal);
                break;
        }

        if (observation.virtualCommitAttempted) {
            if (observation.virtualCommitSucceeded) {
                SaturatingIncrement(
                    gCommitSuccess);
            } else {
                SaturatingIncrement(
                    gCommitFailure);
            }
        }

        if (observation.originalGeometry != 0) {
            gStillGeometry.store(
                observation.originalGeometry,
                std::memory_order_release);
        }
    } else {
        SaturatingIncrement(
            gStillAbsent);
    }
}

void PublishActivationParityPhotoSnapshot(
    const ActivationParityPhotoSnapshot& input) noexcept {
    if (input.selectionGeneration == 0 ||
        gActiveGeneration.load(
            std::memory_order_acquire) !=
            input.selectionGeneration ||
        gPrimaryToken < 0 ||
        gSelectionToken < 0) {
        return;
    }

    ActivationParityPhotoSnapshot snapshot =
        input;

    snapshot.cameraDecisionCallbacks =
        gDecisionCallbacks.load(
            std::memory_order_acquire);
    snapshot.preparedMediaDecisions =
        gPreparedDecisions.load(
            std::memory_order_acquire);
    snapshot.blackFallbackDecisions =
        gBlackDecisions.load(
            std::memory_order_acquire);
    snapshot.emergencyOriginalDecisions =
        gOriginalDecisions.load(
            std::memory_order_acquire);

    snapshot.failReconfigurationContended =
        gFailReconfiguration.load(
            std::memory_order_acquire);
    snapshot.failProducerUnavailable =
        gFailProducer.load(
            std::memory_order_acquire);
    snapshot.failEmptyOrNoEligible =
        gFailEmpty.load(
            std::memory_order_acquire);
    snapshot.failInvalidLease =
        gFailInvalidLease.load(
            std::memory_order_acquire);
    snapshot.failGeometryMismatch =
        gFailGeometry.load(
            std::memory_order_acquire);

    snapshot.lastSource =
        static_cast<CameraDecisionSource>(
            gLastSource.load(
                std::memory_order_acquire));
    snapshot.lastMediaFailureReason =
        static_cast<CameraFailOpenReason>(
            gLastReason.load(
                std::memory_order_acquire));
    snapshot.lastOriginalGeometry =
        gLastOriginalGeometry.load(
            std::memory_order_acquire);
    snapshot.lastPreparedGeometry =
        gLastPreparedGeometry.load(
            std::memory_order_acquire);

    if (snapshot.preparedMediaDecisions > 0) {
        snapshot.stage =
            ActivationParityPhotoStage::
                PreparedMedia;
    } else if (
        snapshot.blackFallbackDecisions > 0) {
        if (snapshot.failGeometryMismatch > 0) {
            snapshot.stage =
                ActivationParityPhotoStage::
                    GeometryMismatch;
        } else if (
            snapshot.failInvalidLease > 0) {
            snapshot.stage =
                ActivationParityPhotoStage::
                    InvalidLease;
        } else if (
            snapshot.failProducerUnavailable > 0) {
            snapshot.stage =
                ActivationParityPhotoStage::
                    ProducerUnavailable;
        } else if (
            snapshot.failReconfigurationContended > 0) {
            snapshot.stage =
                ActivationParityPhotoStage::
                    ReconfigurationContended;
        } else if (
            snapshot.failEmptyOrNoEligible > 0) {
            snapshot.stage =
                ActivationParityPhotoStage::
                    QueueEmpty;
        } else {
            snapshot.stage =
                ActivationParityPhotoStage::
                    BlackFallback;
        }
    } else if (
        snapshot.emergencyOriginalDecisions > 0) {
        snapshot.stage =
            ActivationParityPhotoStage::
                EmergencyOriginal;
    }

    const pid_t pidValue = getpid();
    const time_t nowValue = time(nullptr);
    if (pidValue <= 0 ||
        static_cast<std::uint64_t>(pidValue) >
            UINT32_C(0x000fffff) ||
        nowValue < 0 ||
        static_cast<std::uint64_t>(nowValue) >
            UINT32_MAX) {
        return;
    }

    uint64_t controlFlags = 0;
    if (snapshot.enabled) {
        controlFlags |=
            VCAM_ACTIVATION_CONTROL_ENABLED;
    }
    if (snapshot.photoSelected) {
        controlFlags |=
            VCAM_ACTIVATION_CONTROL_PHOTO |
            VCAM_ACTIVATION_CONTROL_HAS_MEDIA;
    }
    if (snapshot.mediaStaged) {
        controlFlags |=
            VCAM_ACTIVATION_CONTROL_STAGED;
    }
    if (snapshot.controlObserved) {
        controlFlags |=
            VCAM_ACTIVATION_CONTROL_OBSERVED;
    }
    if (snapshot.selectPhotoAttempted) {
        controlFlags |=
            VCAM_ACTIVATION_CONTROL_SELECT_ATTEMPTED;
    }
    if (snapshot.selectPhotoResult) {
        controlFlags |=
            VCAM_ACTIVATION_CONTROL_SELECT_RESULT;
    }
    if (snapshot.startAttempted) {
        controlFlags |=
            VCAM_ACTIVATION_CONTROL_START_ATTEMPTED;
    }
    if (snapshot.startResult) {
        controlFlags |=
            VCAM_ACTIVATION_CONTROL_START_RESULT;
    }
    if (snapshot.sessionInstalled) {
        controlFlags |=
            VCAM_ACTIVATION_CONTROL_SESSION_INSTALLED;
    }
    if (snapshot.queueBound) {
        controlFlags |=
            VCAM_ACTIVATION_CONTROL_QUEUE_BOUND;
    }

    uint64_t sessionFlags = 0;
    if (snapshot.sessionExists) {
        sessionFlags |=
            VCAM_ACTIVATION_SESSION_EXISTS;
    }
    if (snapshot.selectedMediaValid) {
        sessionFlags |=
            VCAM_ACTIVATION_SESSION_SELECTED_VALID;
    }
    if (snapshot.selectedMediaPhoto) {
        sessionFlags |=
            VCAM_ACTIVATION_SESSION_SELECTED_PHOTO;
    }
    if (snapshot.selectedMediaPathMatches) {
        sessionFlags |=
            VCAM_ACTIVATION_SESSION_PATH_MATCH;
    }
    if (snapshot.producerHealthy) {
        sessionFlags |=
            VCAM_ACTIVATION_SESSION_PRODUCER_HEALTHY;
    }
    if (snapshot.observedGeometry != 0) {
        sessionFlags |=
            VCAM_ACTIVATION_SESSION_GEOMETRY_OBSERVED;
    }

    const uint64_t primary =
        vcam_activation_remediation_encode_primary(
            static_cast<uint32_t>(nowValue),
            static_cast<uint32_t>(pidValue),
            EncodedStage(snapshot.stage));
    const uint64_t sessionState =
        vcam_activation_remediation_encode_session(
            snapshot.readyQueueSize,
            snapshot.sessionReplacementCount,
            snapshot.playbackIntent,
            snapshot.playbackState,
            snapshot.readerState,
            snapshot.readerError,
            sessionFlags);
    const uint64_t producerState =
        vcam_activation_remediation_encode_producer(
            snapshot.frameSequenceCount,
            snapshot.startAttempted,
            snapshot.startResult);
    const uint64_t decisionCounts =
        vcam_activation_remediation_encode_decision_counts(
            snapshot.cameraDecisionCallbacks,
            snapshot.preparedMediaDecisions,
            snapshot.blackFallbackDecisions,
            snapshot.emergencyOriginalDecisions);
    const uint64_t failCounts =
        vcam_activation_remediation_encode_fail_counts(
            snapshot.failReconfigurationContended,
            snapshot.failProducerUnavailable,
            snapshot.failEmptyOrNoEligible,
            snapshot.failInvalidLease,
            snapshot.failGeometryMismatch);
    const uint64_t lastDecision =
        vcam_activation_remediation_encode_last_decision(
            static_cast<std::uint8_t>(
                snapshot.lastSource),
            static_cast<std::uint8_t>(
                snapshot.lastMediaFailureReason));
    const uint64_t stillCounts =
        vcam_activation_remediation_encode_still_counts(
            gHookTotal.load(std::memory_order_acquire),
            gStillPresent.load(std::memory_order_acquire),
            gStillAbsent.load(std::memory_order_acquire),
            gStillPrepared.load(std::memory_order_acquire),
            gStillBlack.load(std::memory_order_acquire),
            gStillOriginal.load(std::memory_order_acquire),
            gCommitSuccess.load(std::memory_order_acquire),
            gCommitFailure.load(std::memory_order_acquire));

    const struct {
        int token;
        uint64_t value;
    } states[] = {
        {gSelectionToken, snapshot.selectionGeneration},
        {gPathHashToken, snapshot.mediaPathHash},
        {gControlToken, controlFlags},
        {gObservedGeometryToken, snapshot.observedGeometry},
        {gTargetGeometryToken, snapshot.sessionTargetGeometry},
        {gSessionToken, sessionState},
        {gQueueGenerationToken, snapshot.queueMediaGeneration},
        {gQueueEpochToken, snapshot.queueTimelineEpoch},
        {gAdapterGenerationToken, snapshot.adapterMediaGeneration},
        {gAdapterEpochToken, snapshot.adapterTimelineEpoch},
        {gProducerToken, producerState},
        {gDecisionCountsToken, decisionCounts},
        {gFailCountsToken, failCounts},
        {gLastDecisionToken, lastDecision},
        {gLastPreparedGeometryToken, snapshot.lastPreparedGeometry},
        {gStillCountsToken, stillCounts},
        {gStillGeometryToken, gStillGeometry.load(std::memory_order_acquire)},
        {gPrimaryToken, primary},
    };

    for (const auto& state : states) {
        if (state.token < 0 ||
            notify_set_state(
                state.token,
                state.value) !=
                NOTIFY_STATUS_OK) {
            return;
        }
    }

    (void)notify_post(
        VCAM_ACTIVATION_PARITY_REMEDIATION_NOTIFICATION);
}

}  // namespace vcam::product::proof
