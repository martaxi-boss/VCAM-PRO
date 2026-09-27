#pragma once

#include <cstddef>
#include <cstdint>

namespace vcam::product::proof {

struct LocalPhotoCallbackFacts {
    std::uint64_t selectionGeneration = 0;
    bool originalNonNull = false;
    bool vcamDisabled = false;
    bool photoSelected = false;
    bool hasMedia = false;
    bool decisionOriginal = false;
    bool disabledReason = false;
    bool originalBufferReturned = false;
    std::uint64_t decisionCountBefore = 0;
    std::uint64_t decisionCountAfter = 0;
    std::uint64_t virtualDecisionCountBefore = 0;
    std::uint64_t virtualDecisionCountAfter = 0;
};

struct LocalPhotoReadyFacts {
    std::uint64_t selectionGeneration = 0;
    bool vcamDisabled = false;
    bool photoSelected = false;
    bool mediaPathNonEmpty = false;
    bool playbackIntentPlaying = false;
    bool controlObserved = false;
    bool cameraGeometryObserved = false;
    bool mediaStaged = false;
    bool sessionExists = false;
    bool selectedMediaValid = false;
    bool selectedMediaPhoto = false;
    bool selectedMediaPathMatches = false;
    bool producerPlaying = false;
    std::size_t readyFrameCount = 0;
    std::uint64_t virtualDecisionCount = 0;
};

void ResetLocalPhotoPipelineReadyProofState() noexcept;

void BeginLocalPhotoPipelineSelection(
    std::uint64_t selectionGeneration) noexcept;

void ObserveLocalPhotoCallbackPhase(
    const LocalPhotoCallbackFacts& facts) noexcept;

void ObserveLocalPhotoReadyPhase(
    const LocalPhotoReadyFacts& facts) noexcept;

}  // namespace vcam::product::proof
