#pragma once

#include "CameraConsumerAdapter.h"

#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>

#include <cstddef>
#include <cstdint>

namespace vcam::product::proof {

enum class ActivationParityPhotoStage : std::uint8_t {
    WaitingControl = 0,
    StagingMismatch,
    WaitingGeometry,
    SelectPhotoFailed,
    ProducerStartFailed,
    SessionAbsent,
    ProducerUnavailable,
    QueueEmpty,
    ReconfigurationContended,
    InvalidLease,
    GeometryMismatch,
    BlackFallback,
    PreparedMedia,
    EmergencyOriginal,
};

struct ActivationParityPhotoSnapshot {
    std::uint64_t selectionGeneration = 0;
    std::uint64_t mediaPathHash = 0;

    bool enabled = false;
    bool photoSelected = false;
    bool mediaStaged = false;
    bool controlObserved = false;

    std::uint64_t observedGeometry = 0;
    std::uint32_t geometryChangeCount = 0;
    std::uint64_t sessionTargetGeometry = 0;
    std::uint64_t targetSelectionGeneration = 0;

    bool selectPhotoAttempted = false;
    bool selectPhotoResult = false;
    bool startAttempted = false;
    bool startResult = false;
    bool sessionInstalled = false;
    std::uint32_t sessionReplacementCount = 0;

    bool sessionExists = false;
    bool selectedMediaValid = false;
    bool selectedMediaPhoto = false;
    bool selectedMediaPathMatches = false;

    std::uint8_t playbackIntent = 0;
    std::uint8_t playbackState = 0;
    bool producerHealthy = false;
    std::uint8_t readerState = 0;
    std::uint8_t readerError = 0;
    std::uint64_t frameSequenceCount = 0;

    bool queueBound = false;
    std::uint32_t readyQueueSize = 0;
    std::uint64_t queueMediaGeneration = 0;
    std::uint64_t queueTimelineEpoch = 0;
    std::uint64_t adapterMediaGeneration = 0;
    std::uint64_t adapterTimelineEpoch = 0;

    std::uint32_t cameraDecisionCallbacks = 0;
    std::uint32_t preparedMediaDecisions = 0;
    std::uint32_t blackFallbackDecisions = 0;
    std::uint32_t emergencyOriginalDecisions = 0;

    std::uint32_t failReconfigurationContended = 0;
    std::uint32_t failProducerUnavailable = 0;
    std::uint32_t failEmptyOrNoEligible = 0;
    std::uint32_t failInvalidLease = 0;
    std::uint32_t failGeometryMismatch = 0;

    CameraDecisionSource lastSource =
        CameraDecisionSource::Original;
    CameraFailOpenReason lastMediaFailureReason =
        CameraFailOpenReason::None;

    std::uint64_t lastOriginalGeometry = 0;
    std::uint64_t lastPreparedGeometry = 0;
    ActivationParityPhotoStage stage =
        ActivationParityPhotoStage::WaitingControl;
};

struct ActivationParityHookObservation {
    bool stillImageKeyPresent = false;
    CameraDecisionSource source =
        CameraDecisionSource::Original;
    CameraDecisionKind kind =
        CameraDecisionKind::Original;
    CameraFailOpenReason mediaFailureReason =
        CameraFailOpenReason::None;
    bool virtualCommitAttempted = false;
    bool virtualCommitSucceeded = false;
    std::uint64_t originalGeometry = 0;
};

void ResetActivationParityDeviceRemediationProof() noexcept;

void BeginActivationParityPhotoGeneration(
    std::uint64_t selectionGeneration) noexcept;

void ObserveActivationParityCameraDecision(
    std::uint64_t selectionGeneration,
    const CameraDecision& decision,
    CVPixelBufferRef original) noexcept;

void ObserveActivationParityHook(
    const ActivationParityHookObservation& observation) noexcept;

void PublishActivationParityPhotoSnapshot(
    const ActivationParityPhotoSnapshot& snapshot) noexcept;

}  // namespace vcam::product::proof
