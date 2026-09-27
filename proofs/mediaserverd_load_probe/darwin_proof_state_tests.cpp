#include "DarwinProofState.h"

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
    constexpr uint32_t timestamp =
        1770000000U;
    constexpr uint32_t pid =
        4242U;

    const uint64_t state =
        vcam_pro_encode_load_state(
            timestamp,
            pid);

    Check(
        vcam_pro_load_state_timestamp(
            state) == timestamp,
        "timestamp decode");

    Check(
        vcam_pro_load_state_pid(
            state) == pid,
        "pid decode");

    Check(
        vcam_pro_load_state_is_fresh(
            state,
            timestamp),
        "fresh current state");

    Check(
        vcam_pro_load_state_is_fresh(
            state,
            timestamp + 180U),
        "fresh boundary accepted");

    Check(
        !vcam_pro_load_state_is_fresh(
            state,
            timestamp + 181U),
        "stale state rejected");

    const uint64_t nearFuture =
        vcam_pro_encode_load_state(
            timestamp + 5U,
            pid);

    Check(
        vcam_pro_load_state_is_fresh(
            nearFuture,
            timestamp),
        "bounded clock skew accepted");

    const uint64_t farFuture =
        vcam_pro_encode_load_state(
            timestamp + 6U,
            pid);

    Check(
        !vcam_pro_load_state_is_fresh(
            farFuture,
            timestamp),
        "far future state rejected");

    Check(
        !vcam_pro_load_state_is_fresh(
            vcam_pro_encode_load_state(
                timestamp,
                0U),
            timestamp),
        "zero pid rejected");

    Check(
        !vcam_pro_load_state_is_fresh(
            0U,
            timestamp),
        "zero state rejected");

    if (failures == 0) {
        std::cout
            << "STATEFUL_DARWIN_SIGNAL=PASS\n"
            << "VERSIONED_SIGNAL=PASS\n"
            << "FRESHNESS_VALIDATION=PASS\n";
    }

    return failures == 0
        ? 0
        : 1;
}
