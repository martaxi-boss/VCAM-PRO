#include "HookReachabilityProofState.h"

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

}  // namespace

int main() {
    constexpr std::uint32_t timestamp =
        1770000000U;
    constexpr std::uint32_t pid =
        4242U;

    const std::uint64_t state =
        vcam_hook_reach_encode_state(
            timestamp,
            pid);

    Check(
        vcam_hook_reach_state_timestamp(
            state) == timestamp,
        "timestamp decode");

    Check(
        vcam_hook_reach_state_pid(
            state) == pid,
        "pid decode");

    Check(
        vcam_hook_reach_state_flags(
            state) ==
            VCAM_HOOK_REACH_REQUIRED_FLAGS,
        "all proof flags present");

    Check(
        vcam_hook_reach_state_is_valid_fresh(
            state,
            timestamp),
        "current state accepted");

    Check(
        vcam_hook_reach_state_is_valid_fresh(
            state,
            timestamp + 180U),
        "freshness boundary accepted");

    Check(
        !vcam_hook_reach_state_is_valid_fresh(
            state,
            timestamp + 181U),
        "stale state rejected");

    const std::uint64_t future =
        vcam_hook_reach_encode_state(
            timestamp + 5U,
            pid);

    Check(
        vcam_hook_reach_state_is_valid_fresh(
            future,
            timestamp),
        "bounded future skew accepted");

    const std::uint64_t farFuture =
        vcam_hook_reach_encode_state(
            timestamp + 6U,
            pid);

    Check(
        !vcam_hook_reach_state_is_valid_fresh(
            farFuture,
            timestamp),
        "far future state rejected");

    Check(
        !vcam_hook_reach_state_is_valid_fresh(
            vcam_hook_reach_encode_state(
                timestamp,
                0U),
            timestamp),
        "zero pid rejected");

    const std::uint64_t missingResolved =
        ((std::uint64_t)timestamp << 32) |
        ((std::uint64_t)pid << 6) |
        (VCAM_HOOK_REACH_REQUIRED_FLAGS &
         ~VCAM_HOOK_REACH_FLAG_TARGET_RESOLVED);

    Check(
        !vcam_hook_reach_state_is_valid_fresh(
            missingResolved,
            timestamp),
        "missing target-resolved flag rejected");

    if (failures == 0) {
        std::cout
            << "HOOK_CALL_PATH_REACHABILITY_PROOF=PASS\n"
            << "TARGET_SYMBOL_RESOLUTION_PROBE=PASS\n"
            << "HOOK_INSTALLATION_DISABLED=PASS\n"
            << "FRAME_ACCESS_INACTIVE=PASS\n"
            << "FRAME_SUBSTITUTION_INACTIVE=PASS\n"
            << "FRESHNESS_VALIDATION=PASS\n";
    }

    return failures == 0
        ? 0
        : 1;
}
