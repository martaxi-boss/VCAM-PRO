#include "RealCameraCallbackPassThroughProofState.h"

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
        vcam_real_camera_callback_passthrough_encode_state(
            timestamp,
            pid);

    Check(
        vcam_real_camera_callback_passthrough_state_timestamp(state) ==
            timestamp,
        "timestamp decode");
    Check(
        vcam_real_camera_callback_passthrough_state_pid(state) == pid,
        "pid decode");
    Check(
        vcam_real_camera_callback_passthrough_state_flags(state) ==
            VCAM_REAL_CAMERA_CALLBACK_REQUIRED_FLAGS,
        "all required facts encoded");
    Check(
        vcam_real_camera_callback_passthrough_state_is_valid_fresh(
            state,
            timestamp),
        "current proof accepted");
    Check(
        vcam_real_camera_callback_passthrough_state_is_valid_fresh(
            state,
            timestamp + 180U),
        "freshness boundary accepted");
    Check(
        !vcam_real_camera_callback_passthrough_state_is_valid_fresh(
            state,
            timestamp + 181U),
        "stale proof rejected");

    const std::uint64_t future =
        vcam_real_camera_callback_passthrough_encode_state(
            timestamp + 5U,
            pid);
    Check(
        vcam_real_camera_callback_passthrough_state_is_valid_fresh(
            future,
            timestamp),
        "bounded future skew accepted");

    const std::uint64_t farFuture =
        vcam_real_camera_callback_passthrough_encode_state(
            timestamp + 6U,
            pid);
    Check(
        !vcam_real_camera_callback_passthrough_state_is_valid_fresh(
            farFuture,
            timestamp),
        "excess future skew rejected");

    Check(
        !vcam_real_camera_callback_passthrough_state_is_valid_fresh(
            vcam_real_camera_callback_passthrough_encode_state(
                timestamp,
                0U),
            timestamp),
        "zero pid rejected");

    const std::uint32_t required[] = {
        VCAM_REAL_CAMERA_CALLBACK_FLAG_EXERCISED,
        VCAM_REAL_CAMERA_CALLBACK_FLAG_VCAM_DISABLED,
        VCAM_REAL_CAMERA_CALLBACK_FLAG_NO_MEDIA,
        VCAM_REAL_CAMERA_CALLBACK_FLAG_DECISION_ORIGINAL,
        VCAM_REAL_CAMERA_CALLBACK_FLAG_ORIGINAL_RETURNED,
        VCAM_REAL_CAMERA_CALLBACK_FLAG_SUBSTITUTION_INACTIVE,
        VCAM_REAL_CAMERA_CALLBACK_FLAG_VIRTUAL_COUNT_ZERO,
        VCAM_REAL_CAMERA_CALLBACK_FLAG_DISABLED_REASON,
    };

    for (const std::uint32_t missing : required) {
        const std::uint64_t incomplete =
            ((std::uint64_t)timestamp << 32) |
            ((std::uint64_t)pid << 8) |
            (VCAM_REAL_CAMERA_CALLBACK_REQUIRED_FLAGS & ~missing);

        Check(
            !vcam_real_camera_callback_passthrough_state_is_valid_fresh(
                incomplete,
                timestamp),
            "incomplete proof rejected");
    }

    if (failures == 0) {
        std::cout
            << "REQUIRED_FLAGS_ACCEPTED=PASS\n"
            << "INCOMPLETE_FLAGS_REJECTED=PASS\n"
            << "STALE_STATE_REJECTED=PASS\n"
            << "FUTURE_SKEW_LIMIT_ENFORCED=PASS\n"
            << "NONZERO_PID_REQUIRED=PASS\n";
    }

    return failures == 0 ? 0 : 1;
}
