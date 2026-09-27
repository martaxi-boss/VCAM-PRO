#pragma once

#include "FirstLocalPhotoSubstitutionDiagnosticProofState.h"

#include <cstdint>

namespace vcam::product::proof {

struct FirstLocalPhotoSubstitutionDiagnosticSnapshot {
    std::uint64_t selectionGeneration = 0;

    std::uint32_t cameraCallbackCount = 0;
    std::uint32_t decisionCountDelta = 0;
    std::uint32_t virtualDecisionCountDelta = 0;
    std::uint32_t decisionVirtualCount = 0;
    std::uint32_t decisionOriginalCount = 0;

    std::uint32_t failOpenDisabledCount = 0;
    std::uint32_t failOpenReconfigurationContendedCount = 0;
    std::uint32_t failOpenProducerUnavailableCount = 0;
    std::uint32_t failOpenEmptyOrNoEligibleCount = 0;
    std::uint32_t failOpenInvalidLeaseCount = 0;
    std::uint32_t failOpenGeometryMismatchCount = 0;

    std::uint32_t geometryChangeCount = 0;
    std::uint64_t observedCameraGeometry = 0;
    std::uint64_t sessionTargetGeometry = 0;

    bool vcamEnabled = false;
    bool photoSelected = false;
    bool producerHealthy = false;
    bool sessionExists = false;
    FirstPhotoSubDiagnosticPlaybackState playbackState =
        FirstPhotoSubDiagnosticPlaybackState::Unknown;
    std::uint32_t readyFrameCount = 0;
    bool selectedMediaValid = false;
    FirstPhotoSubDiagnosticMediaKind selectedMediaKind =
        FirstPhotoSubDiagnosticMediaKind::None;
    bool selectedMediaPathMatch = false;

    FirstPhotoSubDiagnosticDecision lastDecision =
        FirstPhotoSubDiagnosticDecision::None;
    FirstPhotoSubDiagnosticReason lastFailOpenReason =
        FirstPhotoSubDiagnosticReason::None;
    bool virtualBufferNonNull = false;
    bool virtualBufferDifferentFromOriginal = false;
    bool virtualWidthMatch = false;
    bool virtualHeightMatch = false;
    bool virtualPixelFormatMatch = false;
    bool virtualGeometryMatch = false;
};

}  // namespace vcam::product::proof
