#include "RuntimeGateProofState.h"
#include "ReferenceCameraHook.h"

#include <notify.h>
#include <os/log.h>

#include <stdint.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

namespace vcam::product {

namespace {

int gRuntimeGateStateToken = -1;

void PublishRuntimeStartProof() noexcept {
    const char* process = getprogname();

    if (process == nullptr ||
        strcmp(process, "mediaserverd") != 0) {
        return;
    }

    const pid_t pidValue = getpid();
    const time_t nowValue = time(nullptr);

    if (pidValue <= 0 ||
        (uint64_t)pidValue >
            UINT32_C(0x3fffffff) ||
        nowValue < 0 ||
        (uint64_t)nowValue > UINT32_MAX) {
        return;
    }

    const uint64_t state =
        vcam_runtime_gate_encode_state(
            (uint32_t)nowValue,
            (uint32_t)pidValue);

    int token = 0;

    if (notify_register_check(
            VCAM_RUNTIME_GATE_NOTIFICATION,
            &token) != NOTIFY_STATUS_OK) {
        return;
    }

    if (notify_set_state(
            token,
            state) != NOTIFY_STATUS_OK) {
        (void)notify_cancel(token);
        return;
    }

    if (notify_post(
            VCAM_RUNTIME_GATE_NOTIFICATION) !=
        NOTIFY_STATUS_OK) {
        (void)notify_cancel(token);
        return;
    }

    gRuntimeGateStateToken = token;

    os_log_with_type(
        OS_LOG_DEFAULT,
        OS_LOG_TYPE_DEFAULT,
        "[VCAM PRO RUNTIME GATE] "
        "version=%{public}s "
        "process=mediaserverd "
        "runtime.start=PASS "
        "reference-hook=DISABLED "
        "frame-substitution=INACTIVE "
        "pid=%{public}d",
        VCAM_RUNTIME_GATE_VERSION,
        pidValue);
}

}  // namespace

bool InstallReferenceCameraHook() {
    PublishRuntimeStartProof();

    // This certification harness intentionally installs no hook.
    return false;
}

}  // namespace vcam::product
