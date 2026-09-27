#include "FirstLocalPhotoSubstitutionDiagnosticProofState.h"

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
        vcam_first_photo_sub_diag_encode_primary(
            timestamp,
            pid,
            FirstPhotoSubDiagnosticClassification::
                OriginalGeometryMismatch);

    Check(
        vcam_first_photo_sub_diag_primary_timestamp(primary) ==
            timestamp,
        "primary timestamp decode");
    Check(
        vcam_first_photo_sub_diag_primary_pid(primary) ==
            pid,
        "primary pid decode");
    Check(
        vcam_first_photo_sub_diag_primary_classification(primary) ==
            FirstPhotoSubDiagnosticClassification::
                OriginalGeometryMismatch,
        "classification decode");
    Check(
        vcam_first_photo_sub_diag_primary_is_valid_fresh(
            primary,
            generation,
            timestamp),
        "fresh diagnostic accepted");
    Check(
        !vcam_first_photo_sub_diag_primary_is_valid_fresh(
            primary,
            0,
            timestamp),
        "zero generation rejected");

    const std::uint64_t counts =
        vcam_first_photo_sub_diag_encode_counts(
            240,
            240,
            5,
            5,
            235);
    Check(
        vcam_first_photo_sub_diag_callback_count(counts) == 240,
        "callback count transport");
    Check(
        vcam_first_photo_sub_diag_decision_count_delta(counts) == 240,
        "decision delta transport");
    Check(
        vcam_first_photo_sub_diag_virtual_decision_count_delta(counts) == 5,
        "virtual delta transport");
    Check(
        vcam_first_photo_sub_diag_decision_virtual_count(counts) == 5,
        "virtual decision count transport");
    Check(
        vcam_first_photo_sub_diag_decision_original_count(counts) == 235,
        "original decision count transport");

    const std::uint64_t fails =
        vcam_first_photo_sub_diag_encode_fail_counts(
            1, 2, 3, 4, 5, 220, 9);
    Check(vcam_first_photo_sub_diag_fail_disabled(fails) == 1,
          "disabled counter transport");
    Check(vcam_first_photo_sub_diag_fail_reconfiguration(fails) == 2,
          "reconfiguration counter transport");
    Check(vcam_first_photo_sub_diag_fail_producer(fails) == 3,
          "producer counter transport");
    Check(vcam_first_photo_sub_diag_fail_empty(fails) == 4,
          "empty counter transport");
    Check(vcam_first_photo_sub_diag_fail_invalid_lease(fails) == 5,
          "invalid lease counter transport");
    Check(vcam_first_photo_sub_diag_fail_geometry(fails) == 220,
          "geometry mismatch counter transport");
    Check(vcam_first_photo_sub_diag_geometry_change_count(fails) == 9,
          "geometry change transport");

    const std::uint64_t geometry =
        vcam_first_photo_sub_diag_encode_geometry(
            1920,
            1080,
            UINT32_C(875704438));
    Check(vcam_first_photo_sub_diag_geometry_width(geometry) == 1920,
          "geometry width decode");
    Check(vcam_first_photo_sub_diag_geometry_height(geometry) == 1080,
          "geometry height decode");
    Check(vcam_first_photo_sub_diag_geometry_pixel_format(geometry) ==
              UINT32_C(875704438),
          "geometry pixel format decode");

    const std::uint64_t session =
        vcam_first_photo_sub_diag_encode_session(
            3,
            true,
            true,
            true,
            true,
            true,
            true,
            FirstPhotoSubDiagnosticPlaybackState::Playing,
            FirstPhotoSubDiagnosticMediaKind::Photo);

    Check(vcam_first_photo_sub_diag_ready_frame_count(session) == 3,
          "ready count transport");
    Check(vcam_first_photo_sub_diag_vcam_enabled(session),
          "vcam enabled transport");
    Check(vcam_first_photo_sub_diag_photo_selected(session),
          "photo selected transport");
    Check(vcam_first_photo_sub_diag_producer_healthy(session),
          "producer healthy transport");
    Check(vcam_first_photo_sub_diag_session_exists(session),
          "session exists transport");
    Check(vcam_first_photo_sub_diag_selected_valid(session),
          "selected valid transport");
    Check(vcam_first_photo_sub_diag_selected_path_match(session),
          "path match transport");
    Check(vcam_first_photo_sub_diag_playback_state(session) ==
              FirstPhotoSubDiagnosticPlaybackState::Playing,
          "playback state transport");
    Check(vcam_first_photo_sub_diag_selected_media_kind(session) ==
              FirstPhotoSubDiagnosticMediaKind::Photo,
          "selected media kind transport");

    const std::uint64_t last =
        vcam_first_photo_sub_diag_encode_last(
            FirstPhotoSubDiagnosticDecision::Virtual,
            FirstPhotoSubDiagnosticReason::None,
            true,
            true,
            true,
            true,
            true,
            true);

    Check(vcam_first_photo_sub_diag_last_decision(last) ==
              FirstPhotoSubDiagnosticDecision::Virtual,
          "last decision transport");
    Check(vcam_first_photo_sub_diag_last_reason(last) ==
              FirstPhotoSubDiagnosticReason::None,
          "last reason transport");
    Check(vcam_first_photo_sub_diag_virtual_non_null(last),
          "virtual non-null transport");
    Check(vcam_first_photo_sub_diag_virtual_different(last),
          "virtual different transport");
    Check(vcam_first_photo_sub_diag_width_match(last),
          "width match transport");
    Check(vcam_first_photo_sub_diag_height_match(last),
          "height match transport");
    Check(vcam_first_photo_sub_diag_pixel_format_match(last),
          "pixel format match transport");
    Check(vcam_first_photo_sub_diag_geometry_match(last),
          "geometry match transport");

    const std::uint64_t future =
        vcam_first_photo_sub_diag_encode_primary(
            timestamp + 5U,
            pid,
            FirstPhotoSubDiagnosticClassification::
                VirtualDecisionObserved);
    Check(
        vcam_first_photo_sub_diag_primary_is_valid_fresh(
            future,
            generation,
            timestamp),
        "bounded future skew accepted");

    const std::uint64_t farFuture =
        vcam_first_photo_sub_diag_encode_primary(
            timestamp + 6U,
            pid,
            FirstPhotoSubDiagnosticClassification::
                VirtualDecisionObserved);
    Check(
        !vcam_first_photo_sub_diag_primary_is_valid_fresh(
            farFuture,
            generation,
            timestamp),
        "excess future skew rejected");

    const std::uint64_t stale =
        vcam_first_photo_sub_diag_encode_primary(
            timestamp,
            pid,
            FirstPhotoSubDiagnosticClassification::
                OriginalMixedFailOpen);
    Check(
        !vcam_first_photo_sub_diag_primary_is_valid_fresh(
            stale,
            generation,
            timestamp + 181U),
        "stale state rejected");

    const std::uint64_t zeroPid =
        vcam_first_photo_sub_diag_encode_primary(
            timestamp,
            0,
            FirstPhotoSubDiagnosticClassification::
                NoGenuineCallbackObserved);
    Check(
        !vcam_first_photo_sub_diag_primary_is_valid_fresh(
            zeroPid,
            generation,
            timestamp),
        "zero pid rejected");

    if (failures == 0) {
        std::cout
            << "DIAGNOSTIC_PRIMARY_ENCODING=PASS\n"
            << "CALLBACK_DECISION_COUNTS_TRANSPORT=PASS\n"
            << "FAIL_OPEN_COUNTS_TRANSPORT=PASS\n"
            << "GEOMETRY_TRANSPORT=PASS\n"
            << "SESSION_STATE_TRANSPORT=PASS\n"
            << "LAST_DECISION_TRANSPORT=PASS\n"
            << "FRESHNESS_ENFORCED=PASS\n"
            << "FUTURE_SKEW_LIMIT_ENFORCED=PASS\n"
            << "NONZERO_PID_REQUIRED=PASS\n"
            << "STALE_STATE_REJECTED=PASS\n";
    }

    return failures == 0 ? 0 : 1;
}
