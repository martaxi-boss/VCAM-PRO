#include "LocalPhotoPipelineReadyProof.h"
#include "LocalPhotoPipelineReadyProofState.h"

#include <dispatch/dispatch.h>
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
std::atomic<std::uint64_t> gCallbackGeneration{0};
std::atomic<std::uint64_t> gReadyGeneration{0};
std::atomic<bool> gPublished{false};

dispatch_queue_t gPublishQueue = nullptr;
int gProofStateToken = -1;

bool CallbackFactsValid(
    const LocalPhotoCallbackFacts& facts) noexcept {
    if (facts.selectionGeneration == 0 ||
        !facts.originalNonNull ||
        !facts.vcamDisabled ||
        !facts.photoSelected ||
        !facts.hasMedia ||
        !facts.decisionOriginal ||
        !facts.disabledReason ||
        !facts.originalBufferReturned) {
        return false;
    }

    if (facts.decisionCountBefore ==
            std::numeric_limits<std::uint64_t>::max() ||
        facts.decisionCountAfter !=
            facts.decisionCountBefore + 1U) {
        return false;
    }

    return
        facts.virtualDecisionCountBefore == 0U &&
        facts.virtualDecisionCountAfter == 0U;
}

bool ReadyFactsValid(
    const LocalPhotoReadyFacts& facts) noexcept {
    return
        facts.selectionGeneration != 0 &&
        facts.vcamDisabled &&
        facts.photoSelected &&
        facts.mediaPathNonEmpty &&
        facts.playbackIntentPlaying &&
        facts.controlObserved &&
        facts.cameraGeometryObserved &&
        facts.mediaStaged &&
        facts.sessionExists &&
        facts.selectedMediaValid &&
        facts.selectedMediaPhoto &&
        facts.selectedMediaPathMatches &&
        facts.producerPlaying &&
        facts.readyFrameCount > 0 &&
        facts.virtualDecisionCount == 0U;
}

void MaybePublish() noexcept {
    const std::uint64_t active =
        gActiveGeneration.load(
            std::memory_order_acquire);
    const std::uint64_t callback =
        gCallbackGeneration.load(
            std::memory_order_acquire);
    const std::uint64_t ready =
        gReadyGeneration.load(
            std::memory_order_acquire);

    if (active == 0 ||
        active != callback ||
        active != ready) {
        return;
    }

    bool expected = false;
    if (!gPublished.compare_exchange_strong(
            expected,
            true,
            std::memory_order_acq_rel,
            std::memory_order_acquire)) {
        return;
    }

    if (gProofStateToken < 0 ||
        gActiveGeneration.load(
            std::memory_order_acquire) != active) {
        gPublished.store(
            false,
            std::memory_order_release);
        return;
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
        return;
    }

    if (gActiveGeneration.load(
            std::memory_order_acquire) != active) {
        gPublished.store(
            false,
            std::memory_order_release);
        return;
    }

    const std::uint64_t state =
        vcam_local_photo_pipeline_ready_encode_state(
            static_cast<std::uint32_t>(nowValue),
            static_cast<std::uint32_t>(pidValue));

    if (notify_set_state(
            gProofStateToken,
            state) != NOTIFY_STATUS_OK ||
        notify_post(
            VCAM_LOCAL_PHOTO_PIPELINE_READY_NOTIFICATION) !=
            NOTIFY_STATUS_OK) {
        gPublished.store(
            false,
            std::memory_order_release);
        return;
    }

    os_log_with_type(
        OS_LOG_DEFAULT,
        OS_LOG_TYPE_DEFAULT,
        "[VCAM PRO LOCAL PHOTO READY] "
        "version=%{public}s "
        "vcam-enabled=NO "
        "media-kind=PHOTO "
        "media-staged=YES "
        "control-state-observed=YES "
        "camera-geometry-observed=YES "
        "producer-ready=YES "
        "ready-frame-count=>0 "
        "camera-callback=EXERCISED "
        "decision=ORIGINAL "
        "original-buffer-returned=YES "
        "frame-substitution=INACTIVE "
        "virtual-decision-count=0 "
        "selection-generation=%{public}llu "
        "pid=%{public}d",
        VCAM_LOCAL_PHOTO_PIPELINE_READY_VERSION,
        static_cast<unsigned long long>(active),
        pidValue);
}

void SchedulePublishCheck() noexcept {
    if (gPublishQueue == nullptr) {
        return;
    }

    dispatch_async(
        gPublishQueue,
        ^{
            MaybePublish();
        });
}

}  // namespace

void ResetLocalPhotoPipelineReadyProofState() noexcept {
    gActiveGeneration.store(0, std::memory_order_release);
    gCallbackGeneration.store(0, std::memory_order_release);
    gReadyGeneration.store(0, std::memory_order_release);
    gPublished.store(false, std::memory_order_release);

    if (gProofStateToken >= 0) {
        (void)notify_cancel(gProofStateToken);
        gProofStateToken = -1;
    }

    if (gPublishQueue == nullptr) {
        gPublishQueue =
            dispatch_queue_create(
                "com.vcampro.local-photo-ready-proof",
                DISPATCH_QUEUE_SERIAL);
    }

    int token = 0;
    if (notify_register_check(
            VCAM_LOCAL_PHOTO_PIPELINE_READY_NOTIFICATION,
            &token) != NOTIFY_STATUS_OK) {
        return;
    }

    if (notify_set_state(token, UINT64_C(0)) !=
        NOTIFY_STATUS_OK) {
        (void)notify_cancel(token);
        return;
    }

    gProofStateToken = token;
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

    gCallbackGeneration.store(
        0,
        std::memory_order_release);
    gReadyGeneration.store(
        0,
        std::memory_order_release);
    gPublished.store(
        false,
        std::memory_order_release);

    if (gPublishQueue != nullptr) {
        dispatch_async(
            gPublishQueue,
            ^{
                if (gProofStateToken >= 0) {
                    (void)notify_set_state(
                        gProofStateToken,
                        UINT64_C(0));
                }
            });
    }
}

void ObserveLocalPhotoCallbackPhase(
    const LocalPhotoCallbackFacts& facts) noexcept {
    if (!CallbackFactsValid(facts) ||
        gActiveGeneration.load(
            std::memory_order_acquire) !=
            facts.selectionGeneration) {
        return;
    }

    gCallbackGeneration.store(
        facts.selectionGeneration,
        std::memory_order_release);
    SchedulePublishCheck();
}

void ObserveLocalPhotoReadyPhase(
    const LocalPhotoReadyFacts& facts) noexcept {
    if (!ReadyFactsValid(facts) ||
        gActiveGeneration.load(
            std::memory_order_acquire) !=
            facts.selectionGeneration) {
        return;
    }

    gReadyGeneration.store(
        facts.selectionGeneration,
        std::memory_order_release);
    SchedulePublishCheck();
}

}  // namespace vcam::product::proof
