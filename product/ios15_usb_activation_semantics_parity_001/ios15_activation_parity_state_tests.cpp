#include "IOS15ActivationParityProofState.h"

#include <cstdint>
#include <iostream>

namespace {

int failures = 0;

void Check(
    bool condition,
    const char* name) {
    if (condition) {
        std::cout
            << "PASS "
            << name
            << "\n";
        return;
    }

    std::cout
        << "FAIL "
        << name
        << "\n";
    ++failures;
}

uint64_t State(
    IOS15ActivationOutput output,
    uint32_t flags,
    uint32_t timestamp = 1770000000U,
    uint32_t pid = 4242U) {
    return
        vcam_ios15_activation_parity_encode_state(
            timestamp,
            pid,
            output,
            flags);
}

}  // namespace

int main() {
    constexpr uint32_t now =
        1770000000U;

    const uint32_t originalFlags =
        VCAM_ACTIVATION_FLAG_CALLBACK_EXERCISED |
        VCAM_ACTIVATION_FLAG_DECISION_ORIGINAL;

    const uint32_t blackFlags =
        VCAM_ACTIVATION_FLAG_CALLBACK_EXERCISED |
        VCAM_ACTIVATION_FLAG_VCAM_ENABLED |
        VCAM_ACTIVATION_FLAG_DECISION_VIRTUAL |
        VCAM_ACTIVATION_FLAG_VIRTUAL_NON_NULL |
        VCAM_ACTIVATION_FLAG_VIRTUAL_DIFFERENT |
        VCAM_ACTIVATION_FLAG_GEOMETRY_MATCH |
        VCAM_ACTIVATION_FLAG_SOURCE_BLACK;

    const uint32_t photoFlags =
        VCAM_ACTIVATION_FLAG_CALLBACK_EXERCISED |
        VCAM_ACTIVATION_FLAG_VCAM_ENABLED |
        VCAM_ACTIVATION_FLAG_MEDIA_PHOTO |
        VCAM_ACTIVATION_FLAG_DECISION_VIRTUAL |
        VCAM_ACTIVATION_FLAG_VIRTUAL_NON_NULL |
        VCAM_ACTIVATION_FLAG_VIRTUAL_DIFFERENT |
        VCAM_ACTIVATION_FLAG_GEOMETRY_MATCH |
        VCAM_ACTIVATION_FLAG_SOURCE_MEDIA;

    Check(
        vcam_ios15_activation_parity_state_is_valid(
            State(
                IOS15ActivationOutput::Original,
                originalFlags),
            0,
            now),
        "ORIGINAL proof accepted");

    Check(
        vcam_ios15_activation_parity_state_is_valid(
            State(
                IOS15ActivationOutput::BlackVirtual,
                blackFlags),
            0,
            now),
        "BLACK proof accepted");

    Check(
        vcam_ios15_activation_parity_state_is_valid(
            State(
                IOS15ActivationOutput::PhotoVirtual,
                photoFlags),
            77,
            now),
        "PHOTO proof accepted");

    Check(
        !vcam_ios15_activation_parity_state_is_valid(
            State(
                IOS15ActivationOutput::PhotoVirtual,
                photoFlags),
            0,
            now),
        "PHOTO requires selection generation");

    Check(
        !vcam_ios15_activation_parity_state_is_valid(
            State(
                IOS15ActivationOutput::BlackVirtual,
                blackFlags &
                    ~VCAM_ACTIVATION_FLAG_SOURCE_BLACK),
            0,
            now),
        "BLACK requires source");

    Check(
        !vcam_ios15_activation_parity_state_is_valid(
            State(
                IOS15ActivationOutput::Original,
                originalFlags |
                    VCAM_ACTIVATION_FLAG_VCAM_ENABLED),
            0,
            now),
        "ORIGINAL rejects VCAM enabled");

    Check(
        !vcam_ios15_activation_parity_state_is_valid(
            State(
                IOS15ActivationOutput::PhotoVirtual,
                photoFlags &
                    ~VCAM_ACTIVATION_FLAG_GEOMETRY_MATCH),
            77,
            now),
        "PHOTO requires geometry match");

    const uint64_t stale =
        State(
            IOS15ActivationOutput::BlackVirtual,
            blackFlags,
            now - 181U);

    Check(
        !vcam_ios15_activation_parity_state_is_valid(
            stale,
            0,
            now),
        "stale state rejected");

    const uint64_t future =
        State(
            IOS15ActivationOutput::BlackVirtual,
            blackFlags,
            now + 5U);

    Check(
        vcam_ios15_activation_parity_state_is_valid(
            future,
            0,
            now),
        "bounded future skew accepted");

    const uint64_t tooFuture =
        State(
            IOS15ActivationOutput::BlackVirtual,
            blackFlags,
            now + 6U);

    Check(
        !vcam_ios15_activation_parity_state_is_valid(
            tooFuture,
            0,
            now),
        "excess future skew rejected");

    const uint64_t zeroPid =
        State(
            IOS15ActivationOutput::BlackVirtual,
            blackFlags,
            now,
            0U);

    Check(
        !vcam_ios15_activation_parity_state_is_valid(
            zeroPid,
            0,
            now),
        "zero pid rejected");

    if (failures == 0) {
        std::cout
            << "ORIGINAL_STATE_VALIDATION=PASS\n"
            << "BLACK_STATE_VALIDATION=PASS\n"
            << "PHOTO_STATE_VALIDATION=PASS\n"
            << "FRESHNESS_VALIDATION=PASS\n"
            << "SELECTION_IDENTITY_VALIDATION=PASS\n";
    }

    return failures == 0
        ? 0
        : 1;
}
