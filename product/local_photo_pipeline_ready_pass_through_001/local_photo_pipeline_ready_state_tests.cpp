#include "LocalPhotoPipelineReadyProofState.h"

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

    const std::uint64_t state =
        vcam_local_photo_pipeline_ready_encode_state(
            timestamp,
            pid);

    Check(
        vcam_local_photo_pipeline_ready_state_timestamp(state) ==
            timestamp,
        "timestamp decode");
    Check(
        vcam_local_photo_pipeline_ready_state_pid(state) == pid,
        "pid decode");
    Check(
        vcam_local_photo_pipeline_ready_state_flags(state) ==
            VCAM_LOCAL_PHOTO_REQUIRED_FLAGS,
        "required flags decode");
    Check(
        vcam_local_photo_pipeline_ready_generations_match(7U, 7U),
        "matching selection generation accepted");
    Check(
        !vcam_local_photo_pipeline_ready_generations_match(7U, 8U),
        "mismatched selection generation rejected");
    Check(
        !vcam_local_photo_pipeline_ready_generations_match(0U, 0U),
        "zero selection generation rejected");

    Check(
        vcam_local_photo_pipeline_ready_state_is_valid_fresh(
            state,
            timestamp),
        "current proof accepted");
    Check(
        vcam_local_photo_pipeline_ready_state_is_valid_fresh(
            state,
            timestamp + 180U),
        "freshness boundary accepted");
    Check(
        !vcam_local_photo_pipeline_ready_state_is_valid_fresh(
            state,
            timestamp + 181U),
        "stale proof rejected");

    const std::uint64_t future =
        vcam_local_photo_pipeline_ready_encode_state(
            timestamp + 5U,
            pid);
    Check(
        vcam_local_photo_pipeline_ready_state_is_valid_fresh(
            future,
            timestamp),
        "bounded future skew accepted");

    const std::uint64_t farFuture =
        vcam_local_photo_pipeline_ready_encode_state(
            timestamp + 6U,
            pid);
    Check(
        !vcam_local_photo_pipeline_ready_state_is_valid_fresh(
            farFuture,
            timestamp),
        "excess future skew rejected");

    Check(
        !vcam_local_photo_pipeline_ready_state_is_valid_fresh(
            vcam_local_photo_pipeline_ready_encode_state(
                timestamp,
                0U),
            timestamp),
        "zero pid rejected");

    const std::uint32_t required[] = {
        VCAM_LOCAL_PHOTO_FLAG_CALLBACK_EXERCISED,
        VCAM_LOCAL_PHOTO_FLAG_VCAM_DISABLED,
        VCAM_LOCAL_PHOTO_FLAG_MEDIA_PHOTO,
        VCAM_LOCAL_PHOTO_FLAG_MEDIA_STAGED,
        VCAM_LOCAL_PHOTO_FLAG_CONTROL_OBSERVED,
        VCAM_LOCAL_PHOTO_FLAG_GEOMETRY_OBSERVED,
        VCAM_LOCAL_PHOTO_FLAG_PRODUCER_PLAYING,
        VCAM_LOCAL_PHOTO_FLAG_READY_QUEUE_NONEMPTY,
        VCAM_LOCAL_PHOTO_FLAG_DECISION_ORIGINAL,
        VCAM_LOCAL_PHOTO_FLAG_ORIGINAL_RETURNED,
        VCAM_LOCAL_PHOTO_FLAG_SUBSTITUTION_INACTIVE,
        VCAM_LOCAL_PHOTO_FLAG_VIRTUAL_COUNT_ZERO,
    };

    for (const std::uint32_t missing : required) {
        const std::uint64_t incomplete =
            ((std::uint64_t)timestamp << 32) |
            ((std::uint64_t)pid << 12) |
            (VCAM_LOCAL_PHOTO_REQUIRED_FLAGS & ~missing);

        Check(
            !vcam_local_photo_pipeline_ready_state_is_valid_fresh(
                incomplete,
                timestamp),
            "incomplete flags rejected");
    }

    if (failures == 0) {
        std::cout
            << "REQUIRED_FLAGS_ACCEPTED=PASS\n"
            << "SELECTION_GENERATION_IDENTITY=PASS\n"
            << "INCOMPLETE_FLAGS_REJECTED=PASS\n"
            << "STALE_STATE_REJECTED=PASS\n"
            << "FUTURE_SKEW_LIMIT_ENFORCED=PASS\n"
            << "NONZERO_PID_REQUIRED=PASS\n";
    }

    return failures == 0 ? 0 : 1;
}
