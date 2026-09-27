#pragma once

#include <cstdint>

namespace vcam::product::proof {

struct FirstLocalPhotoVirtualSubstitutionFacts {
    std::uint64_t selectionGeneration = 0;
    bool originalNonNull = false;
    bool vcamEnabled = false;
    bool photoSelected = false;
    bool mediaReady = false;
    bool cameraGeometryObserved = false;
    bool callbackExercised = false;
    bool decisionVirtual = false;
    bool decisionReasonNone = false;
    bool virtualBufferNonNull = false;
    bool virtualBufferDifferentFromOriginal = false;
    bool geometryMatch = false;
    bool decisionCountIncremented = false;
    bool virtualDecisionCountIncremented = false;
    std::uint64_t virtualDecisionCountAfter = 0;
};

void ResetFirstLocalPhotoVirtualSubstitutionProofState() noexcept;

void BeginFirstLocalPhotoVirtualSubstitutionSelection(
    std::uint64_t selectionGeneration) noexcept;

void ObserveFirstLocalPhotoVirtualSubstitution(
    const FirstLocalPhotoVirtualSubstitutionFacts& facts) noexcept;

}  // namespace vcam::product::proof
