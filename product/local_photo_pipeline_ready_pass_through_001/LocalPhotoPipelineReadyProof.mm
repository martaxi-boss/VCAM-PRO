#include "LocalPhotoPipelineReadyProof.h"

#include <notify.h>
#include <os/log.h>
#include <time.h>
#include <unistd.h>

#include <atomic>
#include <cstdint>
#include <limits>

namespace vcam::product::proof {

namespace {

std::atomic<std::uint64_t> gActiveGeneration{0};
std::atomic<std::uint64_t> gCallbackSequence{0};
std::atomic<std::uint64_t> gCallbackGeneration{0};
std::atomic<std::uint64_t> gCallbackFlags{0};
std::atomic<std::uint64_t> gCallbackVirtualDecisionCount{0};
std::atomic<bool> gPublished{false};

int gEventToken = -1;
int gSelectionToken = -1;
int gFlagsToken = -1;
int gEnumsToken = -1;
int gCountsToken = -1;

bool RegisterStateToken(
    const char* name,
    int* token) noexcept {
    if (name == nullptr ||
        token == nullptr) {
        return false;
    }

    int value = 0;
    if (notify_register_check(
            name,
            &value) != NOTIFY_STATUS_OK) {
        return false;
    }

    *token = value;
    return true;
}

void CancelToken(int* token) noexcept {
    if (token != nullptr &&
        *token >= 0) {
        (void)notify_cancel(*token);
        *token = -1;
    }
}

void ClearPublishedStates() noexcept {
    if (gEventToken >= 0) {
        (void)notify_set_state(
            gEventToken,
            UINT64_C(0));
    }
    if (gSelectionToken >= 0) {
        (void)notify_set_state(
            gSelectionToken,
            UINT64_C(0));
    }
    if (gFlagsToken >= 0) {
        (void)notify_set_state(
            gFlagsToken,
            UINT64_C(0));
    }
    if (gEnumsToken >= 0) {
        (void)notify_set_state(
            gEnumsToken,
            UINT64_C(0));
    }
    if (gCountsToken >= 0) {
        (void)notify_set_state(
            gCountsToken,
            UINT64_C(0));
    }
}

uint64_t DiagnosticFlags(
    const LocalPhotoDiagnosticSnapshot& snapshot) noexcept {
    uint64_t flags = 0;

    if (snapshot.vcamEnabled) {
        flags |= VCAM_LOCAL_PHOTO_FLAG_VCAM_ENABLED;
    }
    if (snapshot.hasMedia) {
        flags |= VCAM_LOCAL_PHOTO_FLAG_HAS_MEDIA;
    }
    if (snapshot.mediaStaged) {
        flags |= VCAM_LOCAL_PHOTO_FLAG_MEDIA_STAGED;
    }
    if (snapshot.controlObserved) {
        flags |= VCAM_LOCAL_PHOTO_FLAG_CONTROL_OBSERVED;
    }
    if (snapshot.cameraGeometryObserved) {
        flags |= VCAM_LOCAL_PHOTO_FLAG_GEOMETRY_OBSERVED;
    }
    if (snapshot.sessionExists) {
        flags |= VCAM_LOCAL_PHOTO_FLAG_SESSION_EXISTS;
    }
    if (snapshot.selectedMediaValid) {
        flags |= VCAM_LOCAL_PHOTO_FLAG_SELECTED_MEDIA_VALID;
    }
    if (snapshot.selectedMediaPathMatches) {
        flags |= VCAM_LOCAL_PHOTO_FLAG_SELECTED_PATH_MATCH;
    }
    if (snapshot.producerReady) {
        flags |= VCAM_LOCAL_PHOTO_FLAG_PRODUCER_READY;
    }
    if (snapshot.callbackExercised) {
        flags |= VCAM_LOCAL_PHOTO_FLAG_CALLBACK_EXERCISED;
    }
    if (snapshot.decisionOriginal) {
        flags |= VCAM_LOCAL_PHOTO_FLAG_DECISION_ORIGINAL;
    }
    if (snapshot.originalBufferReturned) {
        flags |= VCAM_LOCAL_PHOTO_FLAG_ORIGINAL_RETURNED;
    }
    if (snapshot.disabledReason) {
        flags |= VCAM_LOCAL_PHOTO_FLAG_DISABLED_REASON;
    }
    if (snapshot.virtualDecisionCount == 0U) {
        flags |= VCAM_LOCAL_PHOTO_FLAG_SUBSTITUTION_INACTIVE;
    }
    if (snapshot.originalNonNull) {
        flags |= VCAM_LOCAL_PHOTO_FLAG_ORIGINAL_NON_NULL;
    }

    return flags;
}

bool SnapshotEstablishesPass(
    const LocalPhotoDiagnosticSnapshot& snapshot) noexcept {
    if (snapshot.selectionGeneration == 0 ||
        snapshot.vcamEnabled ||
        snapshot.mediaKind !=
            LocalPhotoProofMediaKind::Photo ||
        !snapshot.hasMedia ||
        !snapshot.mediaStaged ||
        !snapshot.controlObserved ||
        !snapshot.cameraGeometryObserved ||
        !snapshot.sessionExists ||
        !snapshot.selectedMediaValid ||
        snapshot.selectedMediaKind !=
            LocalPhotoProofMediaKind::Photo ||
        !snapshot.selectedMediaPathMatches ||
        snapshot.playbackIntent !=
            LocalPhotoProofPlaybackIntent::Playing ||
        snapshot.playbackState !=
            LocalPhotoProofPlaybackState::Playing ||
        !snapshot.producerReady ||
        snapshot.readyFrameCount == 0 ||
        !snapshot.callbackExercised ||
        !snapshot.originalNonNull ||
        !snapshot.decisionOriginal ||
        !snapshot.disabledReason ||
        !snapshot.originalBufferReturned ||
        snapshot.virtualDecisionCount != 0 ||
        snapshot.pipelineStage !=
            LocalPhotoProofPipelineStage::Ready) {
        return false;
    }

    const uint64_t flags =
        DiagnosticFlags(snapshot);
    const uint64_t enumsState =
        vcam_local_photo_pipeline_ready_encode_enums(
            snapshot.mediaKind,
            snapshot.selectedMediaKind,
            snapshot.playbackIntent,
            snapshot.playbackState);
    const uint64_t countsState =
        vcam_local_photo_pipeline_ready_encode_counts(
            snapshot.readyFrameCount,
            snapshot.virtualDecisionCount);
    const uint64_t syntheticEvent =
        vcam_local_photo_pipeline_ready_encode_event(
            1U,
            1U,
            LocalPhotoProofResult::Pass,
            snapshot.pipelineStage);

    return
        vcam_local_photo_pipeline_ready_structured_pass_is_valid(
            syntheticEvent,
            snapshot.selectionGeneration,
            flags,
            enumsState,
            countsState) != 0;
}

}  // namespace

void ResetLocalPhotoPipelineReadyProofState() noexcept {
    gActiveGeneration.store(
        0,
        std::memory_order_release);
    gCallbackSequence.store(
        0,
        std::memory_order_release);
    gCallbackGeneration.store(
        0,
        std::memory_order_release);
    gCallbackFlags.store(
        0,
        std::memory_order_release);
    gCallbackVirtualDecisionCount.store(
        0,
        std::memory_order_release);
    gPublished.store(
        false,
        std::memory_order_release);

    CancelToken(&gEventToken);
    CancelToken(&gSelectionToken);
    CancelToken(&gFlagsToken);
    CancelToken(&gEnumsToken);
    CancelToken(&gCountsToken);

    if (!RegisterStateToken(
            VCAM_LOCAL_PHOTO_PIPELINE_READY_NOTIFICATION,
            &gEventToken) ||
        !RegisterStateToken(
            VCAM_LOCAL_PHOTO_PIPELINE_READY_SELECTION_STATE,
            &gSelectionToken) ||
        !RegisterStateToken(
            VCAM_LOCAL_PHOTO_PIPELINE_READY_FLAGS_STATE,
            &gFlagsToken) ||
        !RegisterStateToken(
            VCAM_LOCAL_PHOTO_PIPELINE_READY_ENUMS_STATE,
            &gEnumsToken) ||
        !RegisterStateToken(
            VCAM_LOCAL_PHOTO_PIPELINE_READY_COUNTS_STATE,
            &gCountsToken)) {
        CancelToken(&gEventToken);
        CancelToken(&gSelectionToken);
        CancelToken(&gFlagsToken);
        CancelToken(&gEnumsToken);
        CancelToken(&gCountsToken);
        return;
    }

    ClearPublishedStates();
}

void BeginLocalPhotoPipelineSelection(
    std::uint64_t selectionGeneration) noexcept {
    const std::uint64_t previous =
        gActiveGeneration.exchange(
            selectionGeneration,
            std::memory_order_acq_rel);

    if (previous == selectionGeneration) {
        return;
    }

    gCallbackSequence.fetch_add(
        1,
        std::memory_order_acq_rel);
    gCallbackGeneration.store(
        0,
        std::memory_order_relaxed);
    gCallbackFlags.store(
        0,
        std::memory_order_relaxed);
    gCallbackVirtualDecisionCount.store(
        0,
        std::memory_order_relaxed);
    gCallbackSequence.fetch_add(
        1,
        std::memory_order_release);

    gPublished.store(
        false,
        std::memory_order_release);

    ClearPublishedStates();
}

void ObserveLocalPhotoCallbackPhase(
    const LocalPhotoCallbackFacts& facts) noexcept {
    if (facts.selectionGeneration == 0 ||
        gActiveGeneration.load(
            std::memory_order_acquire) !=
            facts.selectionGeneration) {
        return;
    }

    uint64_t flags = 0;
    if (facts.callbackExercised) {
        flags |=
            VCAM_LOCAL_PHOTO_FLAG_CALLBACK_EXERCISED;
    }
    if (facts.originalNonNull) {
        flags |=
            VCAM_LOCAL_PHOTO_FLAG_ORIGINAL_NON_NULL;
    }
    if (facts.decisionOriginal) {
        flags |=
            VCAM_LOCAL_PHOTO_FLAG_DECISION_ORIGINAL;
    }
    if (facts.disabledReason) {
        flags |=
            VCAM_LOCAL_PHOTO_FLAG_DISABLED_REASON;
    }
    if (facts.originalBufferReturned) {
        flags |=
            VCAM_LOCAL_PHOTO_FLAG_ORIGINAL_RETURNED;
    }

    if (facts.decisionCountBefore !=
            std::numeric_limits<std::uint64_t>::max() &&
        facts.decisionCountAfter ==
            facts.decisionCountBefore + 1U) {
        flags |= UINT64_C(0x8000000000000000);
    }

    gCallbackSequence.fetch_add(
        1,
        std::memory_order_acq_rel);
    gCallbackGeneration.store(
        facts.selectionGeneration,
        std::memory_order_relaxed);
    gCallbackFlags.store(
        flags,
        std::memory_order_relaxed);
    gCallbackVirtualDecisionCount.store(
        facts.virtualDecisionCount,
        std::memory_order_relaxed);
    gCallbackSequence.fetch_add(
        1,
        std::memory_order_release);
}

bool ReadLocalPhotoCallbackSnapshot(
    std::uint64_t selectionGeneration,
    LocalPhotoCallbackSnapshot* snapshot) noexcept {
    if (selectionGeneration == 0 ||
        snapshot == nullptr) {
        return false;
    }

    for (int attempt = 0;
         attempt < 3;
         ++attempt) {
        const uint64_t before =
            gCallbackSequence.load(
                std::memory_order_acquire);
        if ((before & UINT64_C(1)) != 0) {
            continue;
        }

        const uint64_t generation =
            gCallbackGeneration.load(
                std::memory_order_relaxed);
        const uint64_t flags =
            gCallbackFlags.load(
                std::memory_order_relaxed);
        const uint64_t virtualCount =
            gCallbackVirtualDecisionCount.load(
                std::memory_order_relaxed);

        const uint64_t after =
            gCallbackSequence.load(
                std::memory_order_acquire);

        if (before != after ||
            (after & UINT64_C(1)) != 0) {
            continue;
        }

        if (generation != selectionGeneration) {
            return false;
        }

        snapshot->callbackExercised =
            (flags &
             VCAM_LOCAL_PHOTO_FLAG_CALLBACK_EXERCISED) != 0;
        snapshot->originalNonNull =
            (flags &
             VCAM_LOCAL_PHOTO_FLAG_ORIGINAL_NON_NULL) != 0;
        snapshot->decisionOriginal =
            (flags &
             VCAM_LOCAL_PHOTO_FLAG_DECISION_ORIGINAL) != 0;
        snapshot->disabledReason =
            (flags &
             VCAM_LOCAL_PHOTO_FLAG_DISABLED_REASON) != 0;
        snapshot->originalBufferReturned =
            (flags &
             VCAM_LOCAL_PHOTO_FLAG_ORIGINAL_RETURNED) != 0;
        snapshot->virtualDecisionCount =
            virtualCount;
        return true;
    }

    return false;
}

bool PublishLocalPhotoPipelineSnapshot(
    const LocalPhotoDiagnosticSnapshot& snapshot,
    LocalPhotoProofResult result) noexcept {
    if (snapshot.selectionGeneration == 0 ||
        gActiveGeneration.load(
            std::memory_order_acquire) !=
            snapshot.selectionGeneration ||
        (result != LocalPhotoProofResult::Pass &&
         result != LocalPhotoProofResult::Diagnostic) ||
        (result == LocalPhotoProofResult::Pass &&
         !SnapshotEstablishesPass(snapshot))) {
        return false;
    }

    bool expected = false;
    if (!gPublished.compare_exchange_strong(
            expected,
            true,
            std::memory_order_acq_rel,
            std::memory_order_acquire)) {
        return false;
    }

    if (gEventToken < 0 ||
        gSelectionToken < 0 ||
        gFlagsToken < 0 ||
        gEnumsToken < 0 ||
        gCountsToken < 0 ||
        gActiveGeneration.load(
            std::memory_order_acquire) !=
            snapshot.selectionGeneration) {
        gPublished.store(
            false,
            std::memory_order_release);
        return false;
    }

    const pid_t pidValue = getpid();
    const time_t nowValue = time(nullptr);
    if (pidValue <= 0 ||
        static_cast<std::uint64_t>(pidValue) >
            UINT32_C(0x000fffff) ||
        nowValue < 0 ||
        static_cast<std::uint64_t>(nowValue) >
            UINT32_MAX) {
        gPublished.store(
            false,
            std::memory_order_release);
        return false;
    }

    const uint64_t flags =
        DiagnosticFlags(snapshot);
    const uint64_t enumsState =
        vcam_local_photo_pipeline_ready_encode_enums(
            snapshot.mediaKind,
            snapshot.selectedMediaKind,
            snapshot.playbackIntent,
            snapshot.playbackState);
    const uint64_t countsState =
        vcam_local_photo_pipeline_ready_encode_counts(
            snapshot.readyFrameCount,
            snapshot.virtualDecisionCount);
    const uint64_t eventState =
        vcam_local_photo_pipeline_ready_encode_event(
            static_cast<uint32_t>(nowValue),
            static_cast<uint32_t>(pidValue),
            result,
            snapshot.pipelineStage);

    if (notify_set_state(
            gSelectionToken,
            snapshot.selectionGeneration) !=
            NOTIFY_STATUS_OK ||
        notify_set_state(
            gFlagsToken,
            flags) !=
            NOTIFY_STATUS_OK ||
        notify_set_state(
            gEnumsToken,
            enumsState) !=
            NOTIFY_STATUS_OK ||
        notify_set_state(
            gCountsToken,
            countsState) !=
            NOTIFY_STATUS_OK ||
        notify_set_state(
            gEventToken,
            eventState) !=
            NOTIFY_STATUS_OK ||
        notify_post(
            VCAM_LOCAL_PHOTO_PIPELINE_READY_NOTIFICATION) !=
            NOTIFY_STATUS_OK) {
        gPublished.store(
            false,
            std::memory_order_release);
        return false;
    }

    os_log_with_type(
        OS_LOG_DEFAULT,
        OS_LOG_TYPE_DEFAULT,
        "[VCAM PRO LOCAL PHOTO DIAGNOSTIC] "
        "version=%{public}s "
        "result=%{public}u "
        "stage=%{public}u "
        "selection-generation=%{public}llu "
        "ready-frame-count=%{public}zu "
        "virtual-decision-count=%{public}llu "
        "pid=%{public}d",
        VCAM_LOCAL_PHOTO_PIPELINE_READY_VERSION,
        static_cast<unsigned int>(result),
        static_cast<unsigned int>(
            snapshot.pipelineStage),
        static_cast<unsigned long long>(
            snapshot.selectionGeneration),
        snapshot.readyFrameCount,
        static_cast<unsigned long long>(
            snapshot.virtualDecisionCount),
        pidValue);

    return true;
}

}  // namespace vcam::product::proof
