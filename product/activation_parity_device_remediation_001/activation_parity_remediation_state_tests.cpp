#include "ActivationParityDeviceRemediationProofState.h"

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
    constexpr std::uint64_t generation = UINT64_C(77);

    const std::uint64_t primary =
        vcam_activation_remediation_encode_primary(
            timestamp,
            pid,
            ActivationParityEncodedStage::PreparedMedia);

    Check(
        vcam_activation_remediation_primary_timestamp(primary) ==
            timestamp,
        "primary timestamp decode");
    Check(
        vcam_activation_remediation_primary_pid(primary) ==
            pid,
        "primary pid decode");
    Check(
        vcam_activation_remediation_primary_stage(primary) ==
            ActivationParityEncodedStage::PreparedMedia,
        "primary stage decode");
    Check(
        vcam_activation_remediation_primary_is_valid_fresh(
            primary,
            generation,
            timestamp),
        "fresh state accepted");
    Check(
        !vcam_activation_remediation_primary_is_valid_fresh(
            primary,
            0,
            timestamp),
        "zero generation rejected");

    const std::uint64_t session =
        vcam_activation_remediation_encode_session(
            3,
            2,
            1,
            2,
            2,
            0,
            VCAM_ACTIVATION_SESSION_EXISTS |
            VCAM_ACTIVATION_SESSION_SELECTED_VALID |
            VCAM_ACTIVATION_SESSION_SELECTED_PHOTO |
            VCAM_ACTIVATION_SESSION_PATH_MATCH |
            VCAM_ACTIVATION_SESSION_PRODUCER_HEALTHY |
            VCAM_ACTIVATION_SESSION_GEOMETRY_OBSERVED);

    Check(
        vcam_activation_remediation_ready_count(session) == 3,
        "ready count decode");
    Check(
        vcam_activation_remediation_replacement_count(session) == 2,
        "replacement count decode");
    Check(
        vcam_activation_remediation_playback_intent(session) == 1,
        "playback intent decode");
    Check(
        vcam_activation_remediation_playback_state(session) == 2,
        "playback state decode");
    Check(
        vcam_activation_remediation_reader_state(session) == 2,
        "reader state decode");
    Check(
        vcam_activation_remediation_reader_error(session) == 0,
        "reader error decode");
    Check(
        vcam_activation_remediation_session_flags(session) ==
            (VCAM_ACTIVATION_SESSION_EXISTS |
             VCAM_ACTIVATION_SESSION_SELECTED_VALID |
             VCAM_ACTIVATION_SESSION_SELECTED_PHOTO |
             VCAM_ACTIVATION_SESSION_PATH_MATCH |
             VCAM_ACTIVATION_SESSION_PRODUCER_HEALTHY |
             VCAM_ACTIVATION_SESSION_GEOMETRY_OBSERVED),
        "session flags decode");

    const std::uint64_t producer =
        vcam_activation_remediation_encode_producer(
            UINT64_C(1234),
            true,
            true);
    Check(
        vcam_activation_remediation_frame_sequence_count(producer) ==
            UINT64_C(1234),
        "frame sequence decode");
    Check(
        vcam_activation_remediation_start_attempted(producer),
        "start attempted decode");
    Check(
        vcam_activation_remediation_start_result(producer),
        "start result decode");

    const std::uint64_t stale =
        vcam_activation_remediation_encode_primary(
            timestamp,
            pid,
            ActivationParityEncodedStage::BlackFallback);
    Check(
        !vcam_activation_remediation_primary_is_valid_fresh(
            stale,
            generation,
            timestamp + 181U),
        "stale state rejected");

    const std::uint64_t future =
        vcam_activation_remediation_encode_primary(
            timestamp + 5U,
            pid,
            ActivationParityEncodedStage::WaitingGeometry);
    Check(
        vcam_activation_remediation_primary_is_valid_fresh(
            future,
            generation,
            timestamp),
        "future skew boundary accepted");

    const std::uint64_t farFuture =
        vcam_activation_remediation_encode_primary(
            timestamp + 6U,
            pid,
            ActivationParityEncodedStage::WaitingGeometry);
    Check(
        !vcam_activation_remediation_primary_is_valid_fresh(
            farFuture,
            generation,
            timestamp),
        "excess future skew rejected");

    const std::uint64_t zeroPid =
        vcam_activation_remediation_encode_primary(
            timestamp,
            0,
            ActivationParityEncodedStage::QueueEmpty);
    Check(
        !vcam_activation_remediation_primary_is_valid_fresh(
            zeroPid,
            generation,
            timestamp),
        "zero pid rejected");

    if (failures == 0) {
        std::cout
            << "ACTIVATION_REMEDIATION_STATE_ENCODING=PASS\n"
            << "ACTIVATION_REMEDIATION_FRESHNESS=PASS\n"
            << "ACTIVATION_REMEDIATION_GENERATION_BINDING=PASS\n"
            << "ACTIVATION_REMEDIATION_SESSION_FIELDS=PASS\n"
            << "ACTIVATION_REMEDIATION_PRODUCER_FIELDS=PASS\n";
    }

    return failures == 0 ? 0 : 1;
}
