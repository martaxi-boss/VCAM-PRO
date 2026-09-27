#include "FirstLocalPhotoVirtualSubstitutionProof.h"
#include "FirstLocalPhotoVirtualSubstitutionProofState.h"

#include <dispatch/dispatch.h>
#include <notify.h>
#include <os/log.h>
#include <time.h>
#include <unistd.h>

#include <atomic>
#include <cstdint>

namespace vcam::product::proof {

namespace {

std::atomic<std::uint64_t> gActiveSelectionGeneration{0};
std::atomic<bool> gProofClaimed{false};

dispatch_queue_t gProofQueue = nullptr;
int gProofStateToken = -1;
int gSelectionStateToken = -1;

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

void ClearPublishedState() noexcept {
    if (gProofStateToken >= 0) {
        (void)notify_set_state(
            gProofStateToken,
            UINT64_C(0));
    }
    if (gSelectionStateToken >= 0) {
        (void)notify_set_state(
            gSelectionStateToken,
            UINT64_C(0));
    }
}

bool FactsEstablishSubstitution(
    const FirstLocalPhotoVirtualSubstitutionFacts& facts) noexcept {
    return
        facts.selectionGeneration != 0 &&
        facts.originalNonNull &&
        facts.vcamEnabled &&
        facts.photoSelected &&
        facts.mediaReady &&
        facts.cameraGeometryObserved &&
        facts.callbackExercised &&
        facts.decisionVirtual &&
        facts.decisionReasonNone &&
        facts.virtualBufferNonNull &&
        facts.virtualBufferDifferentFromOriginal &&
        facts.geometryMatch &&
        facts.decisionCountIncremented &&
        facts.virtualDecisionCountIncremented &&
        facts.virtualDecisionCountAfter > 0;
}

void PublishAcceptedProof(
    FirstLocalPhotoVirtualSubstitutionFacts facts) noexcept {
    if (gProofStateToken < 0 ||
        gSelectionStateToken < 0 ||
        gActiveSelectionGeneration.load(
            std::memory_order_acquire) !=
            facts.selectionGeneration) {
        gProofClaimed.store(
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
        gProofClaimed.store(
            false,
            std::memory_order_release);
        return;
    }

    if (!FactsEstablishSubstitution(facts) ||
        gActiveSelectionGeneration.load(
            std::memory_order_acquire) !=
            facts.selectionGeneration) {
        gProofClaimed.store(
            false,
            std::memory_order_release);
        return;
    }

    const std::uint64_t state =
        vcam_first_photo_substitution_encode_state(
            static_cast<std::uint32_t>(nowValue),
            static_cast<std::uint32_t>(pidValue),
            VCAM_FIRST_PHOTO_SUB_REQUIRED_FLAGS);

    if (notify_set_state(
            gSelectionStateToken,
            facts.selectionGeneration) !=
            NOTIFY_STATUS_OK ||
        notify_set_state(
            gProofStateToken,
            state) !=
            NOTIFY_STATUS_OK ||
        notify_post(
            VCAM_FIRST_LOCAL_PHOTO_VIRTUAL_SUBSTITUTION_NOTIFICATION) !=
            NOTIFY_STATUS_OK) {
        gProofClaimed.store(
            false,
            std::memory_order_release);
        return;
    }

    os_log_with_type(
        OS_LOG_DEFAULT,
        OS_LOG_TYPE_DEFAULT,
        "[VCAM PRO FIRST PHOTO SUBSTITUTION] "
        "version=%{public}s "
        "vcam-enabled=YES "
        "media-kind=PHOTO "
        "media-ready=YES "
        "camera-geometry-observed=YES "
        "camera-callback=EXERCISED "
        "decision=VIRTUAL "
        "virtual-buffer-non-null=YES "
        "virtual-buffer-different-from-original=YES "
        "geometry-match=YES "
        "virtual-decision-count=%{public}llu "
        "frame-substitution=ACTIVE "
        "selection-generation=%{public}llu "
        "pid=%{public}d",
        VCAM_FIRST_LOCAL_PHOTO_VIRTUAL_SUBSTITUTION_VERSION,
        static_cast<unsigned long long>(
            facts.virtualDecisionCountAfter),
        static_cast<unsigned long long>(
            facts.selectionGeneration),
        pidValue);
}

}  // namespace

void ResetFirstLocalPhotoVirtualSubstitutionProofState() noexcept {
    gActiveSelectionGeneration.store(
        0,
        std::memory_order_release);
    gProofClaimed.store(
        false,
        std::memory_order_release);

    CancelToken(&gProofStateToken);
    CancelToken(&gSelectionStateToken);

    if (gProofQueue == nullptr) {
        gProofQueue =
            dispatch_queue_create(
                "com.vcampro.first-photo-substitution-proof",
                DISPATCH_QUEUE_SERIAL);
    }

    if (!RegisterStateToken(
            VCAM_FIRST_LOCAL_PHOTO_VIRTUAL_SUBSTITUTION_NOTIFICATION,
            &gProofStateToken) ||
        !RegisterStateToken(
            VCAM_FIRST_LOCAL_PHOTO_VIRTUAL_SUBSTITUTION_SELECTION_STATE,
            &gSelectionStateToken)) {
        CancelToken(&gProofStateToken);
        CancelToken(&gSelectionStateToken);
        return;
    }

    ClearPublishedState();
}

void BeginFirstLocalPhotoVirtualSubstitutionSelection(
    std::uint64_t selectionGeneration) noexcept {
    const std::uint64_t previous =
        gActiveSelectionGeneration.exchange(
            selectionGeneration,
            std::memory_order_acq_rel);

    if (previous == selectionGeneration) {
        return;
    }

    gProofClaimed.store(
        false,
        std::memory_order_release);

    if (gProofQueue != nullptr) {
        dispatch_async(
            gProofQueue,
            ^{
                ClearPublishedState();
            });
    }
}

void ObserveFirstLocalPhotoVirtualSubstitution(
    const FirstLocalPhotoVirtualSubstitutionFacts& facts) noexcept {
    if (!FactsEstablishSubstitution(facts) ||
        gProofQueue == nullptr ||
        gActiveSelectionGeneration.load(
            std::memory_order_acquire) !=
            facts.selectionGeneration) {
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
            PublishAcceptedProof(facts);
        });
}

}  // namespace vcam::product::proof
