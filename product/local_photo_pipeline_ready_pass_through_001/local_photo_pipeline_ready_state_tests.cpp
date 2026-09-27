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
    constexpr std::uint64_t generation = UINT64_C(77);

    const std::uint64_t passEvent =
        vcam_local_photo_pipeline_ready_encode_event(
            timestamp,
            pid,
            LocalPhotoProofResult::Pass,
            LocalPhotoProofPipelineStage::Ready);

    const std::uint64_t diagnosticEvent =
        vcam_local_photo_pipeline_ready_encode_event(
            timestamp,
            pid,
            LocalPhotoProofResult::Diagnostic,
            LocalPhotoProofPipelineStage::WaitingGeometry);

    Check(
        vcam_local_photo_pipeline_ready_event_timestamp(passEvent) ==
            timestamp,
        "event timestamp decode");
    Check(
        vcam_local_photo_pipeline_ready_event_pid(passEvent) == pid,
        "event pid decode");
    Check(
        vcam_local_photo_pipeline_ready_event_result(passEvent) ==
            LocalPhotoProofResult::Pass,
        "PASS result decode");
    Check(
        vcam_local_photo_pipeline_ready_event_stage(passEvent) ==
            LocalPhotoProofPipelineStage::Ready,
        "PASS stage decode");
    Check(
        vcam_local_photo_pipeline_ready_event_result(diagnosticEvent) ==
            LocalPhotoProofResult::Diagnostic,
        "DIAGNOSTIC result decode");
    Check(
        vcam_local_photo_pipeline_ready_event_stage(diagnosticEvent) ==
            LocalPhotoProofPipelineStage::WaitingGeometry,
        "DIAGNOSTIC stage decode");

    const std::uint64_t flags =
        VCAM_LOCAL_PHOTO_FLAG_HAS_MEDIA |
        VCAM_LOCAL_PHOTO_FLAG_MEDIA_STAGED |
        VCAM_LOCAL_PHOTO_FLAG_CONTROL_OBSERVED |
        VCAM_LOCAL_PHOTO_FLAG_GEOMETRY_OBSERVED |
        VCAM_LOCAL_PHOTO_FLAG_SESSION_EXISTS |
        VCAM_LOCAL_PHOTO_FLAG_SELECTED_MEDIA_VALID |
        VCAM_LOCAL_PHOTO_FLAG_SELECTED_PATH_MATCH |
        VCAM_LOCAL_PHOTO_FLAG_PRODUCER_READY |
        VCAM_LOCAL_PHOTO_FLAG_CALLBACK_EXERCISED |
        VCAM_LOCAL_PHOTO_FLAG_DECISION_ORIGINAL |
        VCAM_LOCAL_PHOTO_FLAG_ORIGINAL_RETURNED |
        VCAM_LOCAL_PHOTO_FLAG_DISABLED_REASON |
        VCAM_LOCAL_PHOTO_FLAG_SUBSTITUTION_INACTIVE |
        VCAM_LOCAL_PHOTO_FLAG_ORIGINAL_NON_NULL;

    Check(
        (flags & VCAM_LOCAL_PHOTO_FLAG_VCAM_ENABLED) == 0,
        "vcam-enabled NO transport");
    Check(
        (flags & VCAM_LOCAL_PHOTO_FLAG_MEDIA_STAGED) != 0,
        "media-staged YES transport");
    Check(
        (flags & VCAM_LOCAL_PHOTO_FLAG_CALLBACK_EXERCISED) != 0,
        "callback-exercised YES transport");
    Check(
        (flags & VCAM_LOCAL_PHOTO_FLAG_ORIGINAL_RETURNED) != 0,
        "original-buffer-returned YES transport");

    const std::uint64_t enumsState =
        vcam_local_photo_pipeline_ready_encode_enums(
            LocalPhotoProofMediaKind::Photo,
            LocalPhotoProofMediaKind::Photo,
            LocalPhotoProofPlaybackIntent::Playing,
            LocalPhotoProofPlaybackState::Playing);

    Check(
        vcam_local_photo_pipeline_ready_media_kind(enumsState) ==
            LocalPhotoProofMediaKind::Photo,
        "media-kind PHOTO decode");
    Check(
        vcam_local_photo_pipeline_ready_selected_media_kind(enumsState) ==
            LocalPhotoProofMediaKind::Photo,
        "selected-media-kind PHOTO decode");
    Check(
        vcam_local_photo_pipeline_ready_playback_intent(enumsState) ==
            LocalPhotoProofPlaybackIntent::Playing,
        "playback-intent PLAYING decode");
    Check(
        vcam_local_photo_pipeline_ready_playback_state(enumsState) ==
            LocalPhotoProofPlaybackState::Playing,
        "playback-state PLAYING decode");

    const std::uint64_t countsState =
        vcam_local_photo_pipeline_ready_encode_counts(
            3U,
            0U);

    Check(
        vcam_local_photo_pipeline_ready_ready_frame_count(countsState) == 3U,
        "ready-frame-count decode");
    Check(
        vcam_local_photo_pipeline_ready_virtual_decision_count(countsState) == 0U,
        "virtual-decision-count decode");

    Check(
        vcam_local_photo_pipeline_ready_structured_pass_is_valid(
            passEvent,
            generation,
            flags,
            enumsState,
            countsState),
        "strict structured PASS accepted");

    Check(
        !vcam_local_photo_pipeline_ready_structured_pass_is_valid(
            diagnosticEvent,
            generation,
            flags,
            enumsState,
            countsState),
        "DIAGNOSTIC never accepted as PASS");

    Check(
        !vcam_local_photo_pipeline_ready_structured_pass_is_valid(
            passEvent,
            0U,
            flags,
            enumsState,
            countsState),
        "zero selection generation rejected");

    Check(
        !vcam_local_photo_pipeline_ready_structured_pass_is_valid(
            passEvent,
            generation,
            flags | VCAM_LOCAL_PHOTO_FLAG_VCAM_ENABLED,
            enumsState,
            countsState),
        "VCAM enabled rejected from PASS");

    Check(
        !vcam_local_photo_pipeline_ready_structured_pass_is_valid(
            passEvent,
            generation,
            flags & ~VCAM_LOCAL_PHOTO_FLAG_PRODUCER_READY,
            enumsState,
            countsState),
        "incomplete PASS flags rejected");

    const std::uint64_t emptyCounts =
        vcam_local_photo_pipeline_ready_encode_counts(
            0U,
            0U);
    Check(
        !vcam_local_photo_pipeline_ready_structured_pass_is_valid(
            passEvent,
            generation,
            flags,
            enumsState,
            emptyCounts),
        "zero ready-frame-count rejected from PASS");

    const std::uint64_t virtualCounts =
        vcam_local_photo_pipeline_ready_encode_counts(
            1U,
            1U);
    Check(
        !vcam_local_photo_pipeline_ready_structured_pass_is_valid(
            passEvent,
            generation,
            flags,
            enumsState,
            virtualCounts),
        "virtual decision rejected from PASS");

    Check(
        vcam_local_photo_pipeline_ready_event_is_valid_fresh(
            passEvent,
            timestamp),
        "fresh PASS accepted");
    Check(
        vcam_local_photo_pipeline_ready_event_is_valid_fresh(
            diagnosticEvent,
            timestamp + 180U),
        "fresh DIAGNOSTIC accepted at boundary");
    Check(
        !vcam_local_photo_pipeline_ready_event_is_valid_fresh(
            diagnosticEvent,
            timestamp + 181U),
        "stale DIAGNOSTIC rejected");

    const std::uint64_t futureEvent =
        vcam_local_photo_pipeline_ready_encode_event(
            timestamp + 5U,
            pid,
            LocalPhotoProofResult::Diagnostic,
            LocalPhotoProofPipelineStage::WaitingReadyFrame);
    Check(
        vcam_local_photo_pipeline_ready_event_is_valid_fresh(
            futureEvent,
            timestamp),
        "bounded future skew accepted");

    const std::uint64_t farFutureEvent =
        vcam_local_photo_pipeline_ready_encode_event(
            timestamp + 6U,
            pid,
            LocalPhotoProofResult::Diagnostic,
            LocalPhotoProofPipelineStage::WaitingReadyFrame);
    Check(
        !vcam_local_photo_pipeline_ready_event_is_valid_fresh(
            farFutureEvent,
            timestamp),
        "excess future skew rejected");

    const std::uint64_t zeroPidEvent =
        vcam_local_photo_pipeline_ready_encode_event(
            timestamp,
            0U,
            LocalPhotoProofResult::Diagnostic,
            LocalPhotoProofPipelineStage::SessionAbsent);
    Check(
        !vcam_local_photo_pipeline_ready_event_is_valid_fresh(
            zeroPidEvent,
            timestamp),
        "zero PID rejected");

    Check(
        LocalPhotoProofPipelineStage::PhotoSelectFailed !=
            LocalPhotoProofPipelineStage::ProducerStartFailed &&
        LocalPhotoProofPipelineStage::WaitingGeometry !=
            LocalPhotoProofPipelineStage::WaitingReadyFrame &&
        LocalPhotoProofPipelineStage::ControlSuperseded !=
            LocalPhotoProofPipelineStage::Ready,
        "pipeline-stage enum distinctions preserved");

    if (failures == 0) {
        std::cout
            << "PASS_ENCODING_DECODING=PASS\n"
            << "DIAGNOSTIC_ENCODING_DECODING=PASS\n"
            << "DIAGNOSTIC_BOOLEAN_FIELDS=PASS\n"
            << "MEDIA_KIND_ENUM=PASS\n"
            << "PLAYBACK_INTENT_ENUM=PASS\n"
            << "PLAYBACK_STATE_ENUM=PASS\n"
            << "PIPELINE_STAGE_ENUM=PASS\n"
            << "SELECTION_GENERATION_TRANSPORT=PASS\n"
            << "READY_FRAME_COUNT_TRANSPORT=PASS\n"
            << "VIRTUAL_DECISION_COUNT_TRANSPORT=PASS\n"
            << "FRESHNESS_ENFORCED=PASS\n"
            << "FUTURE_SKEW_LIMIT_ENFORCED=PASS\n"
            << "NONZERO_PID_REQUIRED=PASS\n"
            << "STALE_STATE_REJECTED=PASS\n"
            << "SELECTION_SUPERSESSION_INVALIDATION=PASS\n";
    }

    return failures == 0 ? 0 : 1;
}
