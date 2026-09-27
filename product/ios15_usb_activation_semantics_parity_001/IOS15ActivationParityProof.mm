#include "IOS15ActivationParityProof.h"

#include <dispatch/dispatch.h>
#include <notify.h>
#include <os/log.h>
#include <time.h>
#include <unistd.h>

#include <array>
#include <atomic>
#include <cstdint>

namespace vcam::product::proof {

namespace {

dispatch_queue_t gProofQueue = nullptr;
int gProofToken = -1;
int gSelectionToken = -1;

std::array<
    std::atomic<bool>,
    4>
    gPublished{};

bool RegisterToken(
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

void CancelToken(
    int* token) noexcept {
    if (token != nullptr &&
        *token >= 0) {
        (void)notify_cancel(*token);
        *token = -1;
    }
}

uint32_t EncodeFlags(
    const IOS15ActivationParityFacts&
        facts) noexcept {
    uint32_t flags = 0;

    if (facts.callbackExercised) {
        flags |=
            VCAM_ACTIVATION_FLAG_CALLBACK_EXERCISED;
    }
    if (facts.vcamEnabled) {
        flags |=
            VCAM_ACTIVATION_FLAG_VCAM_ENABLED;
    }
    if (facts.mediaPhoto) {
        flags |=
            VCAM_ACTIVATION_FLAG_MEDIA_PHOTO;
    }
    if (facts.decisionVirtual) {
        flags |=
            VCAM_ACTIVATION_FLAG_DECISION_VIRTUAL;
    }
    if (facts.decisionOriginal) {
        flags |=
            VCAM_ACTIVATION_FLAG_DECISION_ORIGINAL;
    }
    if (facts.virtualBufferNonNull) {
        flags |=
            VCAM_ACTIVATION_FLAG_VIRTUAL_NON_NULL;
    }
    if (facts.virtualBufferDifferentFromOriginal) {
        flags |=
            VCAM_ACTIVATION_FLAG_VIRTUAL_DIFFERENT;
    }
    if (facts.geometryMatch) {
        flags |=
            VCAM_ACTIVATION_FLAG_GEOMETRY_MATCH;
    }
    if (facts.sourceBlack) {
        flags |=
            VCAM_ACTIVATION_FLAG_SOURCE_BLACK;
    }
    if (facts.sourcePreparedMedia) {
        flags |=
            VCAM_ACTIVATION_FLAG_SOURCE_MEDIA;
    }

    return flags;
}

bool FactsValid(
    const IOS15ActivationParityFacts&
        facts) noexcept {
    if (facts.output ==
        IOS15ActivationOutput::None) {
        return false;
    }

    if ((facts.output ==
             IOS15ActivationOutput::BlackVirtual ||
         facts.output ==
             IOS15ActivationOutput::PhotoVirtual) &&
        !facts.decisionReasonNone) {
        return false;
    }

    const uint32_t flags =
        EncodeFlags(facts);

    const uint64_t synthetic =
        vcam_ios15_activation_parity_encode_state(
            1U,
            1U,
            facts.output,
            flags);

    return
        vcam_ios15_activation_parity_state_is_valid(
            synthetic,
            facts.selectionGeneration,
            1U) != 0;
}

void Publish(
    IOS15ActivationParityFacts facts) noexcept {
    if (gProofToken < 0 ||
        gSelectionToken < 0 ||
        !FactsValid(facts)) {
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
        return;
    }

    const uint32_t flags =
        EncodeFlags(facts);
    const uint64_t state =
        vcam_ios15_activation_parity_encode_state(
            static_cast<uint32_t>(nowValue),
            static_cast<uint32_t>(pidValue),
            facts.output,
            flags);

    if (notify_set_state(
            gSelectionToken,
            facts.selectionGeneration) !=
            NOTIFY_STATUS_OK ||
        notify_set_state(
            gProofToken,
            state) !=
            NOTIFY_STATUS_OK ||
        notify_post(
            VCAM_IOS15_ACTIVATION_PARITY_NOTIFICATION) !=
            NOTIFY_STATUS_OK) {
        return;
    }

    os_log_with_type(
        OS_LOG_DEFAULT,
        OS_LOG_TYPE_DEFAULT,
        "[VCAM PRO ACTIVATION PARITY] "
        "output=%{public}u "
        "selection-generation=%{public}llu "
        "pid=%{public}d",
        static_cast<unsigned int>(
            facts.output),
        static_cast<unsigned long long>(
            facts.selectionGeneration),
        pidValue);
}

}  // namespace

void ResetIOS15ActivationParityProofState() noexcept {
    for (auto& published : gPublished) {
        published.store(
            false,
            std::memory_order_release);
    }

    CancelToken(&gProofToken);
    CancelToken(&gSelectionToken);

    if (gProofQueue == nullptr) {
        gProofQueue =
            dispatch_queue_create(
                "com.vcampro.ios15-activation-parity-proof",
                DISPATCH_QUEUE_SERIAL);
    }

    if (!RegisterToken(
            VCAM_IOS15_ACTIVATION_PARITY_NOTIFICATION,
            &gProofToken) ||
        !RegisterToken(
            VCAM_IOS15_ACTIVATION_PARITY_SELECTION_STATE,
            &gSelectionToken)) {
        CancelToken(&gProofToken);
        CancelToken(&gSelectionToken);
        return;
    }

    (void)notify_set_state(
        gProofToken,
        UINT64_C(0));
    (void)notify_set_state(
        gSelectionToken,
        UINT64_C(0));
}

void ObserveIOS15ActivationParity(
    const IOS15ActivationParityFacts&
        facts) noexcept {
    if (!FactsValid(facts) ||
        gProofQueue == nullptr) {
        return;
    }

    const std::size_t index =
        static_cast<std::size_t>(
            facts.output);

    if (index >= gPublished.size()) {
        return;
    }

    bool expected = false;
    if (!gPublished[index].
            compare_exchange_strong(
                expected,
                true,
                std::memory_order_acq_rel,
                std::memory_order_acquire)) {
        return;
    }

    dispatch_async(
        gProofQueue,
        ^{
            Publish(facts);
        });
}

}  // namespace vcam::product::proof
