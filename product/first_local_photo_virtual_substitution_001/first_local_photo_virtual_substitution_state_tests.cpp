#include "FirstLocalPhotoVirtualSubstitutionProofState.h"

#include <cstdint>
#include <iostream>

namespace {

int failures = 0;

void Check(bool condition, const char* name) {
    if (condition) {
        std::cout << "PASS " << name << "\n";
        return;
    }

    std::cout << "FAIL " << name << "\n";
    ++failures;
}

}  // namespace

int main() {
    constexpr std::uint32_t timestamp = 1770000000U;
    constexpr std::uint32_t pid = 4242U;
    constexpr std::uint64_t generation = UINT64_C(91);

    const std::uint64_t state =
        vcam_first_photo_substitution_encode_state(
            timestamp,
            pid,
            VCAM_FIRST_PHOTO_SUB_REQUIRED_FLAGS);

    Check(
        vcam_first_photo_substitution_state_timestamp(state) ==
            timestamp,
        "timestamp decode");
    Check(
        vcam_first_photo_substitution_state_pid(state) ==
            pid,
        "pid decode");
    Check(
        vcam_first_photo_substitution_state_flags(state) ==
            VCAM_FIRST_PHOTO_SUB_REQUIRED_FLAGS,
        "required flags decode");
    Check(
        vcam_first_photo_substitution_state_is_valid_fresh(
            state,
            generation,
            timestamp),
        "fresh complete proof accepted");
    Check(
        vcam_first_photo_substitution_state_is_valid_fresh(
            state,
            generation,
            timestamp + 180U),
        "freshness boundary accepted");
    Check(
        !vcam_first_photo_substitution_state_is_valid_fresh(
            state,
            generation,
            timestamp + 181U),
        "stale proof rejected");
    Check(
        !vcam_first_photo_substitution_state_is_valid_fresh(
            state,
            0U,
            timestamp),
        "zero generation rejected");

    const std::uint64_t zeroPid =
        vcam_first_photo_substitution_encode_state(
            timestamp,
            0U,
            VCAM_FIRST_PHOTO_SUB_REQUIRED_FLAGS);
    Check(
        !vcam_first_photo_substitution_state_is_valid_fresh(
            zeroPid,
            generation,
            timestamp),
        "zero pid rejected");

    const std::uint32_t required[] = {
        VCAM_FIRST_PHOTO_SUB_FLAG_VCAM_ENABLED,
        VCAM_FIRST_PHOTO_SUB_FLAG_MEDIA_PHOTO,
        VCAM_FIRST_PHOTO_SUB_FLAG_MEDIA_READY,
        VCAM_FIRST_PHOTO_SUB_FLAG_GEOMETRY_OBSERVED,
        VCAM_FIRST_PHOTO_SUB_FLAG_CALLBACK_EXERCISED,
        VCAM_FIRST_PHOTO_SUB_FLAG_DECISION_VIRTUAL,
        VCAM_FIRST_PHOTO_SUB_FLAG_VIRTUAL_NON_NULL,
        VCAM_FIRST_PHOTO_SUB_FLAG_VIRTUAL_DIFFERENT,
        VCAM_FIRST_PHOTO_SUB_FLAG_GEOMETRY_MATCH,
        VCAM_FIRST_PHOTO_SUB_FLAG_VIRTUAL_COUNT_INCREMENT,
        VCAM_FIRST_PHOTO_SUB_FLAG_DECISION_COUNT_INCREMENT,
    };

    for (const std::uint32_t missing : required) {
        const std::uint64_t incomplete =
            vcam_first_photo_substitution_encode_state(
                timestamp,
                pid,
                VCAM_FIRST_PHOTO_SUB_REQUIRED_FLAGS &
                    ~missing);
        Check(
            !vcam_first_photo_substitution_state_is_valid_fresh(
                incomplete,
                generation,
                timestamp),
            "incomplete proof rejected");
    }

    const std::uint64_t future =
        vcam_first_photo_substitution_encode_state(
            timestamp + 5U,
            pid,
            VCAM_FIRST_PHOTO_SUB_REQUIRED_FLAGS);
    Check(
        vcam_first_photo_substitution_state_is_valid_fresh(
            future,
            generation,
            timestamp),
        "bounded future skew accepted");

    const std::uint64_t farFuture =
        vcam_first_photo_substitution_encode_state(
            timestamp + 6U,
            pid,
            VCAM_FIRST_PHOTO_SUB_REQUIRED_FLAGS);
    Check(
        !vcam_first_photo_substitution_state_is_valid_fresh(
            farFuture,
            generation,
            timestamp),
        "excess future skew rejected");

    if (failures == 0) {
        std::cout
            << "REQUIRED_FLAGS_ACCEPTED=PASS\n"
            << "INCOMPLETE_FLAGS_REJECTED=PASS\n"
            << "SELECTION_GENERATION_REQUIRED=PASS\n"
            << "FRESHNESS_ENFORCED=PASS\n"
            << "FUTURE_SKEW_LIMIT_ENFORCED=PASS\n"
            << "NONZERO_PID_REQUIRED=PASS\n";
    }

    return failures == 0 ? 0 : 1;
}
