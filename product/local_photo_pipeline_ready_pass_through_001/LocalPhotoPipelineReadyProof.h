#pragma once

#include "LocalPhotoPipelineReadyProofState.h"

#include <cstddef>
#include <cstdint>

namespace vcam::product::proof {

struct LocalPhotoCallbackFacts {
    std::uint64_t selectionGeneration = 0;
    bool callbackExercised = false;
    bool originalNonNull = false;
    bool vcamDisabled = false;
    bool photoSelected = false;
    bool hasMedia = false;
    bool decisionOriginal = false;
    bool disabledReason = false;
    bool originalBufferReturned = false;
    std::uint64_t decisionCountBefore = 0;
    std::uint64_t decisionCountAfter = 0;
    std::uint64_t virtualDecisionCount = 0;
};

struct LocalPhotoCallbackSnapshot {
    bool callbackExercised = false;
    bool originalNonNull = false;
    bool decisionOriginal = false;
    bool disabledReason = false;
    bool originalBufferReturned = false;
    std::uint64_t virtualDecisionCount = 0;
};

struct LocalPhotoDiagnosticSnapshot {
    std::uint64_t selectionGeneration = 0;
    bool vcamEnabled = false;
    LocalPhotoProofMediaKind mediaKind =
        LocalPhotoProofMediaKind::None;
    bool hasMedia = false;
    bool mediaStaged = false;
    bool controlObserved = false;
    bool cameraGeometryObserved = false;
    bool sessionExists = false;
    bool selectedMediaValid = false;
    LocalPhotoProofMediaKind selectedMediaKind =
        LocalPhotoProofMediaKind::None;
    bool selectedMediaPathMatches = false;
    LocalPhotoProofPlaybackIntent playbackIntent =
        LocalPhotoProofPlaybackIntent::Stopped;
    LocalPhotoProofPlaybackState playbackState =
        LocalPhotoProofPlaybackState::Unknown;
    bool producerReady = false;
    std::size_t readyFrameCount = 0;
    bool callbackExercised = false;
    bool originalNonNull = false;
    bool decisionOriginal = false;
    bool disabledReason = false;
    bool originalBufferReturned = false;
    std::uint64_t virtualDecisionCount = 0;
    LocalPhotoProofPipelineStage pipelineStage =
        LocalPhotoProofPipelineStage::WaitingControl;
};

void ResetLocalPhotoPipelineReadyProofState() noexcept;

void BeginLocalPhotoPipelineSelection(
    std::uint64_t selectionGeneration) noexcept;

void ObserveLocalPhotoCallbackPhase(
    const LocalPhotoCallbackFacts& facts) noexcept;

bool ReadLocalPhotoCallbackSnapshot(
    std::uint64_t selectionGeneration,
    LocalPhotoCallbackSnapshot* snapshot) noexcept;

bool PublishLocalPhotoPipelineSnapshot(
    const LocalPhotoDiagnosticSnapshot& snapshot,
    LocalPhotoProofResult result) noexcept;

}  // namespace vcam::product::proof
