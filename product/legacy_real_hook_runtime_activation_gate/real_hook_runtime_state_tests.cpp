#include "RealHookRuntimeProofState.h"

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
        vcam_real_hook_runtime_encode_state(timestamp, pid);

    Check(vcam_real_hook_runtime_state_timestamp(state) == timestamp,
          "timestamp decode");
    Check(vcam_real_hook_runtime_state_pid(state) == pid,
          "pid decode");
    Check(vcam_real_hook_runtime_state_flags(state) ==
              VCAM_REAL_HOOK_RUNTIME_REQUIRED_FLAGS,
          "all proof flags present");
    Check(vcam_real_hook_runtime_state_is_valid_fresh(state, timestamp),
          "current state accepted");
    Check(vcam_real_hook_runtime_state_is_valid_fresh(state, timestamp + 180U),
          "freshness boundary accepted");
    Check(!vcam_real_hook_runtime_state_is_valid_fresh(state, timestamp + 181U),
          "stale state rejected");

    const std::uint64_t future =
        vcam_real_hook_runtime_encode_state(timestamp + 5U, pid);
    Check(vcam_real_hook_runtime_state_is_valid_fresh(future, timestamp),
          "bounded future skew accepted");

    const std::uint64_t farFuture =
        vcam_real_hook_runtime_encode_state(timestamp + 6U, pid);
    Check(!vcam_real_hook_runtime_state_is_valid_fresh(farFuture, timestamp),
          "far future state rejected");

    Check(!vcam_real_hook_runtime_state_is_valid_fresh(
              vcam_real_hook_runtime_encode_state(timestamp, 0U), timestamp),
          "zero pid rejected");

    const std::uint32_t required[] = {
        VCAM_REAL_HOOK_RUNTIME_FLAG_RUNTIME_START_PASS,
        VCAM_REAL_HOOK_RUNTIME_FLAG_REAL_HOOK_INSTALL_PASS,
        VCAM_REAL_HOOK_RUNTIME_FLAG_ORIGINAL_TRAMPOLINE_NON_NULL,
        VCAM_REAL_HOOK_RUNTIME_FLAG_CALLBACK_NOT_EXERCISED,
        VCAM_REAL_HOOK_RUNTIME_FLAG_FRAME_SUBSTITUTION_INACTIVE,
    };

    for (const std::uint32_t missing : required) {
        const std::uint64_t incomplete =
            ((std::uint64_t)timestamp << 32) |
            ((std::uint64_t)pid << 5) |
            (VCAM_REAL_HOOK_RUNTIME_REQUIRED_FLAGS & ~missing);
        Check(!vcam_real_hook_runtime_state_is_valid_fresh(
                  incomplete, timestamp),
              "incomplete flags rejected");
    }

    if (failures == 0) {
        std::cout
            << "PROOF_STATE_PID_REQUIRED=PASS\n"
            << "PROOF_STATE_FRESHNESS_ENFORCED=PASS\n"
            << "PROOF_STATE_FUTURE_SKEW_ENFORCED=PASS\n"
            << "STALE_PASS_REJECTED=PASS\n"
            << "INCOMPLETE_FLAGS_REJECTED=PASS\n"
            << "ZERO_PID_REJECTED=PASS\n";
    }

    return failures == 0 ? 0 : 1;
}
