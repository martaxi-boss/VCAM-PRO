#pragma once

#include <cstdint>

namespace vcam::product::proof {

struct RealCameraCallbackPassThroughFacts {
    bool originalNonNull = false;
    bool controlEnabled = false;
    bool controlHasMedia = false;
    bool decisionOriginal = false;
    bool disabledReason = false;
    bool originalBufferReturned = false;
    std::uint64_t decisionCountBefore = 0;
    std::uint64_t decisionCountAfter = 0;
    std::uint64_t virtualDecisionCountBefore = 0;
    std::uint64_t virtualDecisionCountAfter = 0;
};

void ResetRealCameraCallbackPassThroughProofState() noexcept;

void ObserveRealCameraCallbackPassThroughDecision(
    const RealCameraCallbackPassThroughFacts& facts) noexcept;

}  // namespace vcam::product::proof
