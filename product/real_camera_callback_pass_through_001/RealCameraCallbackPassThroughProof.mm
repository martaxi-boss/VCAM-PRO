#include "RealCameraCallbackPassThroughProof.h"
#include "RealCameraCallbackPassThroughProofState.h"

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

std::atomic<bool> gProofClaimed{false};
dispatch_queue_t gProofQueue = nullptr;
int gProofStateToken = -1;

bool FactsEstablishPassThrough(
    const RealCameraCallbackPassThroughFacts& facts) noexcept {
    if (!facts.originalNonNull ||
        facts.controlEnabled ||
        facts.controlHasMedia ||
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

void PublishAcceptedProof() noexcept {
    if (gProofStateToken < 0) {
        gProofClaimed.store(
            false,
            std::memory_order_release);
        return;
    }

    const pid_t pidValue = getpid();
    const time_t nowValue = time(nullptr);

    if (pidValue <= 0 ||
        static_cast<std::uint64_t>(pidValue) >
            UINT32_C(0x00ffffff) ||
        nowValue < 0 ||
        static_cast<std::uint64_t>(nowValue) >
            UINT32_MAX) {
        gProofClaimed.store(
            false,
            std::memory_order_release);
        return;
    }

    const std::uint64_t state =
        vcam_real_camera_callback_passthrough_encode_state(
            static_cast<std::uint32_t>(nowValue),
            static_cast<std::uint32_t>(pidValue));

    if (notify_set_state(
            gProofStateToken,
            state) != NOTIFY_STATUS_OK ||
        notify_post(
            VCAM_REAL_CAMERA_CALLBACK_PASSTHROUGH_NOTIFICATION) !=
            NOTIFY_STATUS_OK) {
        gProofClaimed.store(
            false,
            std::memory_order_release);
        return;
    }

    os_log_with_type(
        OS_LOG_DEFAULT,
        OS_LOG_TYPE_DEFAULT,
        "[VCAM PRO REAL CAMERA CALLBACK] "
        "version=%{public}s "
        "callback=EXERCISED "
        "vcam-enabled=NO "
        "media-selected=NO "
        "decision=ORIGINAL "
        "original-buffer-returned=YES "
        "frame-substitution=INACTIVE "
        "virtual-decision-count=0 "
        "fail-open-reason=DISABLED "
        "pid=%{public}d",
        VCAM_REAL_CAMERA_CALLBACK_PASSTHROUGH_VERSION,
        pidValue);
}

}  // namespace

void ResetRealCameraCallbackPassThroughProofState() noexcept {
    gProofClaimed.store(
        false,
        std::memory_order_release);

    if (gProofStateToken >= 0) {
        (void)notify_cancel(gProofStateToken);
        gProofStateToken = -1;
    }

    if (gProofQueue == nullptr) {
        gProofQueue =
            dispatch_queue_create(
                "com.vcampro.callback-pass-through-proof",
                DISPATCH_QUEUE_SERIAL);
    }

    int token = 0;
    if (notify_register_check(
            VCAM_REAL_CAMERA_CALLBACK_PASSTHROUGH_NOTIFICATION,
            &token) != NOTIFY_STATUS_OK) {
        return;
    }

    if (notify_set_state(
            token,
            UINT64_C(0)) != NOTIFY_STATUS_OK) {
        (void)notify_cancel(token);
        return;
    }

    gProofStateToken = token;
}

void ObserveRealCameraCallbackPassThroughDecision(
    const RealCameraCallbackPassThroughFacts& facts) noexcept {
    if (gProofQueue == nullptr ||
        gProofStateToken < 0 ||
        !FactsEstablishPassThrough(facts)) {
        return;
    }

    bool expected = false;
    if (!gProofClaimed.compare_exchange_strong(
            expected,
            true,
            std::memory_order_acq_rel,
            std::memory_order_acquire)) {
        return;
    }

    dispatch_async(
        gProofQueue,
        ^{
            PublishAcceptedProof();
        });
}

}  // namespace vcam::product::proof
