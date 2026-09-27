#pragma once

#include "IOS15ActivationParityProofState.h"

#include <cstdint>

namespace vcam::product::proof {

struct IOS15ActivationParityFacts {
    IOS15ActivationOutput output =
        IOS15ActivationOutput::None;
    std::uint64_t selectionGeneration = 0;
    bool callbackExercised = false;
    bool vcamEnabled = false;
    bool mediaPhoto = false;
    bool decisionVirtual = false;
    bool decisionOriginal = false;
    bool decisionReasonNone = false;
    bool virtualBufferNonNull = false;
    bool virtualBufferDifferentFromOriginal = false;
    bool geometryMatch = false;
    bool sourceBlack = false;
    bool sourcePreparedMedia = false;
};

void ResetIOS15ActivationParityProofState() noexcept;

void ObserveIOS15ActivationParity(
    const IOS15ActivationParityFacts& facts) noexcept;

}  // namespace vcam::product::proof
