#include "FullProductRealHookProof.h"
#include "FullProductRealHookProofState.h"

#include <notify.h>
#include <os/log.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#include <cstdint>

namespace vcam::product::proof {

namespace {

int gProofStateToken = -1;

}  // namespace

void ResetFullProductRealHookProofState() noexcept {
    if (gProofStateToken >= 0) {
        (void)notify_cancel(gProofStateToken);
        gProofStateToken = -1;
    }

    int token = 0;
    if (notify_register_check(
            VCAM_FULL_PRODUCT_REAL_HOOK_NOTIFICATION,
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

bool PublishFullProductRealHookInstallProof() noexcept {
    if (gProofStateToken < 0) {
        return false;
    }

    const pid_t pidValue = getpid();
    const time_t nowValue = time(nullptr);

    if (pidValue <= 0 ||
        static_cast<std::uint64_t>(pidValue) >
            UINT32_C(0x07ffffff) ||
        nowValue < 0 ||
        static_cast<std::uint64_t>(nowValue) >
            UINT32_MAX) {
        return false;
    }

    const std::uint64_t state =
        vcam_full_product_real_hook_encode_state(
            static_cast<std::uint32_t>(nowValue),
            static_cast<std::uint32_t>(pidValue));

    if (notify_set_state(
            gProofStateToken,
            state) != NOTIFY_STATUS_OK) {
        return false;
    }

    if (notify_post(
            VCAM_FULL_PRODUCT_REAL_HOOK_NOTIFICATION) !=
        NOTIFY_STATUS_OK) {
        return false;
    }

    os_log_with_type(
        OS_LOG_DEFAULT,
        OS_LOG_TYPE_DEFAULT,
        "[VCAM PRO FULL PRODUCT REAL HOOK] "
        "version=%{public}s "
        "process=mediaserverd "
        "runtime.start=PASS "
        "real-reference-hook-install=PASS "
        "original-trampoline=NON_NULL "
        "callback=NOT_EXERCISED "
        "frame-substitution=INACTIVE "
        "pid=%{public}d",
        VCAM_FULL_PRODUCT_REAL_HOOK_VERSION,
        pidValue);

    return true;
}

}  // namespace vcam::product::proof
