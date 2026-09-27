#include "RuntimeGateProofState.h"

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
        vcam_runtime_gate_encode_state(
            timestamp,
            pid);

    Check(
        vcam_runtime_gate_state_timestamp(
            state) == timestamp,
        "timestamp decode");

    Check(
        vcam_runtime_gate_state_pid(
            state) == pid,
        "pid decode");

    Check(
        vcam_runtime_gate_state_flags(
            state) ==
            VCAM_RUNTIME_GATE_REQUIRED_FLAGS,
        "required gate flags");

    Check(
        vcam_runtime_gate_state_is_valid_fresh(
            state,
            timestamp),
        "current state accepted");

    Check(
        vcam_runtime_gate_state_is_valid_fresh(
            state,
            timestamp + 180U),
        "freshness boundary accepted");

    Check(
        !vcam_runtime_gate_state_is_valid_fresh(
            state,
            timestamp + 181U),
        "stale state rejected");

    const std::uint64_t future =
        vcam_runtime_gate_encode_state(
            timestamp + 5U,
            pid);

    Check(
        vcam_runtime_gate_state_is_valid_fresh(
            future,
            timestamp),
        "bounded future skew accepted");

    const std::uint64_t farFuture =
        vcam_runtime_gate_encode_state(
            timestamp + 6U,
            pid);

    Check(
        !vcam_runtime_gate_state_is_valid_fresh(
            farFuture,
            timestamp),
        "far future state rejected");

    Check(
        !vcam_runtime_gate_state_is_valid_fresh(
            vcam_runtime_gate_encode_state(
                timestamp,
                0U),
            timestamp),
        "zero pid rejected");

    const std::uint64_t missingHookDisabled =
        ((std::uint64_t)timestamp << 32) |
        ((std::uint64_t)pid << 2) |
        VCAM_RUNTIME_GATE_FLAG_RUNTIME_START_PASS;

    Check(
        !vcam_runtime_gate_state_is_valid_fresh(
            missingHookDisabled,
            timestamp),
        "missing hook-disabled flag rejected");

    if (failures == 0) {
        std::cout
            << "RUNTIME_START_PROOF_CHANNEL=PASS\n"
            << "RUNTIME_START_PASS_FLAG=PASS\n"
            << "REFERENCE_HOOK_DISABLED_FLAG=PASS\n"
            << "FRESHNESS_VALIDATION=PASS\n";
    }

    return failures == 0
        ? 0
        : 1;
}
